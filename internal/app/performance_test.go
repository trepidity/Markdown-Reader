package app

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"runtime/pprof"
	"strings"
	"testing"
	"time"
)

// These measurements use the product dispatcher and real temporary files.
// They exclude AppKit, bridge copies, DOM layout, and WebKit helper processes.
func performanceText(size int) string {
	var text strings.Builder
	for section := 0; text.Len() < size; section++ {
		fmt.Fprintf(&text, "## Section %d\n\nA representative paragraph with **bold**, *emphasis*, `code`, and a [local link](other.md). Plain words fill the document for reading and editing.\n\n", section)
	}
	return text.String()[:size]
}

// Repeated heading IDs are a separate worst-case workload, not the typical file.
func BenchmarkRepeatedHeadingsStress(b *testing.B) {
	path, _ := performanceFile(b, 256<<10)
	text := strings.Repeat("## Section\n\nParagraph text with **bold** and `code`.\n\n", 5000)
	if err := os.WriteFile(path, []byte(text), 0600); err != nil {
		b.Fatal(err)
	}
	a := New(filepath.Join(filepath.Dir(path), "settings.json"))
	b.ReportAllocs()
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		performanceDispatch(b, a, Command{Action: "open", Path: path})
	}
}

func performanceFile(tb testing.TB, size int) (string, string) {
	tb.Helper()
	dir, err := filepath.EvalSymlinks(tb.TempDir())
	if err != nil {
		tb.Fatal(err)
	}
	path := filepath.Join(dir, "document.md")
	text := performanceText(size)
	if err := os.WriteFile(path, []byte(text), 0600); err != nil {
		tb.Fatal(err)
	}
	return path, text
}
func performanceDispatch(tb testing.TB, a *App, c Command) int {
	tb.Helper()
	s := a.Dispatch(c)
	if s.Error != "" {
		tb.Fatal(s.Error)
	}
	payload, err := json.Marshal(s)
	if err != nil {
		tb.Fatal(err)
	}
	return len(payload)
}
func BenchmarkDispatcher(b *testing.B) {
	for _, size := range []int{8 << 10, 256 << 10, 1 << 20, 4 << 20} {
		for _, action := range []string{"Open", "Edit", "RefreshIdle", "SearchAbsent"} {
			b.Run(fmt.Sprintf("%dKiB/%s", size>>10, action), func(b *testing.B) {
				path, text := performanceFile(b, size)
				config := filepath.Join(filepath.Dir(path), "settings.json")
				a := New(config)
				performanceDispatch(b, a, Command{Action: "open", Path: path})
				b.ReportAllocs()
				b.ResetTimer()
				for i := 0; i < b.N; i++ {
					switch action {
					case "Open":
						b.StopTimer()
						a = New(config)
						b.StartTimer()
						performanceDispatch(b, a, Command{Action: "open", Path: path})
					case "Edit":
						performanceDispatch(b, a, Command{Action: "edit", Path: path, Text: fmt.Sprintf("%08d\n", i) + text})
					case "RefreshIdle":
						performanceDispatch(b, a, Command{Action: "refresh"})
					case "SearchAbsent":
						performanceDispatch(b, a, Command{Action: "search", Scope: "current", Query: "needle-not-in-the-document"})
					}
				}
			})
		}
	}
}

// Opt-in profiling, deliberately excluded from the ordinary correctness suite.
// GC snapshots distinguish retained memory from short-lived render allocations.
func TestPerformanceMemory(t *testing.T) {
	if os.Getenv("MARKDOWN_READER_PERF") != "1" {
		t.Skip("set MARKDOWN_READER_PERF=1 for memory profiling")
	}
	dir := t.TempDir()
	a := New(filepath.Join(dir, "settings.json"))
	snapshot := func(phase string) {
		runtime.GC()
		var m runtime.MemStats
		runtime.ReadMemStats(&m)
		t.Logf("MEMORY phase=%s heap_live_bytes=%d heap_inuse_bytes=%d go_reserved_bytes=%d total_allocated_bytes=%d", phase, m.HeapAlloc, m.HeapInuse, m.Sys, m.TotalAlloc)
		if directory := os.Getenv("MARKDOWN_READER_PROFILE_DIR"); directory != "" {
			f, err := os.Create(filepath.Join(directory, phase+".pprof"))
			if err != nil {
				t.Fatal(err)
			}
			if err = pprof.WriteHeapProfile(f); err != nil {
				t.Fatal(err)
			}
			if err = f.Close(); err != nil {
				t.Fatal(err)
			}
		}
		runtime.KeepAlive(a)
	}
	run := func(c Command) { performanceDispatch(t, a, c) }
	snapshot("empty")
	for _, size := range []int{8 << 10, 256 << 10, 1 << 20, 4 << 20} {
		path, _ := performanceFile(t, size)
		start := time.Now()
		run(Command{Action: "open", Path: path})
		t.Logf("OPEN bytes=%d elapsed_ms=%.3f", size, float64(time.Since(start).Microseconds())/1000)
		snapshot(fmt.Sprintf("open_%dKiB", size>>10))
		run(Command{Action: "closeDocument"})
		snapshot(fmt.Sprintf("closed_%dKiB", size>>10))
	}
	path, text := performanceFile(t, 256<<10)
	run(Command{Action: "open", Path: path})
	for i := 0; i < 320; i++ {
		run(Command{Action: "edit", Path: path, Text: fmt.Sprintf("%08d\n", i) + text})
		if i == 159 || i == 319 {
			snapshot(fmt.Sprintf("256KiB_%d_edits", i+1))
		}
	}
	// Release test-owned source before measuring closed-document retention.
	text = ""
	run(Command{Action: "closeDocument"})
	snapshot("closed_after_320_edits")
	for i := 0; i < 10; i++ {
		p, _ := performanceFile(t, 1<<20)
		run(Command{Action: "open", Path: p})
	}
	snapshot("ten_open_1MiB_documents")
	for i := 0; i < 10; i++ {
		run(Command{Action: "closeDocument"})
	}
	snapshot("all_documents_closed")
}
