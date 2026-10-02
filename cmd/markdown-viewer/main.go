//go:build darwin

package main

/*
#cgo CFLAGS: -x objective-c -fobjc-arc
#cgo LDFLAGS: -framework Cocoa -framework WebKit
#include <stdlib.h>
#include "native.h"
*/
import "C"

import (
	"embed"
	"encoding/json"
	"markdownviewer/internal/app"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"unsafe"
)

//go:embed ui/*
var assets embed.FS
var application *app.App

//export goCommand
func goCommand(raw *C.char) *C.char {
	var c app.Command
	if e := json.Unmarshal([]byte(C.GoString(raw)), &c); e != nil {
		return C.CString(`{"error":"Invalid command"}`)
	}
	s := application.Dispatch(c)
	b, e := json.Marshal(s)
	if e != nil {
		return C.CString(`{"error":"Cannot encode response"}`)
	}
	return C.CString(string(b))
}
func main() {
	runtime.LockOSThread()
	config, e := os.UserConfigDir()
	if e != nil {
		panic(e)
	}
	if override := os.Getenv("MARKDOWN_VIEWER_CONFIG"); override != "" {
		config = override
	}
	application = app.New(filepath.Join(config, "Markdown Viewer", "settings.json"))
	html, _ := assets.ReadFile("ui/index.html")
	css, _ := assets.ReadFile("ui/style.css")
	js, _ := assets.ReadFile("ui/app.js")
	page := strings.Replace(string(html), "/*APP_CSS*/", string(css), 1)
	page = strings.Replace(page, "/*APP_JS*/", string(js), 1)
	initial := ""
	if len(os.Args) > 1 {
		initial = os.Args[1]
	}
	h := C.CString(page)
	p := C.CString(initial)
	defer C.free(unsafe.Pointer(h))
	defer C.free(unsafe.Pointer(p))
	C.runApp(h, p)
}
