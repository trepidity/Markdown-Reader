package app

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestLiveReloadUpdatesDocumentsAndSearchButKeepsOwnUndo(t *testing.T) {
	a, p := fixture(t)
	a.Dispatch(Command{Action: "open", Path: p})
	writeNote(t, p, "# External refresh\n")
	s := a.Dispatch(Command{Action: "refresh"})
	if s.Error != "" || s.Text != "# External refresh\n" || !strings.Contains(s.HTML, "External refresh") || len(s.ReloadedPaths) != 1 || s.CanUndo || s.Folder != "" {
		t.Fatal("external change did not refresh a standalone preview")
	}
	a.Dispatch(Command{Action: "edit", Text: "Local edit"})
	s = a.Dispatch(Command{Action: "refresh"})
	if !s.Unchanged {
		t.Fatal("own save triggered external reload")
	}
	a.Dispatch(Command{Action: "undo"})
	if disk(t, p) != "# External refresh\n" {
		t.Fatal("polling cleared own undo history")
	}
	other := filepath.Join(filepath.Dir(p), "other.md")
	writeNote(t, other, "Other")
	a.Dispatch(Command{Action: "open", Path: other})
	writeNote(t, p, "background needle")
	s = a.Dispatch(Command{Action: "refresh"})
	if s.Path != other || s.Text != "Other" {
		t.Fatal("inactive refresh switched the current document")
	}
	m := matches(t, a.Dispatch(Command{Action: "search", Scope: "open", Query: "needle"}))
	if len(m) != 1 || m[0].Path != p {
		t.Fatal("open-document search stayed stale")
	}
	a.Dispatch(Command{Action: "navigate", Path: p})
	info, _ := os.Stat(p)
	replacement := filepath.Join(filepath.Dir(p), "replacement.md")
	writeNote(t, replacement, "replacement words")
	if e := os.Chtimes(replacement, info.ModTime(), info.ModTime()); e != nil {
		t.Fatal(e)
	}
	if e := os.Rename(replacement, p); e != nil {
		t.Fatal(e)
	}
	s = a.Dispatch(Command{Action: "refresh"})
	if s.Text != "replacement words" {
		t.Fatal("atomic replacement with matching size and timestamp was missed")
	}
}
func TestLiveReloadPreservesDraftAndRecoversAfterFileReturns(t *testing.T) {
	a, p := fixture(t)
	a.Dispatch(Command{Action: "open", Path: p})
	writeNote(t, p, "External")
	a.Dispatch(Command{Action: "edit", Text: "Retained draft"})
	s := a.Dispatch(Command{Action: "refresh"})
	if s.Text != "Retained draft" || !s.Dirty || s.WatchError == "" || disk(t, p) != "External" {
		t.Fatal("refresh clobbered conflicting draft")
	}
	a.Dispatch(Command{Action: "reload"})
	if e := os.Remove(p); e != nil {
		t.Fatal(e)
	}
	s = a.Dispatch(Command{Action: "refresh"})
	if s.WatchError == "" || s.Text != "External" {
		t.Fatal("missing file destroyed last good content")
	}
	writeNote(t, p, "Restored")
	s = a.Dispatch(Command{Action: "refresh"})
	if s.WatchError != "" || s.Text != "Restored" {
		t.Fatal("viewer did not recover after file returned")
	}
	writeNote(t, p, "\xffinvalid")
	s = a.Dispatch(Command{Action: "refresh"})
	if s.WatchError == "" || s.Text != "Restored" {
		t.Fatal("invalid streaming content replaced good document")
	}
	writeNote(t, p, "Valid again")
	s = a.Dispatch(Command{Action: "refresh"})
	if s.WatchError != "" || s.Text != "Valid again" {
		t.Fatal("valid content did not recover")
	}
}
func TestTypingAgainstPreReloadRevisionCannotOverwriteExternalContent(t *testing.T) {
	a, p := fixture(t)
	before := a.Dispatch(Command{Action: "open", Path: p})
	if before.Revision == 0 {
		t.Fatal("missing document revision")
	}
	writeNote(t, p, "New external version")
	a.Dispatch(Command{Action: "refresh"})
	s := a.Dispatch(Command{Action: "edit", Path: p, Revision: before.Revision, Text: "Typed against the previous view"})
	if s.Error == "" || !s.Dirty || s.Text != "Typed against the previous view" || disk(t, p) != "New external version" {
		t.Fatal("reload and queued edit race silently overwrote external content")
	}
	s = a.Dispatch(Command{Action: "flush"})
	if s.Error == "" || !s.Dirty {
		t.Fatal("retry bypassed stale-view conflict")
	}
	s = a.Dispatch(Command{Action: "reload"})
	if s.Text != "New external version" || s.Dirty {
		t.Fatal("explicit reload did not recover from stale edit")
	}
}
