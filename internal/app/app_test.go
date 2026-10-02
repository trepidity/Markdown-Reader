package app

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func fixture(t *testing.T) (*App, string) {
	t.Helper()
	dir := t.TempDir()
	dir, err := filepath.EvalSymlinks(dir)
	if err != nil {
		t.Fatal(err)
	}
	p := filepath.Join(dir, "note.md")
	if err := os.WriteFile(p, []byte("# Original\n"), 0640); err != nil {
		t.Fatal(err)
	}
	return New(filepath.Join(dir, "settings.json")), p
}
func disk(t *testing.T, p string) string {
	t.Helper()
	b, e := os.ReadFile(p)
	if e != nil {
		t.Fatal(e)
	}
	return string(b)
}
func TestLiveEditUndoRedoAndRecents(t *testing.T) {
	a, p := fixture(t)
	s := a.Dispatch(Command{Action: "open", Path: p})
	if !strings.Contains(s.HTML, "<h1") || !strings.Contains(s.HTML, "Original") {
		t.Fatalf("preview missing: %+v", s)
	}
	s = a.Dispatch(Command{Action: "edit", Text: "# Changed\n"})
	if s.Error != "" || disk(t, p) != "# Changed\n" || !s.CanUndo {
		t.Fatalf("live edit not saved: %+v", s)
	}
	a.Dispatch(Command{Action: "undo"})
	if disk(t, p) != "# Original\n" {
		t.Fatal("undo did not persist")
	}
	a.Dispatch(Command{Action: "redo"})
	if disk(t, p) != "# Changed\n" {
		t.Fatal("redo did not persist")
	}
	info, _ := os.Stat(p)
	if info.Mode().Perm() != 0640 {
		t.Fatal("save lost permissions")
	}
	s = New(filepath.Join(filepath.Dir(p), "settings.json")).Dispatch(Command{Action: "state"})
	if len(s.Recent) != 1 || s.Recent[0] != p {
		t.Fatal("recent files not persisted")
	}
}
func TestExternalChangeBlocksSaveAndNavigation(t *testing.T) {
	a, p := fixture(t)
	a.Dispatch(Command{Action: "open", Path: p})
	if err := os.WriteFile(p, []byte("External"), 0640); err != nil {
		t.Fatal(err)
	}
	s := a.Dispatch(Command{Action: "edit", Text: "My unsaved draft"})
	if s.Error == "" || !s.Dirty || disk(t, p) != "External" {
		t.Fatalf("conflicting edit overwrote disk: %+v", s)
	}
	other := filepath.Join(filepath.Dir(p), "other.md")
	os.WriteFile(other, []byte("Other"), 0600)
	s = a.Dispatch(Command{Action: "open", Path: other})
	if s.Error == "" || s.Path != p || s.Text != "My unsaved draft" {
		t.Fatalf("navigation lost draft: %+v", s)
	}
	copy := filepath.Join(filepath.Dir(p), "recovered.md")
	s = a.Dispatch(Command{Action: "saveAs", Path: copy})
	if s.Error != "" || disk(t, copy) != "My unsaved draft" || disk(t, p) != "External" {
		t.Fatal("save copy failed")
	}
}
func TestFolderModeAndThemePersistence(t *testing.T) {
	a, p := fixture(t)
	s := a.Dispatch(Command{Action: "open", Path: filepath.Dir(p)})
	if s.Folder != filepath.Dir(p) || len(s.Files) != 1 || s.Path != "" {
		t.Fatalf("folder mode: %+v", s)
	}
	a.Dispatch(Command{Action: "settings", Theme: "night", Style: "serif"})
	s = New(filepath.Join(filepath.Dir(p), "settings.json")).Dispatch(Command{Action: "state"})
	if s.Theme != "night" || s.Style != "serif" {
		t.Fatal("settings not durable")
	}
}
func TestMarkdownCannotExecuteOrLoadRemoteContent(t *testing.T) {
	a, p := fixture(t)
	a.Dispatch(Command{Action: "open", Path: p})
	s := a.Dispatch(Command{Action: "edit", Text: "# Safe\n\n<script>alert(1)</script>\n\n[bad](javascript&#58;alert(1))\n\n![tracking](https://example.com/pixel.png)\n\n| A | B |\n|---|---|\n| 1 | 2 |"})
	if strings.Contains(s.HTML, "javascript:") || strings.Contains(s.HTML, "<script") || strings.Contains(s.HTML, `src="https:`) || !strings.Contains(s.HTML, "<table>") {
		t.Fatalf("unsafe or incomplete render: %s", s.HTML)
	}
}

func TestDocumentHeadingsCannotShadowEditorControls(t *testing.T) {
	a, p := fixture(t)
	a.Dispatch(Command{Action: "open", Path: p})
	s := a.Dispatch(Command{Action: "edit", Text: "# editor\n\n[Jump](#editor)"})
	if strings.Contains(s.HTML, `id="editor"`) || !strings.Contains(s.HTML, `id="md-editor"`) {
		t.Fatalf("document heading shadows app control: %s", s.HTML)
	}
}

func TestOversizeEditRemainsRecoverableAndBlocksNavigation(t *testing.T) {
	a, p := fixture(t)
	a.Dispatch(Command{Action: "open", Path: p})
	draft := strings.Repeat("x", (16<<20)+1)
	s := a.Dispatch(Command{Action: "edit", Text: draft})
	if s.Error == "" || !s.Dirty || s.Text != draft || disk(t, p) != "# Original\n" {
		t.Fatal("rejected edit lost its draft or modified disk")
	}
	s = a.Dispatch(Command{Action: "flush"})
	if s.Error == "" || !s.Dirty {
		t.Fatal("oversize draft did not block close")
	}
}
