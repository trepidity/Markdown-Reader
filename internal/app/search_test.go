package app

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func writeNote(t *testing.T, path, text string) {
	t.Helper()
	if e := os.MkdirAll(filepath.Dir(path), 0700); e != nil {
		t.Fatal(e)
	}
	if e := os.WriteFile(path, []byte(text), 0600); e != nil {
		t.Fatal(e)
	}
}
func matches(t *testing.T, s State) []SearchMatch {
	t.Helper()
	if s.Error != "" || s.Search == nil {
		t.Fatalf("search failed: %s", s.Error)
	}
	return s.Search.Matches
}
func TestFindCurrentDocumentUsesLiteralUnicodeTextAndEditorOffsets(t *testing.T) {
	a, p := fixture(t)
	writeNote(t, p, "# Finding\n🙂 Café café [a+b]\nCAFÉ\n")
	a.Dispatch(Command{Action: "open", Path: p})
	s := a.Dispatch(Command{Action: "search", Scope: "current", Query: "café"})
	m := matches(t, s)
	if len(m) != 3 || m[0].Line != 2 || m[0].Column != 3 || m[0].Start != 13 || m[0].End != 17 || m[2].Line != 3 {
		t.Fatalf("wrong Unicode matches: %+v", m)
	}
	if len(m[0].Before) != 1 || m[0].Before[0] != "# Finding" || len(m[0].After) == 0 || m[0].After[0] != "CAFÉ" || m[0].SnippetStart != 3 || m[0].SnippetEnd != 7 {
		t.Fatalf("missing or incorrect match context: %+v", m[0])
	}
	m = matches(t, a.Dispatch(Command{Action: "search", Scope: "current", Query: "Café", MatchCase: true}))
	if len(m) != 1 {
		t.Fatalf("match case ignored: %+v", m)
	}
	m = matches(t, a.Dispatch(Command{Action: "search", Scope: "current", Query: "[a+b]"}))
	if len(m) != 1 {
		t.Fatal("literal query was treated as regex")
	}
	if len(matches(t, a.Dispatch(Command{Action: "search", Scope: "current", Query: "absent"}))) != 0 {
		t.Fatal("no-match query returned results")
	}
}
func TestOpenDocumentSearchKeepsDraftsAndUndoAcrossSwitches(t *testing.T) {
	a, p := fixture(t)
	other := filepath.Join(filepath.Dir(p), "other.md")
	writeNote(t, other, "second needle")
	a.Dispatch(Command{Action: "open", Path: p})
	a.Dispatch(Command{Action: "edit", Text: "first needle"})
	a.Dispatch(Command{Action: "open", Path: other})
	s := a.Dispatch(Command{Action: "search", Scope: "open", Query: "needle"})
	if len(matches(t, s)) != 2 || len(s.OpenDocuments) != 2 {
		t.Fatalf("open documents missing: %+v", s)
	}
	a.Dispatch(Command{Action: "open", Path: p})
	a.Dispatch(Command{Action: "undo"})
	if disk(t, p) != "# Original\n" {
		t.Fatal("switching discarded undo history")
	}
	writeNote(t, p, "outside change")
	a.Dispatch(Command{Action: "edit", Text: "unsaved needle"})
	m := matches(t, a.Dispatch(Command{Action: "search", Scope: "open", Query: "needle"}))
	if len(m) != 2 || m[0].Snippet != "unsaved needle" || disk(t, p) != "outside change" {
		t.Fatalf("draft search changed file or missed draft: %+v", m)
	}
	a.Dispatch(Command{Action: "reload"})
	a.Dispatch(Command{Action: "closeDocument"})
	s = a.Dispatch(Command{Action: "search", Scope: "open", Query: "needle"})
	if len(matches(t, s)) != 1 || len(s.OpenDocuments) != 1 || s.Path != other {
		t.Fatal("closed document remained in search scope")
	}
}
func TestFolderSearchDiscoversFilesWithoutOpeningThem(t *testing.T) {
	a, p := fixture(t)
	root := filepath.Dir(p)
	a.Dispatch(Command{Action: "open", Path: root})
	nested := filepath.Join(root, "nested", "match.markdown")
	writeNote(t, nested, "needle one\nneedle two")
	writeNote(t, filepath.Join(root, ".hidden", "secret.md"), "needle")
	writeNote(t, filepath.Join(root, "ignored.txt"), "needle")
	outside := filepath.Join(t.TempDir(), "outside.md")
	writeNote(t, outside, "needle")
	if e := os.Symlink(outside, filepath.Join(root, "escape.md")); e != nil {
		t.Fatal(e)
	}
	writeNote(t, filepath.Join(root, "binary.md"), "\x00needle")
	s := a.Dispatch(Command{Action: "search", Scope: "folder", Query: "needle"})
	m := matches(t, s)
	if len(m) != 2 || m[0].Path != nested || m[1].Line != 2 || len(s.OpenDocuments) != 0 || s.Path != "" {
		t.Fatalf("folder scope leaked, missed new file, or opened result: %+v", s)
	}
	if len(s.Search.Warnings) == 0 {
		t.Fatal("skipped files were silently hidden")
	}
}
func TestSearchLimitsAndInvalidScopes(t *testing.T) {
	a, p := fixture(t)
	a.Dispatch(Command{Action: "open", Path: p})
	a.Dispatch(Command{Action: "edit", Text: strings.Repeat("needle\n", 1002)})
	s := a.Dispatch(Command{Action: "search", Scope: "current", Query: "needle"})
	if len(matches(t, s)) != 1000 || !s.Search.Truncated {
		t.Fatal("search did not bound results")
	}
	for _, c := range []Command{{Action: "search", Scope: "folder", Query: "needle"}, {Action: "search", Scope: "other", Query: "needle"}} {
		if a.Dispatch(c).Error == "" {
			t.Fatal("invalid search scope accepted")
		}
	}
	s = a.Dispatch(Command{Action: "search", Scope: "current", Query: ""})
	if len(matches(t, s)) != 0 {
		t.Fatal("empty query matched")
	}
}
