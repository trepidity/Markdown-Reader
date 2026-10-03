package main

import (
	"bytes"
	"encoding/binary"
	"encoding/json"
	"os"
	"path/filepath"
	"reflect"
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
	for _, want := range []string{"Heading", "Hello bold and italic", "& *literal*", "•\titem", "quotation", "[Image: description]", "A", "B", "C", "D"} {
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

// renderRecords writes source to a temporary file and returns the decoded
// presentation stream produced by the real run seam.
func renderRecords(t *testing.T, source string) []record {
	t.Helper()
	path := filepath.Join(t.TempDir(), "document.md")
	if err := os.WriteFile(path, []byte(source), 0600); err != nil {
		t.Fatal(err)
	}
	var out bytes.Buffer
	if err := run([]string{path}, &out); err != nil {
		t.Fatal(err)
	}
	return presentationRecords(t, out.Bytes())
}

type want struct {
	text  string
	flags uint32
}

func expectRecords(t *testing.T, source string, expected []want) {
	t.Helper()
	records := renderRecords(t, source)
	var got []want
	for _, r := range records {
		got = append(got, want{string(r.body), r.flags})
	}
	if len(got) != len(expected) {
		t.Fatalf("got %d records %q, want %q", len(got), got, expected)
	}
	for i := range got {
		if got[i] != expected[i] {
			t.Errorf("record %d = %q/%#x, want %q/%#x", i, got[i].text, got[i].flags, expected[i].text, expected[i].flags)
		}
	}
}

const (
	marker    = 128
	listLevel = 1 << 16
	quoteLvl  = 1 << 24
	codeLine  = 4 | 16
	firstLine = 4096
	lastLine  = 8192
)

// Fails if the marker flag leaks onto item text, markers use a space instead of
// a tab, ordered numbering is lost, or nesting does not deepen the list level.
func TestListMarkerRunIsFlaggedSeparatelyFromItemTextAtEachDepth(t *testing.T) {
	expectRecords(t, "- a\n  - b\n\n3. x\n4. y\n", []want{
		{"•\t", marker | listLevel}, {"a", listLevel}, {"\n", listLevel},
		{"•\t", marker | 2*listLevel}, {"b", 2 * listLevel}, {"\n", 2 * listLevel},
		{"3.\t", marker | listLevel}, {"x", listLevel}, {"\n", listLevel},
		{"4.\t", marker | listLevel}, {"y", listLevel}, {"\n", listLevel},
	})
}

// Fails if block quotes reuse the list-depth bits, which would indent quotes as
// lists natively and make a list inside a quote indistinguishable from nesting.
func TestQuoteDepthIsCarriedSeparatelyFromListDepth(t *testing.T) {
	expectRecords(t, "> a\n>\n> > b\n>\n> - c\n", []want{
		{"a", quoteLvl}, {"\n", quoteLvl},
		{"b", 2 * quoteLvl}, {"\n", 2 * quoteLvl},
		{"•\t", marker | quoteLvl | listLevel}, {"c", quoteLvl | listLevel}, {"\n", quoteLvl | listLevel},
	})
}

// Fails if a spacer record follows code, a line lacks its own paragraph newline
// (including a final source line without one), or first/last line bits are lost.
func TestCodeBlockLinesAreParagraphsWithFirstAndLastMarks(t *testing.T) {
	expectRecords(t, "```\none\ntwo\n```\n\n```\n```\n\n    solo\n\n```\nlast", []want{
		{"one\n", codeLine | firstLine}, {"two\n", codeLine | lastLine},
		{"\n", codeLine | firstLine | lastLine},
		{"solo\n", codeLine | firstLine | lastLine},
		{"last\n", codeLine | firstLine | lastLine},
	})
}

// Fails if the break is drawn with characters (which wrap or copy as junk) or
// loses its flag, which the native side uses to draw a rule.
func TestThematicBreakIsOneFlaggedEmptyParagraph(t *testing.T) {
	expectRecords(t, "a\n\n---\n\nb\n", []want{
		{"a", 0}, {"\n", 0}, {"\n", 32}, {"b", 0}, {"\n", 0},
	})
}

// The native grid lays tables out itself, so the parser must hand over every cell as plain
// text, in order, with the column alignments. Fails if inline markup leaks into cells, the
// header is not row 0, alignment is lost, or a table inside a list loses its indent depth.
func TestTableIsOneStructuredRecordOfPlainCells(t *testing.T) {
	type table struct {
		Align []string   `json:"align"`
		Rows  [][]string `json:"rows"`
	}
	decode := func(source string) (uint32, table) {
		var found []record
		for _, r := range renderRecords(t, source) {
			if r.flags&tableRecord != 0 {
				found = append(found, r)
			}
		}
		if len(found) != 1 {
			t.Fatalf("want one table record, got %d", len(found))
		}
		var got table
		if err := json.Unmarshal(found[0].body, &got); err != nil {
			t.Fatal(err)
		}
		return found[0].flags, got
	}
	flags, got := decode("| Left | Right | Mid |\n|:--|--:|:-:|\n| `a` | **bbbbbbb** | é |\n")
	if flags != tableRecord {
		t.Fatalf("flags %#x", flags)
	}
	want := table{[]string{"l", "r", "c"}, [][]string{{"Left", "Right", "Mid"}, {"a", "bbbbbbb", "é"}}}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("got %+v, want %+v", got, want)
	}
	flags, _ = decode("- item\n\n  | A |\n  |---|\n  | b |\n")
	if flags != tableRecord|listLevel {
		t.Fatalf("table in a list has flags %#x", flags)
	}
}

// The chunked parse must be invisible: every split the chunker may choose has to
// yield the same bytes as one whole-document parse. Fails if a split is placed
// inside a fence, an HTML block, or a list/quote, or if reference definitions
// stop resolving across sections.
func TestChunkedRenderingIsByteIdenticalToWholeDocument(t *testing.T) {
	documents := map[string]string{
		"constructs": "# One\n\nIntro *text* with [ref][] later.\n\n" +
			"```\n# not a heading\n\n# still code\n```\n\n" +
			"# Two\n\n~~~~ python\n~~~\n\n# inside tilde fence\n\n````\n~~~~\n\n" +
			"# Three\n\n<!-- comment\n\n# hidden\n\n-->\n\n" +
			"# Four\n\n<pre>\n\n# preformatted\n\n</PRE>\n\n" +
			"<?php\n\n# processing\n\n?>\n\n<!DOCTYPE x\n\n# decl\n\n>\n\n<![CDATA[\n\n# cdata\n\n]]>\n\n" +
			"# Five\n\n1. one\n2. two\n\n# Six\n\n3. three\n4. four\n\n- loose\n\n- list\n\n" +
			"# Seven\n\n> quoted\n>\n> > deeper\n\n| A | B |\n|---|--:|\n| c | d |\n\n" +
			"#\n\n#\tTab heading\n\n#hashtag paragraph\n\n####### seven hashes\n\n" +
			"<div>\n# inside div\n</div>\n\n  ~~~\n\n# indented fence content\n\n  ~~~\n\n" +
			"``` a`b\n\n# Eight\n\n```\nunterminated\n\n# to the end\n",
		// The scanner cannot see list or HTML-block context, so these mis-pair
		// fences; the parsed-chunk check must reject the resulting boundary.
		"fence in list item":       "# A\n\n1. a\n\n   ```\n   nested\n\n# B\n\n```\ncode\n\n# fenced heading\n\n```\n\n# C\n",
		"fence in html block":      "# A\n\n<div>\n```\n</div>\n\n```\nhidden\n\n# fenced after div\n\n```\n\n# B\n",
		"comment after list fence": "# A\n\n1. a\n\n   ```\n\n# B\n\n<!--\n```\n\n# hidden\n\n-->\n\n# C\n",
		"references":               "# One\n\nSee [the site][site] and [site].\n\n# Two\n\n[site]: https://example.com \"Title\"\n\n# Three\n\nAgain [site].\n",
		"quoted reference":         "# One\n\nSee [x][].\n\n# Two\n\n> [x]: /quoted\n",
		"bullet reference":         "# One\n\nSee [y].\n\n# Two\n\n- [y]: /bullet\n",
		"ordered reference":        "# One\n\nSee [z].\n\n# Two\n\n1. [z]: /ordered\n",
	}
	defer func(saved int) { chunkTarget = saved }(chunkTarget)
	for name, document := range documents {
		path := filepath.Join(t.TempDir(), "document.md")
		if err := os.WriteFile(path, []byte(document), 0600); err != nil {
			t.Fatal(err)
		}
		chunkTarget = 1 << 30
		var whole bytes.Buffer
		if err := run([]string{path}, &whole); err != nil {
			t.Fatal(err)
		}
		for _, target := range []int{1, 16, 64, 200} {
			chunkTarget = target
			var chunked bytes.Buffer
			if err := run([]string{path}, &chunked); err != nil {
				t.Fatal(err)
			}
			if !bytes.Equal(whole.Bytes(), chunked.Bytes()) {
				t.Errorf("%s: chunk target %d changed the presentation\nwhole:   %q\nchunked: %q", name, target, whole.String(), chunked.String())
			}
		}
	}
}

// Front matter is metadata, not prose: it must come out as one properties table (key, value) and
// vanish from the Markdown that follows. Fails if the YAML leaks into the body as a paragraph,
// if block scalars, lists or lists of maps lose their text, or if the body is lost.
func TestFrontMatterBecomesAPropertiesTable(t *testing.T) {
	source := "---\ntitle: \"Product Brief\"\nstatus: draft\ntags:\n  - alpha\n  - beta\nsummary: >-\n  Thesis and\n  customers.\nchangelog:\n  - version: 2\n    date: 2026-08-21\n  - version: 1\n    date: 2026-08-16\n---\n# Body\n"
	var table []byte
	var visible strings.Builder
	for _, r := range renderRecords(t, source) {
		if r.flags&tableRecord != 0 {
			table = r.body
		} else {
			visible.Write(r.body)
		}
	}
	var got struct {
		Properties bool       `json:"properties"`
		Rows       [][]string `json:"rows"`
	}
	if err := json.Unmarshal(table, &got); err != nil || !got.Properties {
		t.Fatalf("no properties table: %v %s", err, table)
	}
	want := [][]string{
		{"title", "Product Brief"}, {"status", "draft"}, {"tags", "alpha\nbeta"},
		{"summary", "Thesis and customers."}, {"changelog", "version: 2 · date: 2026-08-21\nversion: 1 · date: 2026-08-16"},
	}
	if !reflect.DeepEqual(got.Rows, want) {
		t.Fatalf("rows %q, want %q", got.Rows, want)
	}
	if strings.Contains(visible.String(), "title:") || strings.Contains(visible.String(), "---") || !strings.Contains(visible.String(), "Body") {
		t.Fatalf("body is %q", visible.String())
	}
}

// A leading thematic break is not front matter: the first line inside must be a key. Fails if
// ordinary Markdown between two rules is swallowed as metadata.
func TestLeadingRuleWithoutKeysIsNotFrontMatter(t *testing.T) {
	for _, r := range renderRecords(t, "---\n\n# Heading\n\n---\ntext\n") {
		if r.flags&tableRecord != 0 {
			t.Fatal("document body was treated as front matter")
		}
	}
	var visible strings.Builder
	for _, r := range renderRecords(t, "---\n\n# Heading\n\n---\ntext\n") {
		visible.Write(r.body)
	}
	if !strings.Contains(visible.String(), "Heading") || !strings.Contains(visible.String(), "text") {
		t.Fatalf("lost content: %q", visible.String())
	}
}

// Front matter this reader cannot structure is shown verbatim, never dropped.
func TestUnstructuredFrontMatterIsShownAsCode(t *testing.T) {
	records := renderRecords(t, "+++\ntitle = \"x\"\n+++\nBody\n")
	var code, rest strings.Builder
	for _, r := range records {
		if r.flags&codeBlockLine != 0 {
			code.Write(r.body)
		} else {
			rest.Write(r.body)
		}
	}
	if !strings.Contains(code.String(), `title = "x"`) || !strings.Contains(rest.String(), "Body") {
		t.Fatalf("code %q rest %q", code.String(), rest.String())
	}
}

// Stream control lives in the top flag bits, so no document may ever set them on ordinary text.
// Deeply nested quotes and lists once carried their depth counters up into those bits, letting a
// document forge placeholder, vector, late and body-end records. Fails if any record produced from
// plain Markdown carries a control bit, or if nesting changes how many records there are.
func TestNestingDepthCannotForgeStreamControlRecords(t *testing.T) {
	const control = placeholderRecord | lateRecord | vectorRecord | bodyEndRecord
	documents := map[string]string{
		"quotes":      strings.Repeat(">", 300) + " deep\n",
		"quote 16":    strings.Repeat(">", 16) + " deep\n",
		"quote 128":   strings.Repeat("> ", 128) + "x\n",
		"lists":       strings.Repeat("  ", 0) + strings.Repeat("- ", 300) + "item\n",
		"mixed":       strings.Repeat("> - ", 100) + "x\n",
		"table quote": strings.Repeat("> ", 40) + "| a |\n" + strings.Repeat("> ", 40) + "|---|\n" + strings.Repeat("> ", 40) + "| b |\n",
		"code quote":  strings.Repeat("> ", 40) + "```go\n" + strings.Repeat("> ", 40) + "x := 1\n" + strings.Repeat("> ", 40) + "```\n",
	}
	for name, source := range documents {
		for _, r := range renderRecords(t, source) {
			if r.flags&control != 0 {
				t.Errorf("%s: record %q carries stream-control bits %#x", name, r.body, r.flags&control)
			}
		}
	}
}
