package main

import (
	"bytes"
	"regexp"
	"strings"
)

// maxFrontMatter bounds how far the reader looks for the closing delimiter. A leading "---" with
// no closing line inside this window is an ordinary thematic break.
const maxFrontMatter = 64 << 10

var (
	yamlKey = regexp.MustCompile(`^([A-Za-z_][^:#]*?):(?:\s+(.*))?$`)
	tomlKey = regexp.MustCompile(`^(?:[A-Za-z_][\w.-]*\s*=|\[[^\]]+\]\s*$)`)
	blockIn = regexp.MustCompile(`^[>|][+-]?\d*$`)
)

type frontPair struct{ key, value string }

// splitFrontMatter separates a leading front matter block from the document. block holds the
// lines between the delimiters; kind is "yaml" or "toml". ok is false for any document that does
// not start with a delimiter line, a closing line, and a plausible first key.
func splitFrontMatter(doc []byte) (block []string, kind string, rest []byte, ok bool) {
	body := bytes.TrimPrefix(doc, []byte("\xef\xbb\xbf"))
	line := func(b []byte) ([]byte, []byte) {
		i := bytes.IndexByte(b, '\n')
		if i < 0 {
			return b, nil
		}
		return b[:i], b[i+1:]
	}
	clean := func(b []byte) string { return strings.TrimRight(string(b), " \t\r") }
	first, remaining := line(body)
	opening := clean(first)
	closing := map[string]string{"---": "---", "+++": "+++"}[opening]
	if closing == "" {
		return nil, "", nil, false
	}
	kind = map[string]string{"---": "yaml", "+++": "toml"}[opening]
	consumed := len(first) + 1
	for len(remaining) > 0 && consumed < maxFrontMatter {
		text, next := line(remaining)
		consumed += len(text) + 1
		trimmed := clean(text)
		if trimmed == closing || (kind == "yaml" && trimmed == "...") {
			// The first content line must look like a key, or this is two rules around prose.
			for _, l := range block {
				l = strings.TrimSpace(l)
				if l == "" || strings.HasPrefix(l, "#") {
					continue
				}
				if (kind == "yaml" && !yamlKey.MatchString(l)) || (kind == "toml" && !tomlKey.MatchString(l)) {
					return nil, "", nil, false
				}
				return block, kind, next, true
			}
			return nil, "", nil, false
		}
		block = append(block, clean(text))
		remaining = next
	}
	return nil, "", nil, false
}

func indentOf(s string) int { return len(s) - len(strings.TrimLeft(s, " ")) }

func unquote(s string) string {
	s = strings.TrimSpace(s)
	if len(s) >= 2 && (s[0] == '"' && s[len(s)-1] == '"' || s[0] == '\'' && s[len(s)-1] == '\'') {
		return s[1 : len(s)-1]
	}
	return s
}

// dedent removes the common leading indentation of the non-blank lines.
func dedent(lines []string) []string {
	least := -1
	for _, l := range lines {
		if strings.TrimSpace(l) != "" && (least < 0 || indentOf(l) < least) {
			least = indentOf(l)
		}
	}
	out := make([]string, len(lines))
	for i, l := range lines {
		if len(l) >= least && least > 0 {
			l = l[least:]
		}
		out[i] = l
	}
	return out
}

// parseMapping reads "key: value" entries from lines that all share one indentation. It
// understands scalars, block scalars (> and |), lists and nested mappings, and reports ok=false
// for anything else so the caller can show the block verbatim instead.
func parseMapping(lines []string, depth int) (pairs []frontPair, ok bool) {
	if depth > 3 {
		return nil, false
	}
	i := 0
	for i < len(lines) {
		l := lines[i]
		if strings.TrimSpace(l) == "" || strings.HasPrefix(strings.TrimSpace(l), "#") {
			i++
			continue
		}
		m := yamlKey.FindStringSubmatch(l)
		if indentOf(l) != 0 || strings.HasPrefix(l, "- ") || m == nil {
			return nil, false
		}
		key, inline := strings.TrimSpace(m[1]), strings.TrimSpace(m[2])
		i++
		var body []string
		for i < len(lines) {
			n := lines[i]
			if strings.TrimSpace(n) != "" && indentOf(n) == 0 && !strings.HasPrefix(n, "- ") && yamlKey.MatchString(n) {
				break
			}
			body = append(body, n)
			i++
		}
		value, ok := frontValue(inline, body, depth)
		if !ok {
			return nil, false
		}
		pairs = append(pairs, frontPair{key, value})
	}
	return pairs, len(pairs) > 0
}

func frontValue(inline string, body []string, depth int) (string, bool) {
	nonBlank := func(ls []string) []string {
		var out []string
		for _, l := range ls {
			if strings.TrimSpace(l) != "" && !strings.HasPrefix(strings.TrimSpace(l), "#") {
				out = append(out, l)
			}
		}
		return out
	}
	switch {
	case blockIn.MatchString(inline):
		lines := dedent(body)
		for len(lines) > 0 && strings.TrimSpace(lines[len(lines)-1]) == "" {
			lines = lines[:len(lines)-1]
		}
		if inline[0] == '|' {
			return strings.Join(lines, "\n"), true
		}
		var folded strings.Builder // folded: single newlines become spaces, blank lines stay
		for _, l := range lines {
			switch {
			case strings.TrimSpace(l) == "":
				folded.WriteString("\n")
			case folded.Len() > 0 && !strings.HasSuffix(folded.String(), "\n"):
				folded.WriteString(" " + strings.TrimSpace(l))
			default:
				folded.WriteString(strings.TrimSpace(l))
			}
		}
		return folded.String(), true
	case inline != "":
		parts := []string{unquote(inline)}
		for _, l := range nonBlank(body) { // a plain scalar may continue on indented lines
			parts = append(parts, strings.TrimSpace(l))
		}
		return strings.Join(parts, " "), true
	}
	content := dedent(nonBlank(body))
	if len(content) == 0 {
		return "", true
	}
	if strings.HasPrefix(content[0], "- ") {
		var items [][]string
		for _, l := range content {
			if strings.HasPrefix(l, "- ") {
				items = append(items, []string{l[2:]})
			} else if len(items) > 0 && indentOf(l) > 0 {
				items[len(items)-1] = append(items[len(items)-1], l)
			} else {
				return "", false
			}
		}
		var out []string
		for _, item := range items {
			if yamlKey.MatchString(item[0]) && !strings.HasPrefix(item[0], "\"") {
				entry, ok := parseMapping(dedent(append([]string{item[0]}, shiftLeft(item[1:], 2)...)), depth+1)
				if !ok {
					return "", false
				}
				var fields []string
				for _, p := range entry {
					fields = append(fields, p.key+": "+strings.ReplaceAll(p.value, "\n", " "))
				}
				out = append(out, strings.Join(fields, " · "))
			} else {
				out = append(out, unquote(strings.Join(item, " ")))
			}
		}
		return strings.Join(out, "\n"), true
	}
	entries, ok := parseMapping(content, depth+1)
	if !ok {
		return "", false
	}
	var out []string
	for _, p := range entries {
		out = append(out, p.key+": "+strings.ReplaceAll(p.value, "\n", " "))
	}
	return strings.Join(out, "\n"), true
}

// shiftLeft removes up to n leading spaces: the continuation lines of a "- key: value" item sit
// two columns right of the dash.
func shiftLeft(lines []string, n int) []string {
	out := make([]string, len(lines))
	for i, l := range lines {
		cut := min(n, indentOf(l))
		out[i] = l[cut:]
	}
	return out
}
