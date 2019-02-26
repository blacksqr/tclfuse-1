fuse-critcl.so:
	critcl -keep -lib fuse-critcl.tcl

backup: clean
	(cd ..; tar czv --exclude='tclfuse/backup/*' -f tclfuse-`date +%F`.tar.gz tclfuse)

clean:
	-rm -r *.o *~ */*~ *.so
