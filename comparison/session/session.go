package session

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"

	"golang.org/x/net/html"
	"markdownreader/internal/app"
)

type Run struct {
	Text   string `json:"text"`
	Bold   bool   `json:"bold,omitempty"`
	Italic bool   `json:"italic,omitempty"`
	Mono   bool   `json:"mono,omitempty"`
	Strike bool   `json:"strike,omitempty"`
	Href   string `json:"href,omitempty"`
	Image  string `json:"image,omitempty"`
}
type Block struct {
	Kind  string    `json:"kind"`
	Level int       `json:"level,omitempty"`
	ID    string    `json:"id,omitempty"`
	Runs  []Run     `json:"runs,omitempty"`
	Rows  [][][]Run `json:"rows,omitempty"`
}

func (b Block) Text() string {
	var s strings.Builder
	for _, r := range b.Runs {
		s.WriteString(r.Text)
	}
	return s.String()
}

type State struct {
	app.State
	Blocks []Block `json:"blocks,omitempty"`
}
type Session struct {
	mu       sync.Mutex
	core     *app.App
	lastHTML string
	blocks   []Block
}

func New(config string) *Session { return &Session{core: app.New(config)} }
func Config(variant string) string {
	root := os.Getenv("MARKDOWN_READER_CONFIG")
	if root == "" {
		root, _ = os.UserConfigDir()
		root = filepath.Join(root, "Markdown Reader Comparisons", variant)
	}
	return filepath.Join(root, "settings.json")
}
func (s *Session) Dispatch(c app.Command) State {
	s.mu.Lock()
	defer s.mu.Unlock()
	state := s.core.Dispatch(c)
	if state.Unchanged || c.Action == "search" {
		return State{State: state}
	}
	if state.HTML != s.lastHTML {
		s.lastHTML = state.HTML
		s.blocks = Presentation(state.HTML)
	}
	return State{State: state, Blocks: s.blocks}
}
func (s *Session) JSON(raw []byte) []byte {
	var c app.Command
	if err := json.Unmarshal(raw, &c); err != nil {
		return []byte(`{"error":"Invalid command"}`)
	}
	result, err := json.Marshal(s.Dispatch(c))
	if err != nil {
		return []byte(`{"error":"Cannot encode response"}`)
	}
	return result
}
func attr(n *html.Node, name string) string {
	for _, a := range n.Attr {
		if a.Key == name {
			return a.Val
		}
	}
	return ""
}
func hasAttr(n *html.Node, name string) bool {
	for _, a := range n.Attr {
		if a.Key == name {
			return true
		}
	}
	return false
}
func inline(n *html.Node, style Run) []Run {
	if n.Type == html.TextNode {
		style.Text = n.Data
		return []Run{style}
	}
	switch n.Data {
	case "strong":
		style.Bold = true
	case "em":
		style.Italic = true
	case "code":
		style.Mono = true
	case "del":
		style.Strike = true
	case "a":
		style.Href = attr(n, "href")
	case "br":
		style.Text = "\n"
		return []Run{style}
	case "input":
		if hasAttr(n, "checked") {
			style.Text = "☑ "
		} else {
			style.Text = "☐ "
		}
		return []Run{style}
	case "img":
		style.Text = attr(n, "alt")
		style.Image = attr(n, "src")
		return []Run{style}
	}
	var out []Run
	for c := n.FirstChild; c != nil; c = c.NextSibling {
		out = append(out, inline(c, style)...)
	}
	return out
}

// Presentation consumes only the core's sanitized HTML, never original raw HTML.
// Native shells receive formatting data, not executable markup or network images.
func Presentation(safeHTML string) []Block {
	root, err := html.Parse(strings.NewReader(safeHTML))
	if err != nil {
		return nil
	}
	var out []Block
	var walk func(*html.Node, int)
	walk = func(n *html.Node, depth int) {
		if n.Type == html.ElementNode {
			b := Block{ID: attr(n, "id"), Level: depth}
			switch n.Data {
			case "h1", "h2", "h3", "h4", "h5", "h6":
				b.Kind = "heading"
				b.Level, _ = strconv.Atoi(n.Data[1:])
				b.Runs = inline(n, Run{})
			case "p":
				b.Kind = "paragraph"
				b.Runs = inline(n, Run{})
			case "pre":
				b.Kind = "code"
				b.Runs = inline(n, Run{Mono: true})
			case "blockquote":
				b.Kind = "quote"
				b.Runs = inline(n, Run{Italic: true})
			case "li":
				b.Kind = "list"
				prefix := "• "
				if n.Parent != nil && n.Parent.Data == "ol" {
					index := 1
					for p := n.PrevSibling; p != nil; p = p.PrevSibling {
						if p.Data == "li" {
							index++
						}
					}
					prefix = strconv.Itoa(index) + ". "
				}
				b.Runs = []Run{{Text: strings.Repeat("  ", depth) + prefix}}
				for c := n.FirstChild; c != nil; c = c.NextSibling {
					if c.Data != "ul" && c.Data != "ol" {
						b.Runs = append(b.Runs, inline(c, Run{})...)
					}
				}
			case "hr":
				b.Kind = "rule"
			case "table":
				b.Kind = "table"
				var rows func(*html.Node)
				rows = func(r *html.Node) {
					if r.Data == "tr" {
						var row [][]Run
						for c := r.FirstChild; c != nil; c = c.NextSibling {
							if c.Data == "td" || c.Data == "th" {
								row = append(row, inline(c, Run{Bold: c.Data == "th"}))
							}
						}
						b.Rows = append(b.Rows, row)
						return
					}
					for c := r.FirstChild; c != nil; c = c.NextSibling {
						rows(c)
					}
				}
				rows(n)
			}
			if b.Kind != "" {
				out = append(out, b)
				if n.Data == "li" {
					for c := n.FirstChild; c != nil; c = c.NextSibling {
						if c.Data == "ul" || c.Data == "ol" {
							walk(c, depth+1)
						}
					}
				}
				return
			}
		}
		for c := n.FirstChild; c != nil; c = c.NextSibling {
			walk(c, depth)
		}
	}
	walk(root, 0)
	return out
}
