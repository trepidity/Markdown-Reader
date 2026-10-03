package main

import (
	"encoding/base64"
	"fmt"
	"fyne.io/fyne/v2"
	fapp "fyne.io/fyne/v2/app"
	"fyne.io/fyne/v2/canvas"
	"fyne.io/fyne/v2/container"
	"fyne.io/fyne/v2/dialog"
	"fyne.io/fyne/v2/theme"
	"fyne.io/fyne/v2/widget"
	"image/color"
	"markdownviewer/comparison/session"
	core "markdownviewer/internal/app"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"time"
)

type palette struct{ name string }

func (p palette) Color(n fyne.ThemeColorName, v fyne.ThemeVariant) color.Color {
	if p.name == "night" {
		return theme.DefaultTheme().Color(n, theme.VariantDark)
	}
	if n == theme.ColorNameBackground && p.name == "sepia" {
		return color.NRGBA{242, 232, 212, 255}
	}
	return theme.DefaultTheme().Color(n, theme.VariantLight)
}
func (p palette) Font(s fyne.TextStyle) fyne.Resource     { return theme.DefaultTheme().Font(s) }
func (p palette) Icon(n fyne.ThemeIconName) fyne.Resource { return theme.DefaultTheme().Icon(n) }
func (p palette) Size(n fyne.ThemeSizeName) float32       { return theme.DefaultTheme().Size(n) }

type imageSpan struct {
	data []byte
	alt  string
}

func (s *imageSpan) Inline() bool    { return false }
func (s *imageSpan) Textual() string { return s.alt }
func (s *imageSpan) Visual() fyne.CanvasObject {
	i := canvas.NewImageFromResource(fyne.NewStaticResource("embedded", s.data))
	i.FillMode = canvas.ImageFillContain
	i.SetMinSize(fyne.NewSize(400, 200))
	return i
}
func (s *imageSpan) Update(fyne.CanvasObject)            {}
func (s *imageSpan) Select(fyne.Position, fyne.Position) {}
func (s *imageSpan) SelectedText() string                { return "" }
func (s *imageSpan) Unselect()                           {}
func main() {
	a := fapp.NewWithID("org.markdownviewer.comparison.fyne")
	a.Settings().SetTheme(palette{"paper"})
	w := a.NewWindow("Markdown Viewer — Fyne")
	w.Resize(fyne.NewSize(1080, 780))
	engine := session.New(session.Config("Fyne"))
	var state session.State
	applying := false
	editing := false
	path := widget.NewEntry()
	path.SetPlaceHolder("File or folder path")
	query := widget.NewEntry()
	query.SetPlaceHolder("Find text")
	status := widget.NewLabel("Ready")
	editor := widget.NewMultiLineEntry()
	editor.TextStyle = fyne.TextStyle{Monospace: true}
	editor.Wrapping = fyne.TextWrapWord
	preview := container.NewStack()
	content := container.NewStack(preview, editor)
	editor.Hide()
	var command func(core.Command) session.State
	link := func(href string) {
		u, e := url.Parse(href)
		if e != nil {
			return
		}
		if u.Scheme == "https" || u.Scheme == "http" || u.Scheme == "mailto" {
			a.OpenURL(u)
			return
		}
		if strings.HasPrefix(href, "#") {
			status.SetText("Heading-anchor scrolling is not implemented in this comparison build")
			return
		}
		command(core.Command{Action: "navigateLink", Path: state.Path, Href: href})
	}
	segments := func(runs []session.Run, size fyne.ThemeSizeName) []widget.RichTextSegment {
		var out []widget.RichTextSegment
		for _, r := range runs {
			style := fyne.TextStyle{Bold: r.Bold, Italic: r.Italic, Monospace: r.Mono}
			if r.Image != "" {
				parts := strings.SplitN(r.Image, ",", 2)
				if len(parts) == 2 {
					data, e := base64.StdEncoding.DecodeString(parts[1])
					if e == nil {
						out = append(out, &imageSpan{data: data, alt: r.Text})
					}
				}
			} else if r.Href != "" {
				href := r.Href
				u, _ := url.Parse(href)
				out = append(out, &widget.HyperlinkSegment{Text: r.Text, URL: u, TextStyle: style, SizeName: size, OnTapped: func() { link(href) }})
			} else {
				out = append(out, &widget.TextSegment{Text: r.Text, Style: widget.RichTextStyle{Inline: true, TextStyle: style, SizeName: size}})
			}
		}
		return out
	}
	blockSegments := func(b session.Block) []widget.RichTextSegment {
		size := theme.SizeNameText
		if b.Kind == "heading" {
			if b.Level <= 2 {
				size = theme.SizeNameHeadingText
			} else {
				size = theme.SizeNameSubHeadingText
			}
		}
		if b.Kind == "table" {
			t := &widget.TableSegment{}
			for i, row := range b.Rows {
				var cells [][]widget.RichTextSegment
				for _, runs := range row {
					cells = append(cells, segments(runs, size))
				}
				if i == 0 {
					t.Headers = cells
				} else {
					t.Rows = append(t.Rows, cells)
				}
			}
			return []widget.RichTextSegment{t}
		}
		runs := segments(b.Runs, size)
		if b.Kind == "rule" {
			runs = []widget.RichTextSegment{&widget.TextSegment{Text: "────────────────────────"}}
		}
		runs = append(runs, &widget.TextSegment{Style: widget.RichTextStyleParagraph})
		return []widget.RichTextSegment{&widget.ParagraphSegment{Texts: runs}}
	}
	render := func() {
		if len(state.Blocks) == 0 {
			preview.Objects = []fyne.CanvasObject{widget.NewLabel("Open a Markdown document to compare Fyne rendering.")}
			preview.Refresh()
			return
		}
		blocks := state.Blocks
		var list *widget.List
		list = widget.NewList(func() int { return len(blocks) }, func() fyne.CanvasObject { return container.NewStack(widget.NewLabel("Markdown block")) }, func(i widget.ListItemID, obj fyne.CanvasObject) {
			cell := obj.(*fyne.Container)
			rich := widget.NewRichText(blockSegments(blocks[i])...)
			rich.Wrapping = fyne.TextWrapWord
			width := max(float32(200), preview.Size().Width-24)
			rich.Resize(fyne.NewSize(width, 1))
			cell.Objects = []fyne.CanvasObject{rich}
			cell.Refresh()
			list.SetItemHeight(i, rich.MinSize().Height+8)
		})
		list.HideSeparators = true
		preview.Objects = []fyne.CanvasObject{list}
		preview.Refresh()
	}

	files := widget.NewSelect(nil, nil)
	files.PlaceHolder = "Folder files"
	docs := widget.NewSelect(nil, nil)
	docs.PlaceHolder = "Open / recent documents"
	themes := widget.NewSelect([]string{"paper", "night", "sepia"}, nil)
	mode := func() {
		editing = !editing
		if editing {
			applying = true
			editor.SetText(state.Text)
			applying = false
			preview.Hide()
			editor.Show()
			w.Canvas().Focus(editor)
		} else {
			editor.Hide()
			preview.Show()
		}
	}
	command = func(c core.Command) session.State {
		s := engine.Dispatch(c)
		if c.Action == "search" || s.Unchanged {
			return s
		}
		if c.Action == "refresh" {
			reload := false
			for _, p := range s.ReloadedPaths {
				if p == state.Path {
					reload = true
				}
			}
			if !reload {
				if s.WatchError != "" {
					status.SetText(s.WatchError)
				}
				return s
			}
		}
		changed := s.Path != state.Path
		redraw := changed || s.HTML != state.HTML || s.Theme != state.Theme
		themeChanged := s.Theme != state.Theme
		state = s
		applying = true
		if changed {
			editor.SetText("")
		} else if editing && (c.Action == "undo" || c.Action == "redo" || c.Action == "reload" || c.Action == "refresh") {
			editor.SetText(s.Text)
		}
		if changed {
			editing = false
			editor.Hide()
			preview.Show()
			w.SetTitle(filepath.Base(s.Path) + " — Fyne")
		}
		if themeChanged {
			a.Settings().SetTheme(palette{s.Theme})
			themes.SetSelected(s.Theme)
		}
		if redraw {
			render()
		}
		files.Options = append([]string(nil), s.Files...)
		files.ClearSelected()
		files.Refresh()
		seen := map[string]bool{}
		docs.Options = nil
		for _, p := range append(append([]string(nil), s.OpenDocuments...), s.Recent...) {
			if !seen[p] {
				seen[p] = true
				docs.Options = append(docs.Options, p)
			}
		}
		docs.ClearSelected()
		docs.Refresh()
		msg := fmt.Sprintf("All changes saved — Fyne · %d blocks", len(s.Blocks))
		if s.Dirty {
			msg = "Unsaved changes"
		}
		if s.Error != "" {
			msg = s.Error
		}
		status.SetText(msg)
		applying = false
		return s
	}
	editor.OnChanged = func(text string) {
		if !applying {
			command(core.Command{Action: "edit", Path: state.Path, Revision: state.Revision, Text: text})
		}
	}
	files.OnChanged = func(p string) {
		if !applying && p != "" {
			command(core.Command{Action: "navigate", Path: p})
		}
	}
	docs.OnChanged = files.OnChanged
	themes.OnChanged = func(t string) {
		if !applying {
			command(core.Command{Action: "settings", Theme: t, Style: "serif"})
		}
	}
	load := func() { command(core.Command{Action: "open", Path: path.Text}) }
	path.OnSubmitted = func(string) { load() }
	open := func() {
		dialog.NewFileOpen(func(r fyne.URIReadCloser, e error) {
			if e != nil {
				status.SetText(e.Error())
				return
			}
			if r != nil {
				p := r.URI().Path()
				r.Close()
				command(core.Command{Action: "open", Path: p})
			}
		}, w).Show()
	}
	save := func() {
		name := widget.NewEntry()
		name.SetPlaceHolder("Absolute destination path")
		dialog.NewForm("Save copy", "Save", "Cancel", []*widget.FormItem{widget.NewFormItem("Path", name)}, func(ok bool) {
			if ok {
				command(core.Command{Action: "saveAs", Path: name.Text})
			}
		}, w).Show()
	}
	undo := func() { command(core.Command{Action: "undo"}) }
	redo := func() { command(core.Command{Action: "redo"}) }
	top := container.NewBorder(nil, nil, widget.NewButton("Open…", open), container.NewHBox(widget.NewButton("Load path", load), widget.NewButton("Preview / Edit", mode), widget.NewButton("Undo", undo), widget.NewButton("Redo", redo), widget.NewButton("Save Copy…", save)), path)
	bar := container.NewGridWithColumns(5, files, docs, widget.NewButton("Close document", func() { command(core.Command{Action: "closeDocument"}) }), widget.NewButton("Reload…", func() {
		dialog.ShowConfirm("Reload", "Discard draft and reload?", func(ok bool) {
			if ok {
				command(core.Command{Action: "reload"})
			}
		}, w)
	}), themes)
	scope := widget.NewSelect([]string{"current", "open", "folder"}, nil)
	scope.SetSelected("current")
	results := widget.NewSelect(nil, nil)
	results.PlaceHolder = "Search results"
	var matches []core.SearchMatch
	find := func() {
		s := command(core.Command{Action: "search", Query: query.Text, Scope: scope.Selected})
		matches = s.Search.Matches
		results.Options = nil
		for i, m := range matches {
			results.Options = append(results.Options, fmt.Sprintf("%d · %s:%d %s", i+1, filepath.Base(m.Path), m.Line, m.Snippet))
		}
		results.ClearSelected()
		results.Refresh()
		status.SetText(fmt.Sprintf("%d matches", len(matches)))
	}
	results.OnChanged = func(value string) {
		i := results.SelectedIndex()
		if i < 0 || i >= len(matches) {
			return
		}
		m := matches[i]
		s := command(core.Command{Action: "navigate", Path: m.Path})
		if s.Error == "" {
			editing = false
			mode()
			status.SetText(fmt.Sprintf("Match at line %d, column %d", m.Line, m.Column))
		}
	}
	query.OnSubmitted = func(string) { find() }
	search := container.NewGridWithColumns(4, query, scope, widget.NewButton("Find", find), results)
	w.SetContent(container.NewBorder(container.NewVBox(top, bar, search), status, nil, nil, content))
	w.SetMainMenu(fyne.NewMainMenu(fyne.NewMenu("File", fyne.NewMenuItem("Open…", open), fyne.NewMenuItem("Save Copy…", save)), fyne.NewMenu("Edit", fyne.NewMenuItem("Undo", undo), fyne.NewMenuItem("Redo", redo), fyne.NewMenuItem("Find", func() { w.Canvas().Focus(query) }))))
	w.SetCloseIntercept(func() {
		s := command(core.Command{Action: "flush"})
		if s.Error == "" && !s.Dirty {
			w.SetCloseIntercept(nil)
			w.Close()
		}
	})
	command(core.Command{Action: "state"})
	if len(os.Args) > 1 {
		command(core.Command{Action: "open", Path: os.Args[1]})
	}
	go func() {
		for range time.NewTicker(750 * time.Millisecond).C {
			fyne.Do(func() {
				if len(state.OpenDocuments) > 0 {
					command(core.Command{Action: "refresh"})
				}
			})
		}
	}()
	w.ShowAndRun()
}
