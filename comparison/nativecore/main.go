package main

/*
#include <stdlib.h>
*/
import "C"
import (
	"markdownreader/comparison/session"
	"unsafe"
)

var current *session.Session

//export MVInitialize
func MVInitialize(variant *C.char) { current = session.New(session.Config(C.GoString(variant))) }

//export MVCommand
func MVCommand(raw *C.char) *C.char { return C.CString(string(current.JSON([]byte(C.GoString(raw))))) }

//export MVFree
func MVFree(p *C.char) { C.free(unsafe.Pointer(p)) }
func main()            {}
