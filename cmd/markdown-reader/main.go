package main

import (
	"bufio"
	"bytes"
	"encoding/binary"
	"fmt"
	"io"
	"os"
	"runtime/debug"
	"strconv"
	"strings"
	"unicode/utf8"

	"github.com/yuin/goldmark"
	"github.com/yuin/goldmark/ast"
	"github.com/yuin/goldmark/extension"
	east "github.com/yuin/goldmark/extension/ast"
	"github.com/yuin/goldmark/text"
	"github.com/yuin/goldmark/util"
)

// Record flags shared with the native viewer (viewer-only/main.m). Bold=1,
// italic=2 and strike=8 mark inline runs; heading level is bits 8..11.
const (
	mono          uint32 = 1 << 2  // inline code span, code block or table text
	codeBlockLine uint32 = 1 << 4  // one line of a fenced or indented code block
	thematicBreak uint32 = 1 << 5  // empty paragraph drawn as a rule
	tableText     uint32 = 1 << 6  // one aligned table row
	listMarker    uint32 = 1 << 7  // "•\t" or "N.\t" opening a list item
	codeFirst     uint32 = 1 << 12 // first line of a code block
	codeLast      uint32 = 1 << 13 // last line of a code block
	listDepth     uint32 = 1 << 16 // bits 16..23: list nesting
	quoteDepth    uint32 = 1 << 24 // bits 24..27: block quote nesting
)

// cellText appends a table cell's plain text: link labels, code span text and
// resolved entities, without markup or raw HTML.
func cellText(b *strings.Builder, n ast.Node, source []byte, code bool) {
	for child := n.FirstChild(); child != nil; child = child.NextSibling() {
		switch v := child.(type) {
		case *ast.Text:
			s := v.Segment.Value(source)
			if !code && !v.IsRaw() {
				s = util.ResolveEntityNames(util.ResolveNumericReferences(util.UnescapePunctuations(s)))
			}
			b.Write(s)
			if v.SoftLineBreak() || v.HardLineBreak() {
				b.WriteByte(' ')
			}
		case *ast.String:
			b.Write(v.Value)
		case *ast.AutoLink:
			b.Write(v.Label(source))
		case *ast.RawHTML:
		case *ast.CodeSpan:
			cellText(b, child, source, true)
		default:
			cellText(b, child, source, code)
		}
	}
}

// chunkTarget is the minimum source size parsed as one goldmark document.
var chunkTarget = 256 << 10

// MVRO1 is a stream of (flags, UTF-8 length, link length) little-endian u32
// records followed by UTF-8 text and link bytes. No source, AST, HTML, history,
// or Go heap survives after this helper exits. Every paragraph, code line and
// table row ends with its own "\n" record text. Vector flag 1<<30 instead
// carries PDF body bytes and UTF-8 SVG metadata.
func run(args []string, out io.Writer) error {
	pluginRoot := ""
	if len(args) == 3 && args[0] == "--plugins" {
		pluginRoot, args = args[1], args[2:]
	}
	if len(args) != 1 {
		return fmt.Errorf("usage: markdown-reader [--plugins DIRECTORY] FILE")
	}
	plugins, err := loadPlugins(pluginRoot)
	if err != nil {
		return err
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
	// An exactly sized buffer: no growth copies of up to 16 MiB.
	document := make([]byte, info.Size())
	if _, err = io.ReadFull(f, document); err != nil {
		return fmt.Errorf("file changed while reading: %w", err)
	}
	var probe [1]byte
	if n, _ := f.Read(probe[:]); n != 0 {
		return fmt.Errorf("file changed while reading")
	}
	if !utf8.Valid(document) || bytes.IndexByte(document, 0) >= 0 {
		return fmt.Errorf("expected UTF-8 text at most 16 MiB without NUL bytes")
	}
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
	var source []byte // the chunk being visited; segments are relative to it
	emitCode := func(lines *text.Segments, flags uint32) {
		flags |= mono | codeBlockLine
		if lines.Len() == 0 {
			emit([]byte("\n"), flags|codeFirst|codeLast, nil)
			return
		}
		for i := 0; i < lines.Len(); i++ {
			segment := lines.At(i)
			f := flags
			if i == 0 {
				f |= codeFirst
			}
			if i == lines.Len()-1 {
				f |= codeLast // goldmark ends even an unterminated final line with "\n"
			}
			emit(segment.Value(source), f, nil)
		}
	}
	emitTable := func(table *east.Table, flags uint32) {
		flags |= mono | tableText
		var rows [][]string
		var widths []int
		for row := table.FirstChild(); row != nil; row = row.NextSibling() {
			var cells []string
			for cell := row.FirstChild(); cell != nil; cell = cell.NextSibling() {
				var b strings.Builder
				cellText(&b, cell, source, false)
				s := strings.TrimSpace(b.String())
				if len(widths) <= len(cells) {
					widths = append(widths, 0)
				}
				widths[len(cells)] = max(widths[len(cells)], utf8.RuneCountInString(s))
				cells = append(cells, s)
			}
			rows = append(rows, cells)
		}
		var line strings.Builder
		for r, cells := range rows {
			line.Reset()
			for c, width := range widths {
				if c > 0 {
					line.WriteString("  │  ")
				}
				cell := ""
				if c < len(cells) {
					cell = cells[c]
				}
				pad := width - utf8.RuneCountInString(cell)
				left := 0
				if c < len(table.Alignments) {
					switch table.Alignments[c] {
					case east.AlignRight:
						left = pad
					case east.AlignCenter:
						left = pad / 2
					}
				}
				line.WriteString(strings.Repeat(" ", left))
				line.WriteString(cell)
				line.WriteString(strings.Repeat(" ", pad-left))
			}
			header := r == 0 && table.FirstChild().Kind() == east.KindTableHeader
			rowFlags := flags
			if header {
				rowFlags |= 1
			}
			emit([]byte(strings.TrimRight(line.String(), " ")+"\n"), rowFlags, nil)
			if header {
				line.Reset()
				for c, width := range widths {
					if c > 0 {
						line.WriteString("──┼──")
					}
					line.WriteString(strings.Repeat("─", width))
				}
				line.WriteString("\n")
				emit([]byte(line.String()), flags, nil)
			}
		}
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
			flags += quoteDepth
		case *ast.List:
			number := v.Start
			flags += listDepth
			for child := n.FirstChild(); child != nil; child = child.NextSibling() {
				prefix := "•\t"
				if v.IsOrdered() {
					prefix = strconv.Itoa(number) + ".\t"
					number++
				}
				emit([]byte(prefix), flags|listMarker, nil)
				visit(child, flags, link)
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
		case *ast.FencedCodeBlock:
			language := strings.ToLower(string(v.Language(source)))
			if _, installed := plugins.languages[language]; installed {
				var code bytes.Buffer
				for i := 0; i < n.Lines().Len(); i++ {
					line := n.Lines().At(i)
					code.Write(line.Value(source))
				}
				result, id, renderError := plugins.render(language, code.Bytes())
				if renderError == nil && result != nil {
					emit(result.PDF, vectorRecord, []byte(result.SVG))
					emit([]byte("\n"), flags, nil)
					return
				}
				if renderError != nil {
					emit([]byte(fmt.Sprintf("[Plugin %s: %s; source follows]\n", id, renderError)), flags, nil)
				}
			}
			emitCode(n.Lines(), flags)
			return
		case *ast.CodeBlock:
			emitCode(n.Lines(), flags)
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
			emit([]byte("\n"), flags|thematicBreak, nil)
			return
		case *east.Table:
			emitTable(v, flags)
			return
		}
		for child := n.FirstChild(); child != nil; child = child.NextSibling() {
			visit(child, flags, link)
		}
		if paragraph {
			emit([]byte("\n"), flags, nil)
		}
	}
	parser := goldmark.New(goldmark.WithExtensions(extension.GFM)).Parser()
	start := 0
	for _, end := range chunkBoundaries(document, chunkTarget) {
		source = document[start:end]
		root := parser.Parse(text.NewReader(source))
		if end < len(document) && chunkEndsOpen(root, source) {
			// The scanner was wrong about this boundary; parse the rest whole.
			end = len(document)
			source = document[start:]
			root = parser.Parse(text.NewReader(source))
		}
		visit(root, 0, nil)
		if start = end; start == len(document) {
			break
		}
	}
	return w.Flush()
}

func main() {
	// A tight heap: the helper is short-lived and memory, not CPU, is the budget.
	debug.SetGCPercent(20)
	if err := run(os.Args[1:], os.Stdout); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
