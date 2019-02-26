#!/usr/bin/tclsh
package provide fuse 2.2

load ./fuse-critcl.so

namespace eval fuse {
    variable debug 0		;# print narrative output?

    variable fusermount	;# fusermount program location
    #variable fusermount /usr/local/bin/fusermount

    variable kernel_version 5		;# fuse major version
    variable kernel_minor_version 1	;# fuse protocol minor version

    # parameters for the filesystem protocol
    variable parameter
    array set parameter {
	attr_revalidate_time 1
	entry_revalidate_time 1
	bsize 512
	namelen 255
    }
}

# find the installed version of fusermount
set fuse::fusermount [exec which fusermount]
if {$fuse::fusermount eq ""} {
    error "Can't find a fusermount program"
}

namespace eval fuse {
    # open modes
    variable omodes {
	RDONLY 00
	WRONLY 01
	RDWR 02
	APPEND 02000
	CREAT 0100
	EXCL 0200
	NOCTTY 0400
	NONBLOCK 04000
	TRUNC 01000
    }

    # return open modes given numeric flags
    proc omodes {flag} {
	variable omodes
	set result {}
	foreach {n v} $omodes {
	    if {$flag & $v} {
		lappend result $n
	    }
	}
	if {$result eq {}} {
	    return RDONLY
	}
	return $result
    }

    # cache of opened files being cached by fuse
    variable files
    set files() 0

    # map from tcl file type to kernel integer dtype
    variable dtype
    array set dtype {
	file DT_REG
	directory DT_DIR
	characterSpecial DT_CHR
	blockSpecial DT_BLK
	fifo DT_FIFO
	link DT_LNK
	socket DT_SOCK

	DT_UNKNOWN 0
	DT_FIFO 1
	DT_CHR 2
	DT_DIR 4
	DT_BLK 6
	DT_REG 8
	DT_LNK 10
	DT_SOCK 12
	DT_WHT 14
    }

    # map opcode <-> opcode name
    variable opcodes
    array set opcodes {
	1 LOOKUP 2 FORGET 3 GETATTR 4 SETATTR
	5 READLINK 6 SYMLINK 8 MKNOD 9 MKDIR
	10 UNLINK 11 RMDIR 12 RENAME 13 LINK
	14 OPEN 15 READ 16 WRITE 17 STATFS
	18 RELEASE 19 INVALID 20 FSYNC 21 SETXATTR
	22 GETXATTR 23 LISTXATTR 24 REMOVEXATTR 25 FLUSH
	26 INIT 27 OPENDIR 28 READDIR 29 RELEASEDIR
    }
    foreach {n v} [array get opcode] {
	set opcode($v) $n
    }
}

# decode - generate tcl script to decode a protocol request
proc genDecode {code} {
    set after ""
    set proc ""

    foreach el [split $code] {
	set type I
	foreach {name type} [split $el :] {}
	switch -- [string toupper $type] {
	    "" -
	    I {
		# 32 bit integer
		lappend proc "\[get_ints \$fd $name\]"
	    }
	    W {
		# 64 bit integer
		lappend proc "\[get_ints64 \$fd $name\]"
	    }
	    S {
		# string
		lappend proc "\[getstring \$fd $name\]" \n
	    }
	    V {
		# variable len data
		lappend proc "\[get_ints \$fd ${name}_len\]"
		lappend after "\[getvar \$fd $name \$h(${name}_len)\]"
	    }
	}
    }

    return "return \[dict merge [join $proc] [join $after]\]"
}

namespace eval fuse {    
    # decodings for opcodes
    foreach {op decode} {
	LOOKUP {name:S}
	FORGET {version:W}
	GETATTR {}
	SETATTR {ino:W size:W blocks:W atime:W mtime:W ctime:W 
	    atimensec mtimensec ctimensec mode nlink uid gid rdev}
	READLINK {}
	SYMLINK {name:S link:S}
	MKNOD {mode dev}
	MKDIR {mode}
	UNLINK {name:S}
	RMDIR {name:S}
	RENAME {newdir:W}
	LINK {oldnodeid:W}
	OPEN {flags}
	READ {fh:W offset:W size}
	WRITE {fh:W offset:W size:V flags}
	STATFS {}
	RELEASE {fh:W flags}
	INVALID {}
	FSYNC {fh:W flags}
	SETXATTR {size:V flags}
	GETXATTR {size:V}
	LISTXATTR {size:V}
	REMOVEXATTR {name:S}
	FLUSH {fh:W flags}
	INIT {major minor}
	OPENDIR {flags}
	READDIR {fh:W offset:W size}
	RELEASEDIR {fh:W flags}
    } {
	proc ${op}_decode {fd} [subst {
	    [genDecode $decode]
	}]
    }
}

# genEncode - generate tcl script to encode a protocol response
proc fuse::genEncode {code} {
    set proc ""
    foreach el $code {
	set type I
	foreach {name type} [split $el :] break
	switch -- [string toupper $type] {
	    E {
		lappend proc "\[ENTRY_encode \$header\]"
		
	    }

	    - {
		return "return {}"
	    }

	    "" -
	    I {
		lappend proc "\[binary format n \[dict get \$header $name\]\]"
	    }

	    W {
		lappend proc "\[binary format m \[dict get \$header $name\]\]"
	    }
	    S {
		lappend proc "\[dict get \$header $name\]"
	    }
	}
    }
    return "return \"[join $proc {}]\""
}

# encode the ENTRY common protocol subresponse
proc fuse::ENTRY_encode {header} {
    # fill the header with some default parameters
    variable parameter
    set header [dict merge $header [subst {
	attr_valid $parameter(attr_revalidate_time)
	attr_valid_nsec 0
	atimensec 0
	mtimensec 0
	ctimensec 0
	dummy 0
    }]]

    # convert file size to number of blocks
    if {![dict exists $header blocks]} {
	variable parameter
	set div [expr {$parameter(bsize) + 0.0}]
	dict set header blocks [expr {int(ceil([dict get $header size] / $div))}]
    }

    # encode the rest of the entry
    return [ENTRY1_encode $header]
}

# encode the LOOKUP protocol response
proc fuse::LOOKUP_encode {header} {
    variable parameter
    set header [dict merge $header [subst {
	attr_valid $parameter(attr_revalidate_time)
	attr_valid_nsec 0
	entry_valid $parameter(entry_revalidate_time)
	entry_valid_nsec 0
	atimensec 0
	mtimensec 0
	ctimensec 0
    }]]

    if {![dict exists $header blocks]} {
	variable parameter
	set div [expr {$parameter(bsize) + 0.0}]
	dict set header blocks [expr {int(ceil([dict get $header size] / $div))}]
    }
    variable debug
    if {$debug} {
	puts stderr "LOOKUP reply: $header"
    }

    return [LOOKUP1_encode $header]
}

# FORGET doesn't return anything
proc fuse::FORGET_encode {header} {
    return -code return
}

namespace eval fuse {    
    # encodings for opcodes
    foreach {op encode} {
	ENTRY1 {attr_valid:W attr_valid_nsec dummy
	    ino:W size:W blocks:W atime:W mtime:W ctime:W 
	    atimensec mtimensec ctimensec mode nlink uid gid dev}

	LOOKUP1 {nodeid:W generation:W entry_valid:W attr_valid:W
	    entry_valid_nsec attr_valid_nsec
	    ino:W size:W blocks:W atime:W mtime:W ctime:W 
	    atimensec mtimensec ctimensec mode nlink uid gid dev
	}

	xxxFORGET {}
	GETATTR {:E}
	SETATTR {:E}
	xxxREADLINK {}
	SYMLINK {:E}
	MKNOD {:E}
	MKDIR {:E}
	UNLINK {:-}
	RMDIR {:-}
	RENAME {:-}
	LINK {:E}
	OPEN {fh:W flags}
	READ {data:S}
	WRITE {size}

	STATFS {
	    blocks:W bfree:W bavail:W files:W ffree:W bsize namelen
	}

	RELEASE {:-}
	xxxINVALID {}
	FSYNC {:-}
	SETXATTR {:-}
	xxxGETXATTR {}
	xxxLISTXATTR {}
	REMOVEXATTR {:-}
	FLUSH {:-}
	INIT {major minor}
	OPENDIR {fh:W flags}
	xxxREADDIR {}
	RELEASEDIR {:-}
    } {
	if {$encode eq ""} {
	    continue
	}

	proc ${op}_encode {header} [subst {
	    [genEncode $encode]
	    return \$result
	}]
    }

}

# handle the INIT protocol request
proc fuse::INIT {fd handler headers} {
    variable debug
    if {$debug} {
	puts stderr "fuse INIT $fd '$handler' $headers"
    }
    variable kernel_version
    variable kernel_minor_version
    eval $handler INIT [list $headers]
    return [list major $kernel_version minor $kernel_minor_version]
}

# OPENDIR protocol request
# - generate a variable with the directory content as a file
proc fuse::OPENDIR {fd handler headers} {
    variable debug
    if {$debug} {
	puts stderr "fuse OPENDIR $fd '$handler' $headers"
    }
    variable files
    variable parameter
    variable dtype

    set dir ""
    foreach {name qual} [dict merge [eval $handler OPENDIR [list $headers]]] {
	if {($name eq ".") || ($name eq "..")} {
	    #continue
	}
	foreach {ino type} $qual break
	set len [string length $name]
	if {$len > $parameter(namelen)} {
	    set len $parameter(namelen)
	}
	variable debug
	if {$debug} {
	    puts stderr "OPENDIR: $name $ino $len $dtype($dtype($type))"
	}

	append dir \
	    [binary format mnn $ino $len $dtype($dtype($type))] \
	    [string range $name 0 [expr {$len - 1}]]

	while {[string length $dir] % 8} {
	    append dir "\0"
	}
    }
    dict set headers fh [incr files()]
    dict set headers flags 0
    set files($files()) $dir
    return $headers
}

# READDIR protocol request
proc fuse::READDIR {fd handler headers} {}
proc fuse::READDIR_encode {headers} {
    variable files
    array set h $headers

    variable debug
    if {$debug} {
	puts stderr "READDIR: $headers"
    }

    return [string range $files($h(fh)) $h(offset) [expr {$h(offset) + $h(size) - 1}]]
}

# RELEASEDIR protocol request
proc fuse::RELEASEDIR {fd handler headers} {
    variable files
    array set h $headers
    unset files($h(fh))
}

# STATFS protocol request
proc fuse::STATFS {fd handler headers} {
    variable parameter
    return [subst {
	namelen $parameter(namelen)
	bsize $parameter(bsize)
	blocks 0 bfree 0 bavail 0 files 0 ffree 0
    }]
}

# get a series of named 32 bit ints
proc fuse::get_ints {fd args} {
    set size [llength $args]
    set in [read $fd [expr $size * 4]]
    binary scan $in n$size vals
    foreach name $args val $vals {
	lappend result $name $val
    }
    return $result
}

# get a series of named 64 bit ints
proc fuse::get_ints64 {fd args} {
    set size [llength $args]
    set in [read $fd [expr $size * 8]]
    binary scan $in m$size vals
    foreach name $args val $vals {
	lappend result $name $val
    }
    return $result
}

# get a single 32 bit int
proc fuse::getint {fd} {
    binary scan [read $fd 4] n val
    return $val
}

# get a single 64 bit int
proc fuse::getint64 {fd} {
    binary scan [read $fd 8] m val
    return $val
}

# get null-terminated string
proc fuse::getstring {fd var} {
    set str ""
    set ch [read $fd 1]
    while {$ch ne "\0"} {
	append str $ch
	set ch [read $fd 1]
    }
    return [list $var $str]
}

# get a variable length string
proc fuse::getvar {fd var len} {
    set str [read $fd $len]
    return [list $var $str]
}

# send a reply to the kernel
proc fuse::reply_detail {fd unique {error 0} {data ""}} {
    set length [expr {[string length $data] + 16}]
    set reply [binary format nnm $length $error $unique]
    puts -nonewline $fd "${reply}$data"
}

# send a reply to the kernel
proc fuse::reply {fd header {error 0} {data ""}} {
    reply_detail $fd [dict get $header unique] $error $data
}

# the Request Format
#uint64_t unique - The identifier used to identify the requests. Replies to the request must provide the exact same unique identifier.
#uint32_t opcode - Member to specify request type. See table below for definitions.
#uint32_t ino - Inode number of the file or directory that the request corresponds to. The root of the file system has inode number 1.
#uint32_t uid
#uint32_t gid
#uint32_t pid
#    Credential information; on who's behalf is the request done.

# read a request header from the system
proc fuse::get_rq {fd} {
    set h [dict merge [get_ints $fd len opcode] \
	       [get_ints64 $fd unique nodeid] \
	       [get_ints $fd uid gid pid]]

    variable opcodes
    dict set h opcode $opcodes([dict get $h opcode])

    return $h
}

# read_eval: read a request, process it, reply to it
# main loop of protocol
proc fuse::read_eval {fd handler} {
    fileevent $fd readable {}	;# block fuse protocol engine
    set h {}

    if {[catch {
	set h [get_rq $fd]

	variable debug
	if {$debug} {
	    puts stderr "read_eval: $h"
	}
    } result eo]} {
	puts stderr "Failed to get request ($h): $eo"
    }

    if {[catch {
	# decode the rest of the request according to opcode
	set opcode [dict get $h opcode]
	set h [dict merge $h [${opcode}_decode $fd]]
    } result eo]} {
	puts stderr "Failed to decode request ($h): $eo"
    }
	
    if {[catch {
	# process the opcode
	if {[info commands ::fuse::$opcode] ne ""} {
	    set h [dict merge $h [$opcode $fd $handler $h]]
	} else {
	    set h [dict merge $h [eval $handler $opcode [list $h]]]
	}
    } result eo]} {
	puts stderr "Failed to process request ($h): $eo"
    }

    if {[catch {
	# reply with encoded response to opcode
	reply $fd $h 0 [${opcode}_encode $h]
    } result eo]} {
	puts stderr "Failed to reply to request ($h): $eo"
    }

    # unblock fuse protocol engine
    fileevent $fd readable [list fuse::read_eval $fd $handler]
}

# mount - call the C mounting process
# associate the resultant kernel-pipe with the fuse protocol handler
proc fuse::mount {handler mp {opt ""}} {
    set fusefd [fuse_mount $mp $opt]
    fconfigure $fusefd -buffering none -translation binary
    fileevent $fusefd readable [list fuse::read_eval $fusefd $handler]
}
