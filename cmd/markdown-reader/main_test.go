package main

import (
	"bytes"
	"encoding/binary"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// Tests the renderer command's actual output protocol, not a parser round-trip.
// Catches dropped content/formatting, executable HTML, and writes by the reader.
func TestReadOnlyPresentation(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "source.md")
	input := []byte("# Heading\n\nHello **bold** and *italic* with `code` and ~~gone~~. &amp; \\*literal\\*\n\n- item\n\n> quotation\n\n[link](https://example.com)\n\n<script>bad()</script>\n\n![description](photo.png)\n\n| A | B |\n|---|---|\n| C | D |\n")
	if err := os.WriteFile(path, input, 0400); err != nil {
		t.Fatal(err)
	}
	var out bytes.Buffer
	if err := run([]string{path}, &out); err != nil {
		t.Fatal(err)
	}
	data := out.Bytes()
	if !bytes.HasPrefix(data, []byte("MVRO1\n")) {
		t.Fatal("missing presentation signature")
	}
	data = data[6:]
	var text strings.Builder
	found := map[string]uint32{}
	links := map[string]string{}
	for len(data) > 0 {
		if len(data) < 12 {
			t.Fatal("truncated record")
		}
		flags, n, l := binary.LittleEndian.Uint32(data), binary.LittleEndian.Uint32(data[4:]), binary.LittleEndian.Uint32(data[8:])
		data = data[12:]
		if uint64(n)+uint64(l) > uint64(len(data)) {
			t.Fatal("invalid record lengths")
		}
		s := string(data[:n])
		text.WriteString(s)
		found[s] |= flags
		links[s] = string(data[n : n+l])
		data = data[n+l:]
	}
	for _, want := range []string{"Heading", "Hello bold and italic", "& *literal*", "• item", "quotation", "[Image: description]", "A", "B", "C", "D"} {
		if !strings.Contains(text.String(), want) {
			t.Errorf("presentation lost %q: %s", want, text.String())
		}
	}
	for s, flag := range map[string]uint32{"Heading": 256, "bold": 1, "italic": 2, "code": 4, "gone": 8} {
		if found[s]&flag == 0 {
			t.Errorf("missing formatting for %q", s)
		}
	}
	if links["link"] != "https://example.com" {
		t.Fatal("lost link destination")
	}
	if strings.Contains(text.String(), "bad()") || strings.Contains(text.String(), "<script>") {
		t.Fatal("raw HTML reached presentation")
	}
	after, _ := os.ReadFile(path)
	if !bytes.Equal(after, input) {
		t.Fatal("reader modified input")
	}
}

func TestRejectsInvalidDocumentsWithoutPresentation(t *testing.T) {
	dir := t.TempDir()
	for name, content := range map[string][]byte{"nul.md": {'a', 0, 'b'}, "invalid.md": {0xff}} {
		path := filepath.Join(dir, name)
		if err := os.WriteFile(path, content, 0600); err != nil {
			t.Fatal(err)
		}
		var out bytes.Buffer
		if err := run([]string{path}, &out); err == nil || out.Len() != 0 {
			t.Errorf("accepted invalid document %s", name)
		}
	}
	for _, args := range [][]string{nil, {dir}, {filepath.Join(dir, "missing.md")}, {"a", "b"}} {
		var out bytes.Buffer
		if err := run(args, &out); err == nil || out.Len() != 0 {
			t.Errorf("accepted invalid invocation %v", args)
		}
	}
}
