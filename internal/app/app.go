package app

import (
	"encoding/json"
	"errors"
	"io/fs"
	"markdownviewer/internal/document"
	"os"
	"path/filepath"
	"strings"
)

type Command struct {
	Action string `json:"action"`
	Path   string `json:"path"`
	Text   string `json:"text"`
	Theme  string `json:"theme"`
	Style  string `json:"style"`
}
type State struct {
	Path    string   `json:"path"`
	Text    string   `json:"text"`
	HTML    string   `json:"html"`
	Error   string   `json:"error"`
	Dirty   bool     `json:"dirty"`
	CanUndo bool     `json:"canUndo"`
	CanRedo bool     `json:"canRedo"`
	Recent  []string `json:"recent"`
	Folder  string   `json:"folder"`
	Files   []string `json:"files"`
	Theme   string   `json:"theme"`
	Style   string   `json:"style"`
}
type settings struct {
	Recent []string `json:"recent"`
	Theme  string   `json:"theme"`
	Style  string   `json:"style"`
}
type App struct {
	doc          *document.Document
	config       string
	settings     settings
	folder       string
	files        []string
	startupError error
}

func New(config string) *App {
	a := &App{config: config, settings: settings{Theme: "paper", Style: "serif"}}
	b, e := os.ReadFile(config)
	if e == nil {
		e = json.Unmarshal(b, &a.settings)
	}
	if e != nil && !os.IsNotExist(e) {
		a.startupError = e
	}
	return a
}
func (a *App) persist() error {
	if e := os.MkdirAll(filepath.Dir(a.config), 0700); e != nil {
		return e
	}
	b, e := json.MarshalIndent(a.settings, "", "  ")
	if e != nil {
		return e
	}
	return document.AtomicWrite(a.config, b, 0600)
}
func (a *App) recent(p string) error {
	r := []string{p}
	for _, v := range a.settings.Recent {
		if v != p && len(r) < 15 {
			r = append(r, v)
		}
	}
	a.settings.Recent = r
	return a.persist()
}
func (a *App) flush() error {
	if a.doc != nil {
		return a.doc.Save()
	}
	return nil
}
func (a *App) open(path string) error {
	if e := a.flush(); e != nil {
		return e
	}
	p, e := filepath.Abs(path)
	if e != nil {
		return e
	}
	info, e := os.Stat(p)
	if e != nil {
		return e
	}
	if info.IsDir() {
		var files []string
		e = filepath.WalkDir(p, func(path string, d fs.DirEntry, e error) error {
			if e != nil {
				return e
			}
			if d.IsDir() {
				if path != p && strings.HasPrefix(d.Name(), ".") {
					return filepath.SkipDir
				}
				return nil
			}
			ext := strings.ToLower(filepath.Ext(path))
			if ext == ".md" || ext == ".markdown" || ext == ".mdown" {
				files = append(files, path)
			}
			if len(files) > 5000 {
				return errors.New("folder contains more than 5,000 Markdown files")
			}
			return nil
		})
		if e != nil {
			return e
		}
		a.folder = p
		a.files = files
		return nil
	}
	d, e := document.Open(p)
	if e != nil {
		return e
	}
	a.doc = d
	return a.recent(d.Path)
}
func (a *App) Dispatch(c Command) State {
	var e error
	switch c.Action {
	case "state":
		e = a.startupError
		a.startupError = nil
	case "open":
		e = a.open(c.Path)
	case "edit":
		if a.doc != nil {
			e = a.doc.Edit(c.Text)
		} else {
			e = errors.New("open or create a file first")
		}
	case "undo":
		if a.doc != nil {
			e = a.doc.Undo()
		}
	case "redo":
		if a.doc != nil {
			e = a.doc.Redo()
		}
	case "flush":
		e = a.flush()
	case "reload":
		if a.doc != nil {
			var d *document.Document
			d, e = document.Open(a.doc.Path)
			if e == nil {
				a.doc = d
			}
		}
	case "saveAs":
		if a.doc != nil {
			e = a.doc.SaveAs(c.Path)
			if e == nil {
				e = a.recent(a.doc.Path)
			}
		}
	case "new":
		if e = a.flush(); e == nil {
			f, err := os.OpenFile(c.Path, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0600)
			e = err
			if e == nil {
				e = f.Close()
				if e == nil {
					e = a.open(c.Path)
				}
			}
		}
	case "settings":
		if !contains([]string{"paper", "night", "sepia", "system"}, c.Theme) || !contains([]string{"serif", "sans", "mono"}, c.Style) {
			e = errors.New("unknown theme or typography")
		} else {
			a.settings.Theme = c.Theme
			a.settings.Style = c.Style
			e = a.persist()
		}
	case "closeFolder":
		a.folder = ""
		a.files = nil
	default:
		e = errors.New("unknown command")
	}
	s := State{Recent: a.settings.Recent, Theme: a.settings.Theme, Style: a.settings.Style, Folder: a.folder, Files: a.files}
	if a.doc != nil {
		s.Path = a.doc.Path
		s.Text = a.doc.Text
		s.HTML = document.Render(a.doc.Text, a.doc.Path)
		s.Dirty = a.doc.Dirty()
		s.CanUndo = a.doc.CanUndo()
		s.CanRedo = a.doc.CanRedo()
	}
	if e != nil {
		s.Error = e.Error()
	}
	return s
}
func contains(values []string, s string) bool {
	for _, v := range values {
		if s == v {
			return true
		}
	}
	return false
}
