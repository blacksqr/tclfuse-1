package provide fuse_c 2.2

namespace eval fuse {}

# load in the fuse C code for establishing a fuse kernel-connection
set fd [open fuse.c]
critcl::ccode [read $fd]
close $fd

# fuse_mount: return a tcl channel
# for the fuse kernel-connection created by C fuse_mount()
critcl::cproc fuse_mount {Tcl_Interp* interp char* mountpoint char* opts} ok {
    int fd = fuse_mount(mountpoint, opts);
    if (fd < 0) {
	Tcl_SetResult(interp, "Error mounting", TCL_STATIC);
	return TCL_ERROR;
    } else {
	Tcl_Obj *objPtr;
	Tcl_Channel chan;
	chan = Tcl_MakeFileChannel(fd, TCL_READABLE|TCL_WRITABLE);
	Tcl_RegisterChannel(interp, chan);
	Tcl_SetObjResult(interp,
			 Tcl_NewStringObj(Tcl_GetChannelName(chan), -1));
	return TCL_OK;
    }
}
