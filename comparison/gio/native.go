package main

/*
#cgo darwin CFLAGS: -x objective-c
#cgo darwin LDFLAGS: -framework Cocoa
#include <stdlib.h>
char *choose(int save);
void openLink(const char* url);
int confirm(void);
*/
import "C"
import "unsafe"

func choosePath(save bool) string {
	s := C.int(0)
	if save {
		s = 1
	}
	p := C.choose(s)
	defer C.free(unsafe.Pointer(p))
	return C.GoString(p)
}
func openURL(url string)  { p := C.CString(url); defer C.free(unsafe.Pointer(p)); C.openLink(p) }
func confirmReload() bool { return C.confirm() != 0 }
