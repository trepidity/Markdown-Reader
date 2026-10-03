package document

import (
	"bytes"
	"encoding/base64"
	"io"
	"net/url"
	"os"
	"path/filepath"
	"strings"

	"github.com/yuin/goldmark"
	"github.com/yuin/goldmark/extension"
	"github.com/yuin/goldmark/parser"
	"golang.org/x/net/html"
)

var markdown = goldmark.New(goldmark.WithExtensions(extension.GFM), goldmark.WithParserOptions(parser.WithAutoHeadingID()))
var tags = map[string]bool{}

func init() {
	for _, t := range strings.Fields("h1 h2 h3 h4 h5 h6 p a img strong em del blockquote ul ol li pre code hr br table thead tbody tr th td input") {
		tags[t] = true
	}
}
func Render(text, path string) string {
	var raw bytes.Buffer
	if markdown.Convert([]byte(text), &raw) != nil {
		return "<p>Unable to render Markdown.</p>"
	}
	z := html.NewTokenizer(&raw)
	var out strings.Builder
	for {
		tt := z.Next()
		if tt == html.ErrorToken {
			if z.Err() == io.EOF {
				break
			}
			break
		}
		t := z.Token()
		switch tt {
		case html.TextToken:
			out.WriteString(html.EscapeString(t.Data))
		case html.StartTagToken, html.SelfClosingTagToken:
			if !tags[t.Data] {
				continue
			}
			attrs := []html.Attribute{}
			for _, a := range t.Attr {
				switch a.Key {
				case "href":
					u, e := url.Parse(strings.TrimSpace(a.Val))
					if e == nil && (u.Scheme == "https" || u.Scheme == "http" || u.Scheme == "mailto" || u.Scheme == "") {
						attrs = append(attrs, a)
					}
				case "src":
					if src := localImage(path, a.Val); src != "" {
						attrs = append(attrs, html.Attribute{Key: "src", Val: src})
					}
				case "id":
					attrs = append(attrs, html.Attribute{Key: "id", Val: "md-" + a.Val})
				case "alt", "title", "align":
					attrs = append(attrs, a)
				case "type":
					if t.Data == "input" && a.Val == "checkbox" {
						attrs = append(attrs, a)
					}
				case "checked", "disabled":
					if t.Data == "input" {
						attrs = append(attrs, a)
					}
				}
			}
			if t.Data == "input" {
				attrs = append(attrs, html.Attribute{Key: "disabled"})
			}
			t.Attr = attrs
			out.WriteString(t.String())
		case html.EndTagToken:
			if tags[t.Data] {
				out.WriteString(t.String())
			}
		}
	}
	return out.String()
}
func localImage(path, src string) string {
	u, e := url.Parse(src)
	if e != nil || u.Scheme != "" || u.Host != "" || path == "" {
		return ""
	}
	root := filepath.Dir(path)
	p, e := filepath.EvalSymlinks(filepath.Join(root, filepath.FromSlash(u.Path)))
	if e != nil {
		return ""
	}
	rel, e := filepath.Rel(root, p)
	if e != nil || rel == ".." || strings.HasPrefix(rel, ".."+string(os.PathSeparator)) {
		return ""
	}
	mime := map[string]string{".png": "image/png", ".jpg": "image/jpeg", ".jpeg": "image/jpeg", ".gif": "image/gif", ".webp": "image/webp"}[strings.ToLower(filepath.Ext(p))]
	if mime == "" {
		return ""
	}
	info, e := os.Stat(p)
	if e != nil || !info.Mode().IsRegular() || info.Size() > 8<<20 {
		return ""
	}
	b, e := os.ReadFile(p)
	if e != nil {
		return ""
	}
	return "data:" + mime + ";base64," + base64.StdEncoding.EncodeToString(b)
}
