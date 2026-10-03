package main

import (
	"regexp"
	"strings"
	"unicode"
	"unicode/utf8"
)

// tokenClass travels in bits 8..11 of a code run's flags (a code line is never a heading, so those
// bits are free there). The reader maps each class to a colour.
type tokenClass uint32

const (
	tPlain tokenClass = iota
	tKeyword
	tString
	tComment
	tNumber
	tType
	tFunction
	tConstant
	tKey
	tVariable
	tAdded
	tRemoved
	tHunk
)

const tokenShift = 8

type span struct {
	start, end int
	class      tokenClass
}

// language describes a C-like scanner. Everything a language needs beyond this (JSON key detection,
// YAML, diff) is handled by the small special cases in highlight.
type language struct {
	keywords, types, constants, builtins map[string]bool
	lineComments                         []string
	blockOpen, blockClose                string
	quotes                               string // characters that open a string
	multiline                            string // quote characters whose strings may span lines
	triple                               bool   // Python-style triple quotes
	fold                                 bool   // keywords are case-insensitive
	dollar                               bool   // $name / ${name} variables
	capTypes                             bool   // Capitalised identifiers are types
	at                                   bool   // @name decorators / annotations
}

func words(s string) map[string]bool {
	m := map[string]bool{}
	for _, w := range strings.Fields(s) {
		m[w] = true
	}
	return m
}

var languages = func() map[string]*language {
	goLang := &language{
		keywords:     words("break default func interface select case defer go map struct chan else goto package switch const fallthrough if range type continue for import return var"),
		types:        words("string int int8 int16 int32 int64 uint uint8 uint16 uint32 uint64 uintptr bool byte rune error any float32 float64 complex64 complex128 comparable"),
		constants:    words("true false nil iota"),
		builtins:     words("append cap clear close complex copy delete imag len make max min new panic print println real recover"),
		lineComments: []string{"//"}, blockOpen: "/*", blockClose: "*/", quotes: "\"`'", multiline: "`", capTypes: true,
	}
	js := &language{
		keywords:     words("async await break case catch class const continue debugger default delete do else enum export extends finally for from function get if implements import in instanceof interface let new of package private protected public return set static super switch this throw try type typeof var void while with yield as readonly declare namespace abstract satisfies keyof"),
		types:        words("string number boolean any unknown never object symbol bigint void Array Promise Record Partial Map Set Date Error"),
		constants:    words("true false null undefined NaN Infinity"),
		lineComments: []string{"//"}, blockOpen: "/*", blockClose: "*/", quotes: "\"'`", multiline: "`", capTypes: true, dollar: false,
	}
	sh := &language{
		keywords:     words("if then else elif fi for while until do done case esac in function select time return exit break continue local export readonly declare unset source alias"),
		builtins:     words("echo cd pwd printf read test set shift eval exec trap kill wait true false cat ls grep sed awk git curl make go npm node python python3 pip brew docker kubectl sudo rm cp mv mkdir touch chmod chown find xargs tar ssh scp head tail sort uniq wc tee"),
		constants:    words("true false"),
		lineComments: []string{"#"}, quotes: "\"'", multiline: "\"'", dollar: true,
	}
	sql := &language{
		keywords:     words("select from where and or not in is null as join left right inner outer full cross on group by order having limit offset insert into values update set delete create alter drop table index view database schema primary key foreign references unique default check constraint distinct union all case when then else end exists between like ilike using with returning begin commit rollback grant revoke if cascade asc desc over partition returning truncate explain analyze trigger function replace temporary"),
		types:        words("int integer bigint smallint serial bigserial text varchar char boolean bool date time timestamp timestamptz numeric decimal real double precision uuid json jsonb bytea float"),
		constants:    words("true false null"),
		builtins:     words("count sum avg min max coalesce now lower upper length substring trim round"),
		lineComments: []string{"--"}, blockOpen: "/*", blockClose: "*/", quotes: "'\"", fold: true,
	}
	py := &language{
		keywords:     words("and as assert async await break class continue def del elif else except finally for from global if import in is lambda nonlocal not or pass raise return try while with yield match case"),
		types:        words("int str float bool list dict set tuple bytes object type"),
		constants:    words("True False None"),
		builtins:     words("print len range open isinstance enumerate zip map filter sorted sum min max abs super self cls"),
		lineComments: []string{"#"}, quotes: "\"'", triple: true, at: true,
	}
	json := &language{constants: words("true false null"), quotes: "\""}
	return map[string]*language{
		"go": goLang, "golang": goLang,
		"js": js, "javascript": js, "jsx": js, "mjs": js, "cjs": js, "ts": js, "typescript": js, "tsx": js,
		"sh": sh, "bash": sh, "zsh": sh, "shell": sh, "console": sh,
		"sql": sql, "pgsql": sql, "postgresql": sql, "mysql": sql, "sqlite": sql,
		"py": py, "python": py,
		"json": json, "jsonc": json, "json5": json,
	}
}()

var yamlLine = regexp.MustCompile(`^(\s*(?:-\s+)*)([^\s:#'"\-][^:#]*?|"[^"]*"|'[^']*')(:)(\s|$)`)

// highlight classifies the code of one fenced block. It returns nothing for unknown languages. The
// spans never overlap and are in order; text outside them is plain.
func highlight(lang string, src []byte) []span {
	lang = strings.ToLower(strings.TrimSpace(lang))
	switch lang {
	case "yaml", "yml":
		return highlightYAML(src)
	case "diff", "patch":
		return highlightDiff(src)
	}
	l := languages[lang]
	if l == nil {
		return nil
	}
	return scan(l, lang == "json" || lang == "jsonc" || lang == "json5", src)
}

func isIdentStart(r rune) bool { return r == '_' || unicode.IsLetter(r) }
func isIdent(r rune) bool      { return r == '_' || unicode.IsLetter(r) || unicode.IsDigit(r) }

func scan(l *language, json bool, src []byte) []span {
	var out []span
	n := len(src)
	add := func(a, b int, c tokenClass) { out = append(out, span{a, b, c}) }
	has := func(i int, s string) bool { return s != "" && i+len(s) <= n && string(src[i:i+len(s)]) == s }
	for i := 0; i < n; {
		c := src[i]
		// comments
		matched := false
		for _, m := range l.lineComments {
			if has(i, m) {
				j := i
				for j < n && src[j] != '\n' {
					j++
				}
				add(i, j, tComment)
				i, matched = j, true
				break
			}
		}
		if matched {
			continue
		}
		if has(i, l.blockOpen) {
			j := i + len(l.blockOpen)
			for j < n && !has(j, l.blockClose) {
				j++
			}
			if j < n {
				j += len(l.blockClose)
			}
			add(i, j, tComment)
			i = j
			continue
		}
		// strings
		if strings.IndexByte(l.quotes, c) >= 0 {
			q := c
			j := i + 1
			if l.triple && has(i, strings.Repeat(string(q), 3)) {
				closing := strings.Repeat(string(q), 3)
				j = i + 3
				for j < n && !has(j, closing) {
					if src[j] == '\\' {
						j++
					}
					j++
				}
				j = min(n, j+3)
			} else {
				multi := strings.IndexByte(l.multiline, q) >= 0
				for j < n && src[j] != q && (multi || src[j] != '\n') {
					if src[j] == '\\' && q != '\'' || src[j] == '\\' && !l.triple && q == '\'' {
						j++
					}
					j++
				}
				if j < n && src[j] == q {
					j++
				}
				j = min(j, n)
			}
			class := tString
			if json {
				k := j
				for k < n && (src[k] == ' ' || src[k] == '\t') {
					k++
				}
				if k < n && src[k] == ':' {
					class = tKey
				}
			}
			add(i, j, class)
			i = j
			continue
		}
		// shell variables
		if l.dollar && c == '$' && i+1 < n {
			j := i + 1
			switch {
			case src[j] == '{':
				for j < n && src[j] != '}' && src[j] != '\n' {
					j++
				}
				j = min(n, j+1)
			case src[j] == '(' || src[j] == '$' || src[j] == '?' || src[j] == '!' || src[j] == '#' || src[j] == '@' || src[j] == '*':
				j++
			default:
				for j < n && (src[j] == '_' || src[j] >= '0' && src[j] <= '9' || src[j] >= 'a' && src[j] <= 'z' || src[j] >= 'A' && src[j] <= 'Z') {
					j++
				}
			}
			if j > i+1 {
				add(i, j, tVariable)
				i = j
				continue
			}
		}
		// numbers
		if c >= '0' && c <= '9' || c == '.' && i+1 < n && src[i+1] >= '0' && src[i+1] <= '9' && (i == 0 || !isIdent(rune(src[i-1]))) {
			if i == 0 || !isIdent(rune(src[i-1])) {
				j := i
				hex := has(i, "0x") || has(i, "0X") // decided once: a sign after "e" is part of a decimal exponent only
				for j < n && (src[j] == '_' || src[j] == '.' && j+1 < n && src[j+1] != '.' || src[j] >= '0' && src[j] <= '9' || src[j] >= 'a' && src[j] <= 'z' || src[j] >= 'A' && src[j] <= 'Z' ||
					(src[j] == '+' || src[j] == '-') && j > i && (src[j-1] == 'e' || src[j-1] == 'E') && !hex) {
					j++
				}
				add(i, j, tNumber)
				i = j
				continue
			}
		}
		// decorators and annotations
		if l.at && c == '@' && i+1 < n && isIdentStart(rune(src[i+1])) {
			j := i + 1
			for j < n && (isIdent(rune(src[j])) || src[j] == '.') {
				j++
			}
			add(i, j, tFunction)
			i = j
			continue
		}
		// words
		r, size := utf8.DecodeRune(src[i:])
		if isIdentStart(r) {
			j := i + size
			for j < n {
				r2, s2 := utf8.DecodeRune(src[j:])
				if !isIdent(r2) {
					break
				}
				j += s2
			}
			word := string(src[i:j])
			key := word
			if l.fold {
				key = strings.ToLower(word)
			}
			k := j
			for k < n && (src[k] == ' ' || src[k] == '\t') {
				k++
			}
			call := k < n && src[k] == '('
			switch {
			case l.keywords[key]:
				add(i, j, tKeyword)
			case l.constants[key]:
				add(i, j, tConstant)
			case l.types[key]:
				add(i, j, tType)
			case call && !(l.dollar && false):
				add(i, j, tFunction)
			case l.builtins[key]:
				add(i, j, tFunction)
			case l.capTypes && unicode.IsUpper(r) && len(word) > 1:
				add(i, j, tType)
			}
			i = j
			continue
		}
		i += size
	}
	return out
}

func highlightYAML(src []byte) []span {
	var out []span
	pos := 0
	for _, line := range strings.SplitAfter(string(src), "\n") {
		if line == "" {
			break
		}
		body := strings.TrimRight(line, "\n")
		rest := 0
		if m := yamlLine.FindStringSubmatchIndex(body); m != nil && !strings.HasPrefix(strings.TrimSpace(body), "#") {
			out = append(out, span{pos + m[4], pos + m[5], tKey})
			rest = m[7]
		} else if t := strings.TrimLeft(body, " -"); t != body && t != "" {
			rest = len(body) - len(t)
		}
		out = append(out, yamlValue(body, rest, pos)...)
		pos += len(line)
	}
	return out
}

// yamlValue colours the value part of one YAML line: quoted strings, numbers, literals and the
// trailing comment.
func yamlValue(body string, from, base int) []span {
	var out []span
	for i := from; i < len(body); {
		c := body[i]
		switch {
		case c == '#' && (i == 0 || body[i-1] == ' ' || body[i-1] == '\t'):
			out = append(out, span{base + i, base + len(body), tComment})
			return out
		case c == '"' || c == '\'':
			j := i + 1
			for j < len(body) && body[j] != c {
				if body[j] == '\\' && c == '"' {
					j++
				}
				j++
			}
			j = min(len(body), j+1)
			out = append(out, span{base + i, base + j, tString})
			i = j
		case c >= '0' && c <= '9' && (i == 0 || body[i-1] == ' ' || body[i-1] == '[' || body[i-1] == ','):
			j := i
			for j < len(body) && (body[j] >= '0' && body[j] <= '9' || body[j] == '.' || body[j] == '_') {
				j++
			}
			if j == len(body) || strings.IndexByte(" ,]#", body[j]) >= 0 {
				out = append(out, span{base + i, base + j, tNumber})
			}
			i = j
		case isIdentStart(rune(c)) && (i == 0 || body[i-1] == ' ' || body[i-1] == '[' || body[i-1] == ','):
			j := i
			for j < len(body) && isIdent(rune(body[j])) {
				j++
			}
			if j == len(body) || strings.IndexByte(" ,]#", body[j]) >= 0 {
				switch strings.ToLower(body[i:j]) {
				case "true", "false", "null", "yes", "no", "on", "off", "~":
					out = append(out, span{base + i, base + j, tConstant})
				}
			}
			i = max(j, i+1)
		default:
			i++
		}
	}
	return out
}

func highlightDiff(src []byte) []span {
	var out []span
	pos := 0
	for _, line := range strings.SplitAfter(string(src), "\n") {
		if line == "" {
			break
		}
		body := strings.TrimRight(line, "\n")
		class := tPlain
		switch {
		case strings.HasPrefix(body, "@@"):
			class = tHunk
		case strings.HasPrefix(body, "+++") || strings.HasPrefix(body, "---") || strings.HasPrefix(body, "diff ") || strings.HasPrefix(body, "index "):
			class = tKeyword
		case strings.HasPrefix(body, "+"):
			class = tAdded
		case strings.HasPrefix(body, "-"):
			class = tRemoved
		}
		if class != tPlain && len(body) > 0 {
			out = append(out, span{pos, pos + len(body), class})
		}
		pos += len(line)
	}
	return out
}
