package main

import (
	"fmt"
	"gioui.org/app"
	"gioui.org/font"
	"gioui.org/font/gofont"
	"gioui.org/io/key"
	"gioui.org/layout"
	"gioui.org/op"
	"gioui.org/op/paint"
	"gioui.org/text"
	"gioui.org/unit"
	"gioui.org/widget"
	"gioui.org/widget/material"
	"gioui.org/x/richtext"
	"image/color"
	"markdownviewer/comparison/session"
	core "markdownviewer/internal/app"
	"os"
	"path/filepath"
	"strings"
	"time"
	"unicode/utf16"
)

type viewer struct {
	w                   *app.Window
	engine              *session.Session
	state               session.State
	theme               *material.Theme
	path, query, editor widget.Editor
	list                widget.List
	buttons             map[string]*widget.Clickable
	spans               []richtext.InteractiveText
	editing             bool
	status              string
	scope               int
	matches             []core.SearchMatch
	show                string
	lastRefresh         time.Time
}

func (v *viewer) cmd(c core.Command) session.State {
	s := v.engine.Dispatch(c)
	if c.Action == "search" || s.Unchanged {
		return s
	}
	if c.Action == "refresh" {
		reload := false
		for _, p := range s.ReloadedPaths {
			if p == v.state.Path {
				reload = true
			}
		}
		if !reload {
			if s.WatchError != "" {
				v.status = s.WatchError
			}
			return s
		}
	}
	changed := s.Path != v.state.Path
	redraw := changed || s.HTML != v.state.HTML
	v.state = s
	if changed {
		v.editor.SetText("")
	} else if v.editing && (c.Action == "undo" || c.Action == "redo" || c.Action == "reload" || c.Action == "refresh") {
		v.editor.SetText(s.Text)
	}
	if changed {
		v.editing = false
		v.list.Position = layout.Position{}
		v.w.Option(app.Title(filepath.Base(s.Path) + " — Gio"))
	}
	if redraw {
		v.spans = make([]richtext.InteractiveText, len(s.Blocks))
	}
	v.status = "All changes saved — Gio"
	if s.Dirty {
		v.status = "Unsaved changes"
	}
	if s.Error != "" {
		v.status = s.Error
	}
	return s
}
func (v *viewer) button(gtx layout.Context, id, label string, f func()) layout.Dimensions {
	b := v.buttons[id]
	if b == nil {
		b = new(widget.Clickable)
		v.buttons[id] = b
	}
	for b.Clicked(gtx) {
		f()
	}
	return layout.Inset{Right: 6, Bottom: 4}.Layout(gtx, material.Button(v.theme, b, label).Layout)
}
func (v *viewer) row(gtx layout.Context, children ...layout.FlexChild) layout.Dimensions {
	return layout.Flex{Axis: layout.Horizontal, Alignment: layout.Middle}.Layout(gtx, children...)
}
func (v *viewer) btn(id, label string, f func()) layout.FlexChild {
	return layout.Rigid(func(gtx layout.Context) layout.Dimensions { return v.button(gtx, id, label, f) })
}
func (v *viewer) field(e *widget.Editor, hint string) layout.FlexChild {
	return layout.Flexed(1, func(gtx layout.Context) layout.Dimensions {
		return layout.UniformInset(8).Layout(gtx, material.Editor(v.theme, e, hint).Layout)
	})
}
func (v *viewer) find() {
	s := v.cmd(core.Command{Action: "search", Query: v.query.Text(), Scope: []string{"current", "open", "folder"}[v.scope]})
	v.matches = s.Search.Matches
	v.show = "matches"
	v.status = fmt.Sprintf("%d matches", len(v.matches))
	v.list.Position = layout.Position{}
}
func (v *viewer) link(href string) {
	if strings.HasPrefix(href, "#") {
		for i, b := range v.state.Blocks {
			if b.ID == strings.TrimPrefix(href, "#") || b.ID == "md-"+strings.TrimPrefix(href, "#") {
				v.list.Position = layout.Position{First: i}
				break
			}
		}
		return
	}
	if strings.HasPrefix(href, "https:") || strings.HasPrefix(href, "http:") || strings.HasPrefix(href, "mailto:") {
		openURL(href)
		return
	}
	v.cmd(core.Command{Action: "navigateLink", Path: v.state.Path, Href: href})
}
func (v *viewer) block(gtx layout.Context, i int) layout.Dimensions {
	b := v.state.Blocks[i]
	st := &v.spans[i]
	for {
		span, e, ok := st.Update(gtx)
		if !ok {
			break
		}
		if e.Type == richtext.Click {
			if h := span.Get("href"); h != nil {
				v.link(h.(string))
			}
		}
	}
	var styles []richtext.SpanStyle
	size := unit.Sp(17)
	if b.Kind == "heading" {
		size = unit.Sp(36 - b.Level*3)
	}
	add := func(r session.Run) {
		s := richtext.SpanStyle{Content: r.Text, Size: size, Color: v.theme.Fg}
		if r.Bold || b.Kind == "heading" {
			s.Font.Weight = font.Bold
		}
		if r.Italic {
			s.Font.Style = font.Italic
		}
		if r.Mono {
			s.Font.Typeface = "Go Mono"
			s.Size = 14
		}
		if r.Image != "" {
			s.Content = "[Image: " + r.Text + "]"
		}
		if r.Href != "" {
			s.Interactive = true
			s.Set("href", r.Href)
			s.Color = color.NRGBA{60, 130, 230, 255}
		}
		styles = append(styles, s)
	}
	if b.Kind == "table" {
		for _, row := range b.Rows {
			for j, cell := range row {
				if j > 0 {
					add(session.Run{Text: "     │     "})
				}
				for _, r := range cell {
					add(r)
				}
			}
			add(session.Run{Text: "\n"})
		}
	} else if b.Kind == "rule" {
		add(session.Run{Text: "────────────────────────"})
	} else {
		for _, r := range b.Runs {
			add(r)
		}
	}
	return layout.Inset{Left: 24, Right: 24, Top: 8, Bottom: 8}.Layout(gtx, richtext.Text(st, v.theme.Shaper, styles...).Layout)
}
func (v *viewer) draw(gtx layout.Context) layout.Dimensions {
	for {
		e, ok := v.editor.Update(gtx)
		if !ok {
			break
		}
		if _, ok := e.(widget.ChangeEvent); ok {
			v.cmd(core.Command{Action: "edit", Path: v.state.Path, Revision: v.state.Revision, Text: v.editor.Text()})
		}
	}
	for {
		e, ok := v.path.Update(gtx)
		if !ok {
			break
		}
		if _, ok := e.(widget.SubmitEvent); ok {
			v.cmd(core.Command{Action: "open", Path: v.path.Text()})
			v.show = ""
		}
	}
	for {
		e, ok := v.query.Update(gtx)
		if !ok {
			break
		}
		if _, ok := e.(widget.SubmitEvent); ok {
			v.find()
		}
	}
	if time.Since(v.lastRefresh) > 750*time.Millisecond && len(v.state.OpenDocuments) > 0 {
		v.cmd(core.Command{Action: "refresh"})
		v.lastRefresh = time.Now()
	}
	if v.state.Theme == "night" {
		v.theme.Palette = material.Palette{Bg: color.NRGBA{32, 34, 38, 255}, Fg: color.NRGBA{244, 244, 244, 255}, ContrastBg: color.NRGBA{53, 105, 180, 255}, ContrastFg: color.NRGBA{255, 255, 255, 255}}
	} else {
		bg := color.NRGBA{250, 250, 250, 255}
		if v.state.Theme == "sepia" {
			bg = color.NRGBA{242, 232, 212, 255}
		}
		v.theme.Palette = material.Palette{Bg: bg, Fg: color.NRGBA{32, 32, 32, 255}, ContrastBg: color.NRGBA{48, 90, 155, 255}, ContrastFg: color.NRGBA{255, 255, 255, 255}}
	}
	paint.Fill(gtx.Ops, v.theme.Bg)
	return layout.UniformInset(10).Layout(gtx, func(gtx layout.Context) layout.Dimensions {
		return layout.Flex{Axis: layout.Vertical}.Layout(gtx,
			layout.Rigid(func(gtx layout.Context) layout.Dimensions {
				return v.row(gtx, v.btn("open", "Open…", func() {
					if p := choosePath(false); p != "" {
						v.cmd(core.Command{Action: "open", Path: p})
						v.show = ""
					}
				}), v.field(&v.path, "File or folder path"), v.btn("load", "Load path", func() { v.cmd(core.Command{Action: "open", Path: v.path.Text()}); v.show = "" }), v.btn("mode", "Preview / Edit", func() {
					v.editing = !v.editing
					v.show = ""
					if v.editing {
						v.editor.SetText(v.state.Text)
						gtx.Execute(key.FocusCmd{Tag: &v.editor})
					}
				}), v.btn("undo", "Undo", func() { v.cmd(core.Command{Action: "undo"}) }), v.btn("redo", "Redo", func() { v.cmd(core.Command{Action: "redo"}) }), v.btn("save", "Save Copy…", func() {
					if p := choosePath(true); p != "" {
						v.cmd(core.Command{Action: "saveAs", Path: p})
					}
				}))
			}),
			layout.Rigid(func(gtx layout.Context) layout.Dimensions {
				return v.row(gtx, v.btn("files", "Folder files", func() { v.show = "files"; v.list.Position = layout.Position{} }), v.btn("docs", "Open / recent", func() { v.show = "docs"; v.list.Position = layout.Position{} }), v.btn("close", "Close document", func() { v.cmd(core.Command{Action: "closeDocument"}) }), v.btn("reload", "Reload…", func() {
					if confirmReload() {
						v.cmd(core.Command{Action: "reload"})
					}
				}), v.btn("theme", "Theme: "+v.state.Theme, func() {
					t := "paper"
					if v.state.Theme == "paper" {
						t = "night"
					} else if v.state.Theme == "night" {
						t = "sepia"
					}
					v.cmd(core.Command{Action: "settings", Theme: t, Style: "serif"})
				}))
			}),
			layout.Rigid(func(gtx layout.Context) layout.Dimensions {
				return v.row(gtx, v.field(&v.query, "Find text"), v.btn("scope", "Scope: "+[]string{"current", "open", "folder"}[v.scope], func() { v.scope = (v.scope + 1) % 3 }), v.btn("find", "Find", v.find), v.btn("back", "Document", func() { v.show = "" }))
			}),
			layout.Rigid(func(gtx layout.Context) layout.Dimensions { return material.Caption(v.theme, v.status).Layout(gtx) }),
			layout.Flexed(1, func(gtx layout.Context) layout.Dimensions {
				if v.show != "" {
					var paths []string
					if v.show == "files" {
						paths = v.state.Files
					} else if v.show == "docs" {
						seen := map[string]bool{}
						for _, p := range append(append([]string{}, v.state.OpenDocuments...), v.state.Recent...) {
							if !seen[p] {
								paths = append(paths, p)
								seen[p] = true
							}
						}
					} else {
						for _, m := range v.matches {
							paths = append(paths, fmt.Sprintf("%s:%d %s", filepath.Base(m.Path), m.Line, m.Snippet))
						}
					}
					return material.List(v.theme, &v.list).Layout(gtx, len(paths), func(gtx layout.Context, i int) layout.Dimensions {
						return v.button(gtx, fmt.Sprintf("item-%d", i), paths[i], func() {
							p := paths[i]
							match := v.show == "matches"
							if match {
								p = v.matches[i].Path
							}
							s := v.cmd(core.Command{Action: "navigate", Path: p})
							if s.Error == "" {
								v.show = ""
								if match {
									v.editing = true
									v.editor.SetText(s.Text)
									m := v.matches[i]
									u := utf16.Encode([]rune(s.Text))
									start, end := min(m.Start, len(u)), min(m.End, len(u))
									v.editor.SetCaret(len(utf16.Decode(u[:start])), len(utf16.Decode(u[:end])))
								}
							}
						})
					})
				}
				if v.editing {
					return layout.UniformInset(24).Layout(gtx, material.Editor(v.theme, &v.editor, "Markdown source").Layout)
				}
				if len(v.state.Blocks) == 0 {
					return material.H5(v.theme, "Open a Markdown document to compare Gio rendering.").Layout(gtx)
				}
				return material.List(v.theme, &v.list).Layout(gtx, len(v.state.Blocks), v.block)
			}))
	})
}
func main() {
	go func() {
		w := new(app.Window)
		w.Option(app.Title("Markdown Viewer — Gio"), app.Size(unit.Dp(1080), unit.Dp(780)))
		v := &viewer{w: w, engine: session.New(session.Config("Gio")), theme: material.NewTheme(), buttons: map[string]*widget.Clickable{}}
		v.theme.Shaper = text.NewShaper(text.WithCollection(gofont.Collection()))
		v.path.SingleLine = true
		v.path.Submit = true
		v.query.SingleLine = true
		v.query.Submit = true
		v.list.Axis = layout.Vertical
		v.cmd(core.Command{Action: "state"})
		if len(os.Args) > 1 {
			v.cmd(core.Command{Action: "open", Path: os.Args[1]})
		}
		go func() {
			for range time.NewTicker(750 * time.Millisecond).C {
				w.Invalidate()
			}
		}()
		var ops op.Ops
		for {
			switch e := w.Event().(type) {
			case *app.ClosingEvent:
				s := v.cmd(core.Command{Action: "flush"})
				if s.Dirty || s.Error != "" {
					e.Abort()
				}
			case app.DestroyEvent:
				os.Exit(0)
			case app.FrameEvent:
				gtx := app.NewContext(&ops, e)
				v.draw(gtx)
				e.Frame(gtx.Ops)
			}
		}
	}()
	app.Main()
}
