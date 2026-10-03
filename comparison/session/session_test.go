package session

import (
	"markdownviewer/internal/app"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestPresentationPreservesFormattingAndSafeContent(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "note.md")
	source := "# Heading\n\nA **bold** word and [local](other.md).\n\n| A | B |\n|---|---|\n| one | two |\n\n```go\nx := 1\n```\n\n<script>bad()</script>\n\n![remote](https://example.com/a.png)"
	if err := os.WriteFile(path, []byte(source), 0600); err != nil {
		t.Fatal(err)
	}
	s := New(filepath.Join(dir, "settings.json")).Dispatch(app.Command{Action: "open", Path: path})
	if len(s.Blocks) == 0 {
		t.Fatal("native presentation is empty")
	}
	var heading, bold, link, table, code bool
	for _, b := range s.Blocks {
		heading = heading || (b.Kind == "heading" && b.Text() == "Heading")
		table = table || (b.Kind == "table" && len(b.Rows) == 2 && b.Rows[1][0][0].Text == "one")
		code = code || (b.Kind == "code" && strings.Contains(b.Text(), "x := 1"))
		for _, r := range b.Runs {
			bold = bold || (r.Bold && r.Text == "bold")
			link = link || (r.Href == "other.md" && r.Text == "local")
			if strings.HasPrefix(r.Image, "http") {
				t.Fatal("remote image reached renderer")
			}
		}
	}
	if !heading || !bold || !link || !table || !code {
		t.Fatalf("content lost: heading %v bold %v link %v table %v code %v", heading, bold, link, table, code)
	}
}
func TestAlternativeSessionRetainsConflictingDraft(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "note.md")
	other := filepath.Join(dir, "other.md")
	os.WriteFile(path, []byte("Original"), 0600)
	os.WriteFile(other, []byte("Other"), 0600)
	a := New(filepath.Join(dir, "settings.json"))
	s := a.Dispatch(app.Command{Action: "open", Path: path})
	os.WriteFile(path, []byte("External"), 0600)
	s = a.Dispatch(app.Command{Action: "edit", Path: s.Path, Revision: s.Revision, Text: "Draft"})
	s = a.Dispatch(app.Command{Action: "open", Path: other})
	if !s.Dirty || s.Error == "" || s.Text != "Draft" {
		t.Fatalf("draft lost: %+v", s)
	}
}
