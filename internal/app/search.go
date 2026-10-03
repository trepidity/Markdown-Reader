package app

import (
	"errors"
	"fmt"
	"io/fs"
	"markdownviewer/internal/document"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"unicode/utf8"
)

type SearchMatch struct {
	Before       []string `json:"before"`
	After        []string `json:"after"`
	SnippetStart int      `json:"snippetStart"`
	SnippetEnd   int      `json:"snippetEnd"`
	Text         string   `json:"text"`
	Path         string   `json:"path"`
	Line         int      `json:"line"`
	Column       int      `json:"column"`
	Start        int      `json:"start"`
	End          int      `json:"end"`
	Snippet      string   `json:"snippet"`
}
type SearchResult struct {
	Matches   []SearchMatch `json:"matches"`
	Truncated bool          `json:"truncated"`
	Warnings  []string      `json:"warnings"`
}

const maxSearchMatches = 1000
const maxSearchBytes = 64 << 20

func markdownFiles(root string) ([]string, error) {
	var paths []string
	err := filepath.WalkDir(root, func(path string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if d.IsDir() {
			if path != root && strings.HasPrefix(d.Name(), ".") {
				return filepath.SkipDir
			}
			return nil
		}
		ext := strings.ToLower(filepath.Ext(path))
		if ext == ".md" || ext == ".markdown" || ext == ".mdown" {
			paths = append(paths, path)
		}
		if len(paths) > 5000 {
			return errors.New("folder contains more than 5,000 Markdown files")
		}
		return nil
	})
	return paths, err
}

func (a *App) search(c Command) (*SearchResult, error) {
	result := &SearchResult{Matches: []SearchMatch{}, Warnings: []string{}}
	var paths []string
	switch c.Scope {
	case "current":
		if a.doc == nil {
			return result, errors.New("open a document to search")
		}
		paths = []string{a.doc.Path}
	case "open":
		paths = a.documentOrder
	case "folder":
		if a.folder == "" {
			return result, errors.New("open a folder to search")
		}
		var err error
		paths, err = markdownFiles(a.folder)
		if err != nil {
			return result, err
		}
	default:
		return result, errors.New("unknown search scope")
	}
	if c.Query == "" {
		return result, nil
	}
	if len(c.Query) > 4096 || strings.ContainsAny(c.Query, "\r\n") {
		return result, errors.New("find text must be a single line of at most 4,096 bytes")
	}
	pattern := regexp.QuoteMeta(c.Query)
	if !c.MatchCase {
		pattern = "(?i)" + pattern
	}
	re, err := regexp.Compile(pattern)
	if err != nil {
		return result, err
	}
	budget := maxSearchBytes
	seen := map[string]bool{}
	root := ""
	if c.Scope == "folder" {
		root, err = filepath.EvalSymlinks(a.folder)
		if err != nil {
			return result, err
		}
	}
	for _, path := range paths {
		canonical, err := filepath.EvalSymlinks(path)
		// Open documents are session snapshots, including retained unsaved drafts.
		if c.Scope != "folder" {
			canonical = path
			err = nil
		}
		if err != nil {
			result.Warnings = append(result.Warnings, fmt.Sprintf("%s: %v", filepath.Base(path), err))
			continue
		}
		if root != "" {
			rel, e := filepath.Rel(root, canonical)
			if e != nil || rel == ".." || strings.HasPrefix(rel, ".."+string(os.PathSeparator)) {
				result.Warnings = append(result.Warnings, filepath.Base(path)+": link points outside the folder")
				continue
			}
		}
		if seen[canonical] {
			continue
		}
		seen[canonical] = true
		d := a.documents[canonical]
		if d == nil {
			info, e := os.Stat(canonical)
			if e != nil {
				result.Warnings = append(result.Warnings, filepath.Base(path)+": "+e.Error())
				continue
			}
			if info.Size() > int64(budget) && info.Size() <= document.MaxSize {
				result.Truncated = true
				break
			}
			d, err = document.Open(canonical)
			if err != nil {
				result.Warnings = append(result.Warnings, filepath.Base(path)+": "+err.Error())
				continue
			}
		}
		if len(d.Text) > budget {
			result.Truncated = true
			break
		}
		budget -= len(d.Text)
		appendMatches(result, re, d.Path, d.Text)
		if result.Truncated {
			break
		}
	}
	return result, nil
}

// Start and End are UTF-16 offsets into the original document text.
// The UI accounts for textarea CRLF normalization when selecting a source match.
func utf16Length(s string) int {
	n := 0
	for _, r := range s {
		n++
		if r > 0xffff {
			n++
		}
	}
	return n
}
func appendMatches(result *SearchResult, re *regexp.Regexp, path, text string) {
	rest := text
	lineNumber := 1
	lineOffset := 0
	var previousLines []string
	for rest != "" {
		line, tail, more := strings.Cut(rest, "\n")
		positions := re.FindAllStringIndex(line, maxSearchMatches-len(result.Matches)+1)
		previousByte, units, columnRunes := 0, 0, 0
		for _, position := range positions {
			if len(result.Matches) == maxSearchMatches {
				result.Truncated = true
				return
			}
			columnRunes += utf8.RuneCountInString(line[previousByte:position[0]])
			column := columnRunes + 1
			units += utf16Length(line[previousByte:position[0]])
			start := lineOffset + units
			units += utf16Length(line[position[0]:position[1]])
			columnRunes += utf8.RuneCountInString(line[position[0]:position[1]])
			previousByte = position[1]
			snippet, snippetStart, snippetEnd := searchSnippet(line, position[0], position[1])
			var after []string
			if more {
				next := tail
				for n := 0; n < 2; n++ {
					context, remaining, hasNext := strings.Cut(next, "\n")
					after = append(after, shortContext(context))
					if !hasNext {
						break
					}
					next = remaining
				}
			}
			result.Matches = append(result.Matches, SearchMatch{Before: append([]string{}, previousLines...), After: after, SnippetStart: snippetStart, SnippetEnd: snippetEnd, Text: line[position[0]:position[1]], Path: path, Line: lineNumber, Column: column, Start: start, End: lineOffset + units, Snippet: snippet})
		}
		if !more {
			break
		}
		previousLines = append(previousLines, shortContext(line))
		if len(previousLines) > 2 {
			previousLines = previousLines[1:]
		}
		lineOffset += utf16Length(line) + 1
		lineNumber++
		rest = tail
	}
}
func searchSnippet(line string, start, end int) (string, int, int) {
	left := start
	for i := 0; i < 70 && left > 0; i++ {
		_, size := utf8.DecodeLastRuneInString(line[:left])
		left -= size
	}
	right := start
	for i := 0; i < 150 && right < len(line); i++ {
		_, size := utf8.DecodeRuneInString(line[right:])
		right += size
	}
	prefix, suffix := "", ""
	if left > 0 {
		prefix = "…"
	}
	if right < len(line) {
		suffix = "…"
	}
	return prefix + line[left:right] + suffix, utf16Length(prefix + line[left:start]), utf16Length(prefix + line[left:min(end, right)])
}

func shortContext(line string) string {
	end := 0
	for count := 0; count < 220 && end < len(line); count++ {
		_, size := utf8.DecodeRuneInString(line[end:])
		end += size
	}
	if end < len(line) {
		return line[:end] + "…"
	}
	return line
}
