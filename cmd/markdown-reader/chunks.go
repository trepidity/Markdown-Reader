package main

import (
	"bytes"

	"github.com/yuin/goldmark/ast"
)

// Chunked parsing bounds the goldmark AST to about chunkTarget bytes of source
// at a time. A chunk may end only where a whole-document parse would be at the
// document root with nothing open, so each chunk parses exactly as it would in
// place: immediately before a column-0 ATX heading that follows a blank line.
// A blank line closes paragraphs, tables and HTML blocks of types 6 and 7; a
// column-0 line closes lists, block quotes and indented code. Only top-level
// fenced code and HTML blocks of types 1-5 survive both, so those are tracked
// here and checked again on the parsed chunk (chunkEndsOpen). Reference
// definitions are document-global, so any line that may start one disables
// chunking.

// chunkBoundaries returns increasing end offsets covering document. Every chunk
// except the last is at least target bytes.
func chunkBoundaries(document []byte, target int) []int {
	var ends []int
	start, previousBlank := 0, false
	var fenceChar byte
	fenceLength := 0
	var htmlEnd []byte // non-nil while inside an HTML block of types 1-5
	htmlFold := false  // type 1 end tags match case-insensitively
	for at := 0; at < len(document); {
		next := bytes.IndexByte(document[at:], '\n')
		if next < 0 {
			next = len(document)
		} else {
			next += at + 1
		}
		line := bytes.TrimRight(document[at:next], "\r\n")
		if mayStartReferenceDefinition(document, at, line) {
			return []int{len(document)}
		}
		indent, rest := leadingIndent(line)
		switch {
		case fenceLength > 0:
			if indent <= 3 && closesFence(rest, fenceChar, fenceLength) {
				fenceLength = 0
			}
		case htmlEnd != nil:
			if containsEnd(line, htmlEnd, htmlFold) {
				htmlEnd = nil
			}
		default:
			if previousBlank && at-start >= target && isATXHeading(line) {
				ends = append(ends, at)
				start = at
			}
			if indent <= 3 {
				if c, n, ok := opensFence(rest); ok {
					fenceChar, fenceLength = c, n
				} else if end, fold, after, ok := opensHTMLBlock(rest); ok && !containsEnd(after, end, fold) {
					htmlEnd, htmlFold = end, fold
				}
			}
		}
		previousBlank = len(bytes.Trim(line, " \t")) == 0
		at = next
	}
	if start < len(document) {
		ends = append(ends, len(document))
	}
	return ends
}

// chunkEndsOpen reports whether a non-final chunk ends inside a top-level
// fenced code or HTML block, i.e. the scanner's boundary was unsafe. Such a
// block would otherwise run on through the blank line that ends the chunk.
func chunkEndsOpen(root ast.Node, chunk []byte) bool {
	switch last := root.LastChild(); last.(type) {
	case *ast.FencedCodeBlock, *ast.HTMLBlock:
		lines := last.Lines()
		return lines.Len() > 0 && lines.At(lines.Len()-1).Stop >= len(chunk)
	}
	return false
}

// leadingIndent returns the indentation width (tabs to multiples of 4) and the
// rest of the line. Widths of 4 or more are reported as 4.
func leadingIndent(line []byte) (int, []byte) {
	width := 0
	for i, c := range line {
		switch c {
		case ' ':
			width++
		case '\t':
			width += 4 - width%4
		default:
			return min(width, 4), line[i:]
		}
		if width >= 4 {
			return 4, line[i+1:]
		}
	}
	return min(width, 4), nil
}

func isATXHeading(line []byte) bool {
	n := 0
	for n < len(line) && line[n] == '#' {
		n++
	}
	return n >= 1 && n <= 6 && (n == len(line) || line[n] == ' ' || line[n] == '\t')
}

func opensFence(rest []byte) (byte, int, bool) {
	if len(rest) < 3 || (rest[0] != '`' && rest[0] != '~') {
		return 0, 0, false
	}
	c, n := rest[0], 0
	for n < len(rest) && rest[n] == c {
		n++
	}
	if n < 3 || (c == '`' && bytes.IndexByte(rest[n:], '`') >= 0) {
		return 0, 0, false
	}
	return c, n, true
}

func closesFence(rest []byte, c byte, length int) bool {
	n := 0
	for n < len(rest) && rest[n] == c {
		n++
	}
	return n >= length && len(bytes.Trim(rest[n:], " \t")) == 0
}

// opensHTMLBlock recognises CommonMark HTML block start conditions 1-5 and
// returns the end condition and the text after the start condition.
func opensHTMLBlock(rest []byte) (end []byte, fold bool, after []byte, ok bool) {
	if len(rest) < 2 || rest[0] != '<' {
		return nil, false, nil, false
	}
	for _, tag := range []string{"pre", "script", "style", "textarea"} {
		n := 1 + len(tag)
		if len(rest) >= n && bytes.EqualFold(rest[1:n], []byte(tag)) &&
			(len(rest) == n || rest[n] == ' ' || rest[n] == '\t' || rest[n] == '>') {
			return []byte("</" + tag + ">"), true, rest[n:], true
		}
	}
	switch {
	case bytes.HasPrefix(rest, []byte("<!--")):
		return []byte("-->"), false, rest[4:], true
	case bytes.HasPrefix(rest, []byte("<?")):
		return []byte("?>"), false, rest[2:], true
	case bytes.HasPrefix(rest, []byte("<![CDATA[")):
		return []byte("]]>"), false, rest[9:], true
	case len(rest) > 2 && rest[1] == '!' && (rest[2]|0x20 >= 'a' && rest[2]|0x20 <= 'z'):
		return []byte(">"), false, rest[2:], true
	}
	return nil, false, nil, false
}

func containsEnd(line, end []byte, fold bool) bool {
	if !fold {
		return bytes.Contains(line, end)
	}
	for i := 0; i+len(end) <= len(line); i++ {
		if bytes.EqualFold(line[i:i+len(end)], end) {
			return true
		}
	}
	return false
}

// mayStartReferenceDefinition is deliberately over-inclusive: after any
// block-quote or list-item prefix, a '[' with "]:" within the maximum label
// length (labels may span lines).
func mayStartReferenceDefinition(document []byte, at int, line []byte) bool {
	i := 0
prefix:
	for i < len(line) {
		switch c := line[i]; {
		case c == ' ' || c == '\t' || c == '>':
			i++
			continue
		case (c == '-' || c == '*' || c == '+') && i+1 < len(line) && (line[i+1] == ' ' || line[i+1] == '\t'):
			i += 2
			continue
		case c >= '0' && c <= '9':
			j := i
			for j < len(line) && line[j] >= '0' && line[j] <= '9' {
				j++
			}
			if j+1 < len(line) && (line[j] == '.' || line[j] == ')') && (line[j+1] == ' ' || line[j+1] == '\t') {
				i = j + 2
				continue
			}
		}
		break prefix
	}
	if i >= len(line) || line[i] != '[' {
		return false
	}
	window := document[at+i:]
	if len(window) > 1024 {
		window = window[:1024]
	}
	return bytes.Contains(window, []byte("]:"))
}
