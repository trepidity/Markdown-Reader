package app

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// Product seam: document links must resolve URI escapes without decoding the
// already-decoded filesystem directory, and failed navigation must retain edits.
func TestDocumentLinksPreserveLiteralPercentDirectories(t *testing.T) {
	for _, name := range []string{"100%", "literal%20directory"} {
		t.Run(name, func(t *testing.T) {
			dir := filepath.Join(t.TempDir(), name)
			if err := os.Mkdir(dir, 0700); err != nil {
				t.Fatal(err)
			}
			dir, err := filepath.EvalSymlinks(dir)
			if err != nil {
				t.Fatal(err)
			}
			source, target := filepath.Join(dir, "source.md"), filepath.Join(dir, "other note%.md")
			for p, content := range map[string]string{source: "# Source", target: "# Target"} {
				if err := os.WriteFile(p, []byte(content), 0600); err != nil {
					t.Fatal(err)
				}
			}
			a := New(filepath.Join(dir, "settings.json"))
			a.Dispatch(Command{Action: "open", Path: source})
			// The command separates the literal source path from the escaped URI reference.
			s := a.Dispatch(Command{Action: "navigateLink", Path: source, Href: "other%20note%25.md#heading"})
			if s.Error != "" || s.Path != target || !strings.Contains(s.HTML, "Target") {
				t.Fatalf("link failed: %+v", s)
			}
			s = a.Dispatch(Command{Action: "navigateLink", Path: source, Href: "source.md"})
			if s.Error == "" || s.Path != target || s.Text != "# Target" {
				t.Fatalf("stale link changed document: %+v", s)
			}
			for _, href := range []string{"bad%escape.md", "https://example.com/note.md", "//example.com/note.md", "missing.md"} {
				s = a.Dispatch(Command{Action: "navigateLink", Path: target, Href: href})
				if s.Error == "" || s.Path != target || s.Text != "# Target" {
					t.Fatalf("bad link %q changed document: %+v", href, s)
				}
			}
			if err := os.WriteFile(target, []byte("External"), 0600); err != nil {
				t.Fatal(err)
			}
			a.Dispatch(Command{Action: "edit", Text: "Retained draft"})
			s = a.Dispatch(Command{Action: "navigateLink", Path: target, Href: "source.md"})
			if s.Error == "" || s.Path != target || s.Text != "Retained draft" || !s.Dirty || disk(t, target) != "External" {
				t.Fatalf("link lost conflicting draft: %+v", s)
			}
		})
	}
}
