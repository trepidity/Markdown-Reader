package document

import (
	"bytes"
	"crypto/sha256"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"unicode/utf8"
)

const MaxSize = 16 << 20

type Document struct {
	Path, Text    string
	Revision      uint64
	info          os.FileInfo
	staleConflict bool
	saved         [32]byte
	history       []string
	index         int
}

func Open(path string) (*Document, error) {
	p, e := filepath.Abs(path)
	if e != nil {
		return nil, e
	}
	p, e = filepath.EvalSymlinks(p)
	if e != nil {
		return nil, e
	}
	info, e := os.Stat(p)
	if e != nil {
		return nil, e
	}
	if !info.Mode().IsRegular() || info.Size() > MaxSize {
		return nil, errors.New("open a regular UTF-8 text file smaller than 16 MiB")
	}
	b, e := os.ReadFile(p)
	if e != nil {
		return nil, e
	}
	if len(b) > MaxSize {
		return nil, errors.New("file exceeds 16 MiB")
	}
	if !utf8.Valid(b) || bytes.IndexByte(b, 0) >= 0 {
		return nil, errors.New("file is not UTF-8 text")
	}
	return &Document{Path: p, Text: string(b), Revision: 1, info: info, saved: sha256.Sum256(b), history: []string{string(b)}}, nil
}
func (d *Document) Dirty() bool   { return sha256.Sum256([]byte(d.Text)) != d.saved }
func (d *Document) CanUndo() bool { return d.index > 0 }
func (d *Document) CanRedo() bool { return d.index+1 < len(d.history) }
func (d *Document) Edit(text string, revision ...uint64) error {
	if len(revision) > 0 && revision[0] != 0 && revision[0] != d.Revision {
		d.staleConflict = true
	}
	if text != d.Text {
		d.history = append(d.history[:d.index+1], text)
		d.index++
		d.Text = text
		// Bound snapshot history by memory, retaining at least one undo step.
		total := 0
		for _, h := range d.history {
			total += len(h)
		}
		for len(d.history) > 2 && (total > 32<<20 || len(d.history) > 500) {
			total -= len(d.history[0])
			d.history = d.history[1:]
			d.index--
		}
	}
	return d.Save()
}
func (d *Document) Undo() error {
	if d.CanUndo() {
		d.index--
		d.Text = d.history[d.index]
	}
	return d.Save()
}
func (d *Document) Redo() error {
	if d.CanRedo() {
		d.index++
		d.Text = d.history[d.index]
	}
	return d.Save()
}
func (d *Document) Save() error {
	if len(d.Text) > MaxSize {
		return errors.New("document exceeds 16 MiB; shorten the retained draft or use Save Copy")
	}
	if !d.Dirty() {
		d.staleConflict = false
		return nil
	}
	if d.staleConflict {
		return errors.New("file reloaded while you were typing; your draft is retained. Use Save Copy or Reload")
	}
	b, e := os.ReadFile(d.Path)
	if e != nil {
		return e
	}
	if sha256.Sum256(b) != d.saved {
		return errors.New("file changed outside the app; your draft is retained. Use Save Copy to preserve it, or Reload to discard it")
	}
	info, e := os.Stat(d.Path)
	if e != nil {
		return e
	}
	if e = AtomicWrite(d.Path, []byte(d.Text), info.Mode().Perm()); e != nil {
		return e
	}
	d.saved = sha256.Sum256([]byte(d.Text))
	d.info, _ = os.Stat(d.Path)
	d.staleConflict = false
	return nil
}
func (d *Document) SaveAs(path string) error {
	p, e := filepath.Abs(path)
	if e != nil {
		return e
	}
	if p == d.Path {
		return d.Save()
	}
	// Exclusive creation avoids replacing a file selected after an earlier dialog check.
	f, e := os.OpenFile(p, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0600)
	if e != nil {
		return fmt.Errorf("choose a new filename: %w", e)
	}
	_, e = f.WriteString(d.Text)
	if e == nil {
		e = f.Sync()
	}
	ce := f.Close()
	if e == nil {
		e = ce
	}
	if e != nil {
		os.Remove(p)
		return e
	}
	d.Path = p
	d.saved = sha256.Sum256([]byte(d.Text))
	d.info, _ = os.Stat(d.Path)
	d.staleConflict = false
	return nil
}
func AtomicWrite(path string, data []byte, mode os.FileMode) error {
	f, e := os.CreateTemp(filepath.Dir(path), ".markdown-viewer-*")
	if e != nil {
		return e
	}
	name := f.Name()
	defer os.Remove(name)
	if e = f.Chmod(mode); e == nil {
		_, e = f.Write(data)
	}
	if e == nil {
		e = f.Sync()
	}
	ce := f.Close()
	if e == nil {
		e = ce
	}
	if e != nil {
		return e
	}
	return os.Rename(name, path)
}

// Refresh replaces only clean content. Metadata avoids rereading unchanged files;
// inode identity also catches atomic replacements with preserved timestamps.
func (d *Document) Refresh() (bool, error) {
	info, err := os.Stat(d.Path)
	if err != nil {
		return false, err
	}
	if d.info != nil && os.SameFile(info, d.info) && info.Size() == d.info.Size() && info.ModTime() == d.info.ModTime() && info.Mode() == d.info.Mode() {
		return false, nil
	}
	next, err := Open(d.Path)
	if err != nil {
		return false, err
	}
	if next.saved == d.saved {
		d.info = next.info
		return false, nil
	}
	if d.Dirty() {
		return false, errors.New("file changed outside the app; your draft is retained. Use Save Copy or Reload")
	}
	d.Text = next.Text
	d.saved = next.saved
	d.info = next.info
	d.history = []string{d.Text}
	d.index = 0
	d.Revision++
	d.staleConflict = false
	return true, nil
}
