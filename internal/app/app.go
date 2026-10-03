package app

import (
	"encoding/json"
	"errors"
	"markdownviewer/internal/document"
	"os"
	"path/filepath"
	"strings"
)

type Command struct {
	Revision     uint64 `json:"revision"`
	Query        string `json:"query"`
	Scope        string `json:"scope"`
	MatchCase    bool   `json:"matchCase"`
	SidebarWidth int    `json:"sidebarWidth"`
	Action       string `json:"action"`
	Path         string `json:"path"`
	Text         string `json:"text"`
	Theme        string `json:"theme"`
	Style        string `json:"style"`
}
type State struct {
	Revision      uint64        `json:"revision"`
	Unchanged     bool          `json:"unchanged,omitempty"`
	ReloadedPaths []string      `json:"reloadedPaths,omitempty"`
	WatchError    string        `json:"watchError,omitempty"`
	Search        *SearchResult `json:"search,omitempty"`
	OpenDocuments []string      `json:"openDocuments"`
	SidebarWidth  int           `json:"sidebarWidth"`
	Path          string        `json:"path"`
	Text          string        `json:"text"`
	HTML          string        `json:"html"`
	Error         string        `json:"error"`
	Dirty         bool          `json:"dirty"`
	CanUndo       bool          `json:"canUndo"`
	CanRedo       bool          `json:"canRedo"`
	Recent        []string      `json:"recent"`
	Folder        string        `json:"folder"`
	Files         []string      `json:"files"`
	Theme         string        `json:"theme"`
	Style         string        `json:"style"`
}
type settings struct {
	SidebarWidth int      `json:"sidebarWidth"`
	Recent       []string `json:"recent"`
	Theme        string   `json:"theme"`
	Style        string   `json:"style"`
}
type App struct {
	doc           *document.Document
	documents     map[string]*document.Document
	documentOrder []string
	config        string
	settings      settings
	folder        string
	files         []string
	startupError  error
	watchErrors   map[string]string
}

func New(config string) *App {
	a := &App{watchErrors: make(map[string]string), documents: make(map[string]*document.Document), config: config, settings: settings{Theme: "paper", Style: "serif", SidebarWidth: 235}}
	b, e := os.ReadFile(config)
	if e == nil {
		e = json.Unmarshal(b, &a.settings)
	}
	if e != nil && !os.IsNotExist(e) {
		a.startupError = e
	}
	if a.settings.SidebarWidth < 160 || a.settings.SidebarWidth > 600 {
		a.settings.SidebarWidth = 235
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
func (a *App) open(path string, preserveFolder bool) error {
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
		files, e := markdownFiles(p)
		if e != nil {
			return e
		}
		a.folder = p
		a.files = files
		return nil
	}
	p, e = filepath.EvalSymlinks(p)
	if e != nil {
		return e
	}
	d := a.documents[p]
	if d == nil {
		d, e = document.Open(p)
		if e != nil {
			return e
		}
		a.documents[p] = d
		a.documentOrder = append(a.documentOrder, p)
	}
	a.doc = d
	if !preserveFolder {
		a.folder = ""
		a.files = nil
	}
	return a.recent(d.Path)
}
func (a *App) Dispatch(c Command) State {
	var e error
	var search *SearchResult
	var reloaded []string
	switch c.Action {
	case "refresh":
		previous := a.watchError()
		for _, p := range a.documentOrder {
			changed, err := a.documents[p].Refresh()
			delete(a.watchErrors, p)
			if err != nil {
				a.watchErrors[p] = filepath.Base(p) + ": " + err.Error()
			}
			if changed {
				reloaded = append(reloaded, p)
			}
		}
		if len(reloaded) == 0 && previous == a.watchError() {
			return State{Unchanged: true}
		}
	case "search":
		search, e = a.search(c)
	case "closeDocument":
		if e = a.flush(); e == nil && a.doc != nil {
			a.forget(a.doc.Path)
			a.doc = nil
			if len(a.documentOrder) > 0 {
				a.doc = a.documents[a.documentOrder[len(a.documentOrder)-1]]
			}
		}
	case "state":
		e = a.startupError
		a.startupError = nil
	case "open":
		e = a.open(c.Path, false)
	case "navigate":
		e = a.open(c.Path, true)
	case "edit":
		if a.doc != nil {
			if c.Path != "" && c.Path != a.doc.Path {
				e = errors.New("document changed before edit could be applied")
			} else {
				e = a.doc.Edit(c.Text, c.Revision)
			}
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
				a.documents[d.Path] = d
				delete(a.watchErrors, d.Path)
			}
		}
	case "saveAs":
		if a.doc != nil {
			previousPath := a.doc.Path
			e = a.doc.SaveAs(c.Path)
			if e == nil {
				if previousPath != a.doc.Path {
					a.forget(previousPath)
					a.documents[a.doc.Path] = a.doc
					a.documentOrder = append(a.documentOrder, a.doc.Path)
				}
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
					e = a.open(c.Path, false)
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
	case "sidebarWidth":
		if c.SidebarWidth < 160 || c.SidebarWidth > 600 {
			e = errors.New("sidebar width must be between 160 and 600 pixels")
		} else {
			previous := a.settings.SidebarWidth
			a.settings.SidebarWidth = c.SidebarWidth
			e = a.persist()
			if e != nil {
				a.settings.SidebarWidth = previous
			}
		}
	case "closeFolder":
		a.folder = ""
		a.files = nil
	default:
		e = errors.New("unknown command")
	}
	s := State{ReloadedPaths: reloaded, WatchError: a.watchError(), Search: search, OpenDocuments: append([]string{}, a.documentOrder...), SidebarWidth: a.settings.SidebarWidth, Recent: a.settings.Recent, Theme: a.settings.Theme, Style: a.settings.Style, Folder: a.folder, Files: a.files}
	if a.doc != nil {
		s.Path = a.doc.Path
		s.Revision = a.doc.Revision
		if c.Action != "search" {
			s.Text = a.doc.Text
			s.HTML = document.Render(a.doc.Text, a.doc.Path)
		}
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

func (a *App) forget(path string) {
	delete(a.documents, path)
	delete(a.watchErrors, path)
	for i, p := range a.documentOrder {
		if p == path {
			a.documentOrder = append(a.documentOrder[:i], a.documentOrder[i+1:]...)
			break
		}
	}
}

func (a *App) watchError() string {
	var messages []string
	for _, p := range a.documentOrder {
		if message := a.watchErrors[p]; message != "" {
			messages = append(messages, message)
		}
	}
	return strings.Join(messages, "\n")
}
