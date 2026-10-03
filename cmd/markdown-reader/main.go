package main

import (
	"bufio"
	"bytes"
	"encoding/binary"
	"fmt"
	"io"
	"os"
	"unicode/utf8"

	"github.com/yuin/goldmark"
	"github.com/yuin/goldmark/ast"
	"github.com/yuin/goldmark/extension"
	east "github.com/yuin/goldmark/extension/ast"
	"github.com/yuin/goldmark/text"
	"github.com/yuin/goldmark/util"
)

// MVRO1 is a stream of (flags, UTF-8 length, link length) little-endian u32
// records followed by UTF-8 text and link bytes. No source, AST, HTML, history,
// or Go heap survives after this helper exits. Flags: bold=1 italic=2 mono=4
// strike=8, heading level in bits 8..11, indentation in bits 16..23.
func run(args []string, out io.Writer) error {
	if len(args) != 1 {
		return fmt.Errorf("usage: markdown-reader FILE")
	}
	f, err := os.Open(args[0])
	if err != nil {
		return err
	}
	defer f.Close()
	info, err := f.Stat()
	if err != nil {
		return err
	}
	const limit = 16 << 20
	if !info.Mode().IsRegular() || info.Size() > limit {
		return fmt.Errorf("expected a regular UTF-8 file at most 16 MiB")
	}
	source, err := io.ReadAll(io.LimitReader(f, limit+1))
	if err != nil {
		return err
	}
	if len(source) > limit || !utf8.Valid(source) || bytes.IndexByte(source, 0) >= 0 {
		return fmt.Errorf("expected UTF-8 text at most 16 MiB without NUL bytes")
	}
	root := goldmark.New(goldmark.WithExtensions(extension.GFM)).Parser().Parse(text.NewReader(source))
	w := bufio.NewWriter(out)
	if _, err = w.WriteString("MVRO1\n"); err != nil {
		return err
	}
	emit := func(s []byte, flags uint32, link []byte) {
		if len(s) == 0 {
			return
		}
		var header [12]byte
		binary.LittleEndian.PutUint32(header[:], flags)
		binary.LittleEndian.PutUint32(header[4:], uint32(len(s)))
		binary.LittleEndian.PutUint32(header[8:], uint32(len(link)))
		w.Write(header[:])
		w.Write(s)
		w.Write(link) // bufio retains first write error.
	}
	var visit func(ast.Node, uint32, []byte)
	visit = func(n ast.Node, flags uint32, link []byte) {
		paragraph := false
		switch v := n.(type) {
		case *ast.HTMLBlock, *ast.RawHTML:
			return
		case *ast.Heading:
			flags |= uint32(v.Level) << 8
			paragraph = true
		case *ast.Paragraph, *ast.TextBlock:
			paragraph = true
		case *ast.Blockquote:
			flags += 1 << 16
		case *ast.List:
			number := v.Start
			for child := n.FirstChild(); child != nil; child = child.NextSibling() {
				prefix := "• "
				if v.IsOrdered() {
					prefix = fmt.Sprintf("%d. ", number)
					number++
				}
				emit([]byte(prefix), flags+(1<<16), nil)
				visit(child, flags+(1<<16), link)
			}
			return
		case *ast.Emphasis:
			if v.Level == 2 {
				flags |= 1
			} else {
				flags |= 2
			}
		case *east.Strikethrough:
			flags |= 8
		case *ast.CodeSpan:
			flags |= 4
		case *ast.FencedCodeBlock, *ast.CodeBlock:
			lines := n.Lines()
			for i := 0; i < lines.Len(); i++ {
				line := lines.At(i)
				emit(line.Value(source), flags|4, nil)
			}
			emit([]byte("\n"), flags|4, nil)
			return
		case *ast.Text:
			s := v.Segment.Value(source)
			if flags&4 == 0 && !v.IsRaw() {
				s = util.ResolveEntityNames(util.ResolveNumericReferences(util.UnescapePunctuations(s)))
			}
			emit(s, flags, link)
			if v.HardLineBreak() {
				emit([]byte("\n"), flags, link)
			} else if v.SoftLineBreak() {
				emit([]byte(" "), flags, link)
			}
			return
		case *ast.String:
			emit(v.Value, flags, link)
			return
		case *ast.Link:
			link = v.Destination
		case *ast.AutoLink:
			emit(v.Label(source), flags, v.URL(source))
			return
		case *ast.Image:
			emit([]byte("[Image: "), flags, nil)
			for child := n.FirstChild(); child != nil; child = child.NextSibling() {
				visit(child, flags, nil)
			}
			emit([]byte("]"), flags, nil)
			return
		case *east.TaskCheckBox:
			s := "☐ "
			if v.IsChecked {
				s = "☑ "
			}
			emit([]byte(s), flags, nil)
			return
		case *ast.ThematicBreak:
			emit([]byte("────────────────────\n"), flags, nil)
			return
		case *east.TableHeader:
			flags |= 1
		case *east.TableCell:
			flags |= 4
		}
		for child := n.FirstChild(); child != nil; child = child.NextSibling() {
			visit(child, flags, link)
		}
		switch n.(type) {
		case *east.TableCell:
			if n.NextSibling() != nil {
				emit([]byte("  |  "), flags|4, nil)
			}
		case *east.TableRow, *east.TableHeader:
			emit([]byte("\n"), flags|4, nil)
		case *east.Table:
			emit([]byte("\n"), flags, nil)
		}
		if paragraph {
			emit([]byte("\n"), flags, nil)
		}
	}
	visit(root, 0, nil)
	return w.Flush()
}

func main() {
	if err := run(os.Args[1:], os.Stdout); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
