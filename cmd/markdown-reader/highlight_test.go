package main

import (
	"strings"
	"testing"
)

type piece struct {
	text  string
	class tokenClass
}

// codeRuns renders a fenced block and returns its runs, line by line, with the flags checked: every
// run of a line shares the block's first/last marks and is monospaced code.
func codeRuns(t *testing.T, fence, code string) [][]piece {
	t.Helper()
	var lines [][]piece
	var current []piece
	for _, r := range renderRecords(t, "```"+fence+"\n"+code+"```\n") {
		if r.flags&codeBlockLine == 0 {
			continue
		}
		if r.flags&mono == 0 {
			t.Fatalf("code run %q is not monospaced", r.body)
		}
		current = append(current, piece{string(r.body), tokenClass(r.flags >> tokenShift & 15)})
		if bytesEndWithNewline(r.body) {
			lines = append(lines, current)
			current = nil
		}
	}
	if len(current) > 0 {
		t.Fatalf("a code line did not end with a newline: %v", current)
	}
	return lines
}

func bytesEndWithNewline(b []byte) bool { return len(b) > 0 && b[len(b)-1] == '\n' }

func classOf(lines [][]piece, text string) tokenClass {
	for _, l := range lines {
		for _, r := range l {
			if strings.TrimSpace(r.text) == text {
				return r.class
			}
		}
	}
	return 255
}

// Highlighting must never lose, add or reorder a character, whatever the language and however
// malformed the code. Fails if any run is dropped, duplicated, or split from its line.
func TestHighlightedRunsReassembleToTheExactSource(t *testing.T) {
	snippets := map[string]string{
		"go":         "package main\n\n/* open\n   still open */\nfunc main() {\n\ts := `raw\nstring`\n\tr := 'x' // é ✓\n\tprintln(\"unterminated)\n}\n",
		"typescript": "const a: number = 0x1F; // c\n`tpl ${x}`;\n/* never closed\n",
		"json":       "{\"a\": [1, 2.5e3, true, null], \"b\": \"\\\"q\\\"\"}\n",
		"bash":       "# note\nexport A=\"$HOME/x\" && echo ${A} 'it''s'\nif [ -f x ]; then ls -la; fi\n",
		"sql":        "SELECT a, count(*) FROM t -- c\nWHERE b = 'x''y' AND c > 10;\n/* tail */\n",
		"python":     "@dec\ndef f(x):\n    \"\"\"doc\n    more\"\"\"\n    return x  # c\n",
		"yaml":       "key: value # c\nlist:\n  - a: 1\n  - \"q\"\n",
		"diff":       "@@ -1 +1 @@\n-old\n+new\n context\n",
		"text":       "nothing special <here> & there\n",
	}
	for language, code := range snippets {
		var got strings.Builder
		for _, line := range codeRuns(t, language, code) {
			for _, r := range line {
				got.WriteString(r.text)
			}
		}
		if got.String() != code {
			t.Errorf("%s: runs reassemble to %q, want %q", language, got.String(), code)
		}
	}
}

// Fails if a keyword, call, string or comment is classified wrongly, or if a comment that opens on
// one line does not carry onto the next.
func TestGoTokens(t *testing.T) {
	lines := codeRuns(t, "go", "func main() {\n\ts := \"hi\" // note\n\t/* a\n\t b */ x := nil\n}\n")
	for text, want := range map[string]tokenClass{
		"func": tKeyword, "main": tFunction, "\"hi\"": tString, "// note": tComment,
		"/* a": tComment, "b */": tComment, "nil": tConstant,
	} {
		if got := classOf(lines, text); got != want {
			t.Errorf("%q is class %d, want %d", text, got, want)
		}
	}
}

// JSON object keys and values are told apart; so are literals and numbers.
func TestJSONKeysValuesAndLiterals(t *testing.T) {
	lines := codeRuns(t, "json", "{\"name\": \"x\", \"n\": 12, \"ok\": true, \"none\": null}\n")
	for text, want := range map[string]tokenClass{"\"name\"": tKey, "\"x\"": tString, "12": tNumber, "true": tConstant, "null": tConstant} {
		if got := classOf(lines, text); got != want {
			t.Errorf("%q is class %d, want %d", text, got, want)
		}
	}
}

// Shell variables, comments and quoted text; SQL keywords regardless of case; Python triple-quoted
// strings across lines; YAML keys; diff additions and removals.
func TestOtherLanguages(t *testing.T) {
	check := func(fence, code string, want map[string]tokenClass) {
		t.Helper()
		lines := codeRuns(t, fence, code)
		for text, class := range want {
			if got := classOf(lines, text); got != class {
				t.Errorf("%s: %q is class %d, want %d", fence, text, got, class)
			}
		}
	}
	check("bash", "# c\necho \"$HOME\" $USER\n", map[string]tokenClass{"# c": tComment, "$USER": tVariable})
	check("sql", "select a from t where b = 'x'\n", map[string]tokenClass{"select": tKeyword, "from": tKeyword, "'x'": tString})
	check("python", "def f():\n    \"\"\"doc\n    more\"\"\"\n", map[string]tokenClass{"def": tKeyword, "\"\"\"doc": tString, "more\"\"\"": tString})
	check("yaml", "name: Reader # c\nflag: true\n", map[string]tokenClass{"name": tKey, "# c": tComment, "true": tConstant})
	check("diff", "@@ -1 +1 @@\n-old\n+new\n", map[string]tokenClass{"@@ -1 +1 @@": tHunk, "-old": tRemoved, "+new": tAdded})
}

// An unknown language stays exactly as before: one plain run per line.
func TestUnknownLanguageIsOnePlainRunPerLine(t *testing.T) {
	lines := codeRuns(t, "klingon", "alpha beta\ngamma\n")
	if len(lines) != 2 || len(lines[0]) != 1 || lines[0][0].class != tPlain || lines[0][0].text != "alpha beta\n" {
		t.Fatalf("got %v", lines)
	}
}
