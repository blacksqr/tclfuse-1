package provide reflect 1.0

if {[info script] eq $argv0} {
    # set up for tests
    lappend auto_path .
}

package require fuse

# reflect implements a reflector for tcl's file system to fuse.
#
# several concurrent mounts can be supported by this code.
# each mount creates two global variables:
#
# ::reflect_cache* caches the nodeid->name map for known files
# ::reflect_files* contains the nodeid->tcl channel map for open files
#
# nodeid is usually the file's inode, except for the top level mountpoint,
# which is nodeid 1

namespace eval reflect {
    variable debug 0	;# output debugging narrative?
}

# dispatch - shim between fuse protocol engine and namespace
proc reflect::dispatch {prefix opcode headers} {
    variable debug
    if {$debug} {
	puts stderr "Dispatch $opcode $prefix $headers"
    }

    return [::reflect::$opcode $prefix $headers]
}

# INIT - initialise a reflector for a given prefix
proc reflect::INIT {prefix headers} {
    variable debug
    if {$debug} {
	puts stderr "reflect INIT $prefix $headers"
    }

    upvar \#0 reflect_cache[string map {. @} $prefix] cache
    set cache(1) $prefix

    upvar \#0 reflect_files[string map {. @} $prefix] files
    set files() 0

    return {}
}

# LOOKUP - look up a name in a given directory
proc reflect::LOOKUP {prefix headers} {
    variable debug
    if {$debug} {
	puts stderr "reflect LOOKUP $prefix $headers"
    }
    upvar \#0 reflect_cache[string map {. @} $prefix] cache

    # get file name within nominated directory
    set dir [file join $prefix $cache([dict get $headers nodeid])]
    set file [file join $dir [dict get $headers name]]

    # get the file's inode and other attributes
    file stat $file attrs
    set cache($attrs(ino)) $file	;# remember inode->name association
    
    # extract relevant attributes for response
    foreach attr {atime ctime mtime ino mode nlink size uid gid dev} {
	dict set headers $attr $attrs($attr)
    }
    dict set headers generation 1	;# not sure what this is for
    dict set headers nodeid $attrs(ino)	;# return the inode of the found file

    return $headers
}

# FORGET - forget any reference to the nominated node
proc reflect::FORGET {prefix headers} {
    upvar \#0 reflect_cache[string map {. @} $prefix] cache
    variable debug
    if {$debug} {
	puts stderr "FORGET $cache([dict get headers nodeid])"
    }
    unset cache([dict get headers nodeid])
    return {}
}

# GETATTR - return the attributes of a given file
proc reflect::GETATTR {prefix headers} {
    upvar \#0 reflect_cache[string map {. @} $prefix] cache
    set name $cache([dict get $headers nodeid])
    file stat $name attrs
    foreach attr {atime ctime mtime ino mode nlink size uid gid dev} {
	dict set headers $attr $attrs($attr)
    }
    return $headers
}

proc reflect::SETATTR {prefix headers} {
}

proc reflect::READLINK {prefix headers} {
}

proc reflect::SYMLINK {prefix headers} {
}

proc reflect::MKNOD {prefix headers} {
}

proc reflect::MKDIR {prefix headers} {
}

proc reflect::UNLINK {prefix headers} {
}

proc reflect::RMDIR {prefix headers} {
}

proc reflect::RENAME {prefix headers} {
}

proc reflect::LINK {prefix headers} {
}

# OPEN a file
proc reflect::OPEN {prefix headers} {
    upvar \#0 reflect_cache[string map {. @} $prefix] cache
    upvar \#0 reflect_files[string map {. @} $prefix] files
    array set h $headers

    # get the name of the file
    set file $cache($h(nodeid))

    # create a new open fd and file handle for the file
    set h(fh) [incr files()]
    set flags [fuse::omodes $h(flags)]	;# get open mode
    #puts stderr "reflect::OPEN $flags [format %o $h(flags)]"
    set files($h(fh)) [open $file $flags]	;# remember fd

    set h(flags) 0	;# response flags - no idea what they are

    return [array get h]
}

# READ a byterange from open file
proc reflect::READ {prefix headers} {
    upvar \#0 reflect_files[string map {. @} $prefix] files

    array set h $headers
    seek $files($h(fh)) $h(offset) start
    set h(data) [read $files($h(fh)) $h(size)]

    return [array get h]
}

proc reflect::WRITE {prefix headers} {
}

# RELEASE an open file
proc reflect::RELEASE {prefix headers} {
    upvar \#0 reflect_files[string map {. @} $prefix] files
    set fh [dict get $headers fh]
    catch {close $files($fh)}
    unset files($fh)

    return {}
}

proc reflect::INVALID {prefix headers} {
}

proc reflect::FSYNC {prefix headers} {
}

proc reflect::SETXATTR {prefix headers} {
}

proc reflect::GETXATTR {prefix headers} {
}

proc reflect::LISTXATTR {prefix headers} {
}

proc reflect::REMOVEXATTR {prefix headers} {
}

# FLUSH an open file
proc reflect::FLUSH {prefix headers} {
    upvar \#0 reflect_files[string map {. @} $prefix] files
    catch {flush $files([dict get $headers fh])}
    return {}
}

# OPENDIR: return a list of {name {inode type}} for each file in directory
proc reflect::OPENDIR {prefix headers} {
    upvar \#0 reflect_cache[string map {. @} $prefix] cache
    set name $cache([dict get $headers nodeid])
    variable debug
    if {$debug} {
	puts stderr "reflect OPENDIR $name $headers"
    }
    set result {}
    foreach file [concat [glob -nocomplain -tails -dir $name *] [glob -nocomplain -tails -dir $name .*]] {
	catch {unset attr}
	file stat [file join $name $file] attr
	lappend result $file [list $attr(ino) $attr(type)]
    }

    return $result
}

if {[info script] eq $argv0} {
    lappend auto_path .
    #fuse::mount [list reflect::dispatch [file join [pwd] backup]] /mnt/fuse
    fuse::mount [list reflect::dispatch [pwd]] /mnt/fuse
    set forever 0
    vwait forever
}
