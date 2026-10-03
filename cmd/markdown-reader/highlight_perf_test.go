package main

import (
	"strings"
	"testing"
	"time"
)

// Highlighting runs on untrusted documents, so its cost must grow linearly with the code. Fails if
// any pathological block of about a megabyte takes more than a couple of seconds.
func TestHighlightingIsLinearOnPathologicalInput(t *testing.T) {
	size := 1 << 20
	inputs := map[string]string{
		"digits":           strings.Repeat("1", size),
		"hex digits":       "0x" + strings.Repeat("f", size),
		"exponent run":     "1" + strings.Repeat("e+1", size/3),
		"dots":             strings.Repeat("1.", size/2),
		"unterminated str": "\"" + strings.Repeat("a", size),
		"unterminated cmt": "/*" + strings.Repeat("a", size),
		"quotes":           strings.Repeat("'", size),
		"dollars":          strings.Repeat("$", size),
		"words":            strings.Repeat("ab ", size/3),
		"yaml colons":      strings.Repeat("a: b # c\n", size/9),
	}
	for name, code := range inputs {
		for _, lang := range []string{"go", "bash", "sql", "python", "json", "yaml", "diff"} {
			start := time.Now()
			highlight(lang, []byte(code))
			if d := time.Since(start); d > 2*time.Second {
				t.Errorf("%s as %s took %v", name, lang, d)
			}
		}
	}
}
