package main

import (
	"bytes"
	"encoding/base64"
	"encoding/binary"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// A real child process stands in for an installed plugin at the public stdin /
// stdout boundary. Actual Mermaid rendering is separately tested with its bundle.
func TestPluginProcess(t *testing.T) {
	args := os.Args
	i := 0
	for i < len(args) && args[i] != "--" {
		i++
	}
	if i == len(args) {
		return
	}
	mode, destination := args[i+1], args[i+2]
	input, _ := io.ReadAll(os.Stdin)
	_ = os.WriteFile(destination, input, 0600)
	if strings.HasPrefix(mode, "batch") {
		// Each launch appends one byte, so the test can count processes.
		launches, _ := os.OpenFile(destination+".launches", os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0600)
		launches.WriteString("x")
		launches.Close()
		var request struct{ Sources []string }
		json.Unmarshal(input, &request)
		pdf := base64.StdEncoding.EncodeToString([]byte("%PDF-1.4\n% Plugin test output\n%%EOF\n"))
		for i := range request.Sources {
			switch {
			case mode == "batch-partial" && i == 1:
				json.NewEncoder(os.Stdout).Encode(map[string]any{"index": i, "error": "bad syntax"})
			case mode == "batch-partial" && i == 3:
				os.Exit(3) // dies before diagram 3
			default:
				json.NewEncoder(os.Stdout).Encode(map[string]any{"index": i, "protocol": 1, "svg": fmt.Sprintf(`<svg xmlns="http://www.w3.org/2000/svg" width="200" height="100"><text>Diagram %d</text></svg>`, i), "pdf": pdf, "width": 200, "height": 100})
			}
		}
		os.Exit(0)
	}
	switch mode {
	case "fail":
		os.Exit(7)
	case "hang":
		time.Sleep(3 * time.Second)
		os.Exit(0)
	case "invalid":
		os.Stdout.WriteString("invalid plugin output")
		os.Exit(0)
	case "oversize":
		os.Stdout.WriteString(strings.Repeat("x", 9<<20))
		os.Exit(0)
	}
	pdf := []byte("%PDF-1.4\n% Plugin test output\n%%EOF\n")
	json.NewEncoder(os.Stdout).Encode(map[string]any{"protocol": 1, "svg": `<svg xmlns="http://www.w3.org/2000/svg" width="200" height="100"><text>Rendered nodes</text></svg>`, "pdf": base64.StdEncoding.EncodeToString(pdf), "width": 200, "height": 100})
	os.Exit(0)
}

func pluginFixture(t *testing.T, mode string) (string, string) {
	t.Helper()
	root := t.TempDir()
	dir := filepath.Join(root, "test-diagram")
	if err := os.Mkdir(dir, 0700); err != nil {
		t.Fatal(err)
	}
	exe, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	request := filepath.Join(root, "request.json")
	quote := func(s string) string { return "'" + strings.ReplaceAll(s, "'", "'\\''") + "'" }
	script := "#!/bin/sh\nexec " + quote(exe) + " -test.run=TestPluginProcess -- " + quote(mode) + " " + quote(request) + "\n"
	if err = os.WriteFile(filepath.Join(dir, "render"), []byte(script), 0700); err != nil {
		t.Fatal(err)
	}
	manifest := `{"schemaVersion":1,"id":"test-diagram","name":"Test diagram","version":"1.0.0","languages":["mermaid"],"executable":"render","timeoutMilliseconds":100}`
	if mode != "hang" {
		manifest = strings.Replace(manifest, `:100}`, `:5000}`, 1) // re-launching the test binary can be slow on a loaded machine
	}
	if strings.HasPrefix(mode, "batch") {
		manifest = strings.Replace(manifest, `"executable"`, `"batch":true,"executable"`, 1)
	}
	if err = os.WriteFile(filepath.Join(dir, "plugin.json"), []byte(manifest), 0600); err != nil {
		t.Fatal(err)
	}
	return root, request
}

type record struct {
	flags      uint32
	body, meta []byte
}

func presentationRecords(t *testing.T, data []byte) []record {
	t.Helper()
	if !bytes.HasPrefix(data, []byte("MVRO1\n")) {
		t.Fatal("missing presentation")
	}
	data = data[6:]
	var records []record
	for len(data) > 0 {
		if len(data) < 12 {
			t.Fatal("truncated header")
		}
		f, n, m := binary.LittleEndian.Uint32(data), binary.LittleEndian.Uint32(data[4:]), binary.LittleEndian.Uint32(data[8:])
		data = data[12:]
		if uint64(n)+uint64(m) > uint64(len(data)) {
			t.Fatal("truncated record")
		}
		records = append(records, record{f, append([]byte{}, data[:n]...), append([]byte{}, data[n:n+m]...)})
		data = data[n+m:]
	}
	return records
}

func TestPluginRendersMatchingFenceAndPreservesSurroundingText(t *testing.T) {
	root, request := pluginFixture(t, "good")
	path := filepath.Join(t.TempDir(), "diagram.md")
	source := []byte("Before\n\n```mermaid\ngraph TD\n A-->B\n```\n\nAfter\n\n```go\nfmt.Println(1)\n```\n")
	os.WriteFile(path, source, 0400)
	var out bytes.Buffer
	if err := run([]string{"--plugins", root, path}, &out); err != nil {
		t.Fatal(err)
	}
	records := presentationRecords(t, out.Bytes())
	images, bodyEnd, firstLate := 0, -1, -1
	var placeholders []uint32
	var visible strings.Builder
	for i, r := range records {
		switch {
		case r.flags&placeholderRecord != 0:
			placeholders = append(placeholders, r.flags&0xFF)
			visible.Write(r.body)
		case r.flags == bodyEndRecord:
			bodyEnd = i
		case r.flags&lateRecord != 0:
			if firstLate < 0 {
				firstLate = i
			}
			if r.flags != vectorRecord|lateRecord|0 {
				t.Fatalf("diagram 0 patch has flags %#x", r.flags)
			}
			images++
			if !bytes.HasPrefix(r.body, []byte("%PDF-1.4")) || !bytes.Contains(r.meta, []byte("Rendered nodes")) {
				t.Fatal("lost vector output")
			}
		default:
			visible.Write(r.body)
		}
	}
	// The reader must be able to show every word of text before any diagram exists.
	// A diagram can only replace the placeholder whose index it carries.
	if len(placeholders) != 1 || placeholders[0] != 0 {
		t.Fatalf("placeholder indices %v, want [0]", placeholders)
	}
	if bodyEnd < 0 || firstLate < bodyEnd {
		t.Fatalf("body end at %d, first diagram at %d", bodyEnd, firstLate)
	}
	if images != 1 || !strings.Contains(visible.String(), "Before") || !strings.Contains(visible.String(), "After") || !strings.Contains(visible.String(), "fmt.Println(1)") || !strings.Contains(visible.String(), "Rendering diagram") {
		t.Fatalf("lost content: %d images %s", images, visible.String())
	}
	var input struct {
		Protocol         int `json:"protocol"`
		Language, Source string
		Width            int
	}
	b, _ := os.ReadFile(request)
	if err := json.Unmarshal(b, &input); err != nil {
		t.Fatal(err)
	}
	if input.Protocol != 1 || input.Language != "mermaid" || input.Source != "graph TD\n A-->B\n" || input.Width != 900 {
		t.Fatalf("wrong plugin request: %+v", input)
	}
	after, _ := os.ReadFile(path)
	if !bytes.Equal(source, after) {
		t.Fatal("modified source")
	}
}

func TestPluginFailuresRetainSourceAndFollowingContent(t *testing.T) {
	for _, mode := range []string{"fail", "invalid", "hang", "oversize"} {
		t.Run(mode, func(t *testing.T) {
			root, _ := pluginFixture(t, mode)
			path := filepath.Join(t.TempDir(), "diagram.md")
			os.WriteFile(path, []byte("```mermaid\ngraph TD; A-->B\n```\n\nStill readable\n"), 0600)
			var out bytes.Buffer
			start := time.Now()
			if err := run([]string{"--plugins", root, path}, &out); err != nil {
				t.Fatal(err)
			}
			var text, patch strings.Builder
			for _, r := range presentationRecords(t, out.Bytes()) {
				if r.flags&vectorRecord != 0 {
					t.Fatal("failure shown as diagram")
				}
				if r.flags&lateRecord != 0 {
					patch.Write(r.body)
				} else {
					text.Write(r.body)
				}
			}
			// The failure replaces the placeholder with the reason and the source.
			if !strings.Contains(patch.String(), "Plugin test-diagram:") || !strings.Contains(patch.String(), "graph TD; A-->B") || !strings.Contains(text.String(), "Still readable") {
				t.Fatal(patch.String(), text.String())
			}
			if time.Since(start) > 2800*time.Millisecond { // the hanging fake sleeps 3 s; leave room for a loaded machine
				t.Fatal("plugin deadline did not bound rendering")
			}
		})
	}
}

func TestUnknownLanguageDoesNotLaunchInstalledPlugin(t *testing.T) {
	root, request := pluginFixture(t, "fail")
	path := filepath.Join(t.TempDir(), "plain.md")
	os.WriteFile(path, []byte("```go\nfmt.Println(42)\n```\n"), 0600)
	var out bytes.Buffer
	if err := run([]string{"--plugins", root, path}, &out); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(request); !os.IsNotExist(err) {
		t.Fatal("unrelated code launched a plugin")
	}
	if !bytes.Contains(out.Bytes(), []byte("fmt.Println(42)")) {
		t.Fatal("lost ordinary code")
	}
}

func TestRejectsPluginExecutableOutsideItsPackage(t *testing.T) {
	root, request := pluginFixture(t, "good")
	manifest := filepath.Join(root, "test-diagram", "plugin.json")
	b, _ := os.ReadFile(manifest)
	b = bytes.Replace(b, []byte(`"executable":"render"`), []byte(`"executable":"../render"`), 1)
	os.WriteFile(manifest, b, 0600)
	path := filepath.Join(t.TempDir(), "document.md")
	os.WriteFile(path, []byte("```mermaid\nflowchart LR; A-->B\n```"), 0600)
	var out bytes.Buffer
	if err := run([]string{"--plugins", root, path}, &out); err == nil || out.Len() != 0 {
		t.Fatal("accepted executable outside plugin package")
	}
	if _, err := os.Stat(request); !os.IsNotExist(err) {
		t.Fatal("invalid plugin executed")
	}
}

func TestDisabledPluginsLeaveFenceAsSource(t *testing.T) {
	path := filepath.Join(t.TempDir(), "diagram.md")
	os.WriteFile(path, []byte("```mermaid\ngraph TD; A-->B\n```\n"), 0600)
	var out bytes.Buffer
	if err := run([]string{path}, &out); err != nil {
		t.Fatal(err)
	}
	var text strings.Builder
	for _, r := range presentationRecords(t, out.Bytes()) {
		if r.flags == 1<<30 {
			t.Fatal("plugin ran without registry")
		}
		text.Write(r.body)
	}
	if !strings.Contains(text.String(), "graph TD; A-->B") {
		t.Fatal("lost source")
	}
}

// A batch plugin pays its start-up cost once for the whole document; each result still
// lands on the placeholder whose index it carries.
func TestBatchPluginServesEveryDiagramFromOneProcess(t *testing.T) {
	root, request := pluginFixture(t, "batch")
	path := filepath.Join(t.TempDir(), "diagrams.md")
	os.WriteFile(path, []byte("```mermaid\nA\n```\n\ntext\n\n```mermaid\nB\n```\n\n```mermaid\nC\n```\n"), 0600)
	var out bytes.Buffer
	if err := run([]string{"--plugins", root, path}, &out); err != nil {
		t.Fatal(err)
	}
	launches, _ := os.ReadFile(request + ".launches")
	if len(launches) != 1 {
		t.Fatalf("%d plugin processes for 3 diagrams", len(launches))
	}
	var sent struct {
		Protocol int
		Sources  []string
	}
	b, _ := os.ReadFile(request)
	json.Unmarshal(b, &sent)
	if sent.Protocol != 2 || strings.Join(sent.Sources, "|") != "A\n|B\n|C\n" {
		t.Fatalf("batch request %+v", sent)
	}
	for _, r := range presentationRecords(t, out.Bytes()) {
		if r.flags&lateRecord != 0 {
			want := fmt.Sprintf("Diagram %d", r.flags&0xFF)
			if r.flags&vectorRecord == 0 || !bytes.Contains(r.meta, []byte(want)) {
				t.Fatalf("diagram %d carries %s", r.flags&0xFF, r.meta)
			}
		}
	}
}

// One bad diagram does not cost the others, and a renderer that dies mid-batch fails
// only the diagrams it never reached.
func TestBatchPluginIsolatesFailuresPerDiagram(t *testing.T) {
	root, _ := pluginFixture(t, "batch-partial")
	path := filepath.Join(t.TempDir(), "diagrams.md")
	os.WriteFile(path, []byte("```mermaid\n0\n```\n\n```mermaid\n1\n```\n\n```mermaid\n2\n```\n\n```mermaid\n3\n```\n"), 0600)
	var out bytes.Buffer
	if err := run([]string{"--plugins", root, path}, &out); err != nil {
		t.Fatal(err)
	}
	late := map[uint32]record{}
	for _, r := range presentationRecords(t, out.Bytes()) {
		if r.flags&lateRecord != 0 {
			late[r.flags&0xFF] = r
		}
	}
	isDiagram := func(i uint32) bool { return late[i].flags&vectorRecord != 0 }
	if len(late) != 4 || !isDiagram(0) || !isDiagram(2) {
		t.Fatalf("diagrams before and after the bad one were lost: %v", late)
	}
	if isDiagram(1) || !bytes.Contains(late[1].body, []byte("bad syntax")) || !bytes.Contains(late[1].body, []byte("1")) {
		t.Fatalf("diagram 1: %q", late[1].body)
	}
	if isDiagram(3) || !bytes.Contains(late[3].body, []byte("Plugin test-diagram:")) {
		t.Fatalf("diagram 3: %q", late[3].body)
	}
}
