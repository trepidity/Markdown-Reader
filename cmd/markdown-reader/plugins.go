package main

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"encoding/xml"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"syscall"
	"time"
)

// Diagrams stream after the text. A placeholder record (flags placeholderRecord|style|index,
// text "Rendering diagram…\n") reserves the spot; bodyEndRecord says all text has been sent;
// then one lateRecord per placeholder (flags lateRecord|index, plus vectorRecord for a diagram,
// otherwise a failure text) replaces its placeholder. Style bits are the usual flags above
// bit 7; the index occupies the low byte. Bit 27 and below belong to quote depth.
const (
	vectorRecord      uint32 = 1 << 30
	placeholderRecord uint32 = 1 << 29
	lateRecord        uint32 = 1 << 28
	bodyEndRecord     uint32 = 1 << 31
	maxPluginDiagrams        = 16
)

// pluginParent is cancelled when the reader abandons this load (SIGTERM), which kills the
// running plugin's process group so no renderer outlives the document it was drawing.
var pluginParent = context.Background()

const maxPluginSource = 64 << 10
const maxPluginOutput = 8 << 20

type pluginManifest struct {
	SchemaVersion       int      `json:"schemaVersion"`
	ID                  string   `json:"id"`
	Name                string   `json:"name"`
	Version             string   `json:"version"`
	Languages           []string `json:"languages"`
	Executable          string   `json:"executable"`
	TimeoutMilliseconds int      `json:"timeoutMilliseconds"`
	Batch               bool     `json:"batch"`
	path                string
}
type pluginRegistry struct {
	languages   map[string]pluginManifest
	deadline    time.Time
	diagrams    int
	vectorBytes int
	area        int
}
type pluginResult struct {
	Index    int    `json:"index"` // batch lines only
	Error    string `json:"error"` // batch lines only
	Protocol int    `json:"protocol"`
	SVG      string `json:"svg"`
	PDF      []byte `json:"pdf"`
	Width    int    `json:"width"`
	Height   int    `json:"height"`
}

var pluginName = regexp.MustCompile(`^[a-z][a-z0-9-]{0,63}$`)

// Registries are explicitly supplied by the application, never searched for in
// document directories. Installed plugin executables are trusted application code.
func loadPlugins(root string) (*pluginRegistry, error) {
	r := &pluginRegistry{languages: map[string]pluginManifest{}}
	if root == "" {
		return r, nil
	}
	entries, err := os.ReadDir(root)
	if err != nil {
		return nil, fmt.Errorf("plugin registry: %w", err)
	}
	if len(entries) > 64 {
		return nil, errors.New("plugin registry exceeds 64 entries")
	}
	for _, entry := range entries {
		if !entry.IsDir() {
			continue
		}
		dir := filepath.Join(root, entry.Name())
		f, err := os.Open(filepath.Join(dir, "plugin.json"))
		if err != nil {
			return nil, err
		}
		decoder := json.NewDecoder(io.LimitReader(f, 32<<10))
		decoder.DisallowUnknownFields()
		var m pluginManifest
		err = decoder.Decode(&m)
		var extra any
		if err == nil && decoder.Decode(&extra) != io.EOF {
			err = errors.New("extra manifest data")
		}
		f.Close()
		if err != nil {
			return nil, fmt.Errorf("plugin %s: %w", entry.Name(), err)
		}
		if m.SchemaVersion != 1 || !pluginName.MatchString(m.ID) || m.ID != entry.Name() || m.Name == "" || m.Version == "" || len(m.Languages) == 0 || len(m.Languages) > 16 || m.Executable == "" || filepath.Base(m.Executable) != m.Executable || m.Executable == "." || m.TimeoutMilliseconds < 50 || m.TimeoutMilliseconds > 10000 {
			return nil, fmt.Errorf("invalid plugin manifest: %s", entry.Name())
		}
		m.path = filepath.Join(dir, m.Executable)
		info, err := os.Lstat(m.path)
		if err != nil || !info.Mode().IsRegular() || info.Mode()&0111 == 0 {
			return nil, fmt.Errorf("plugin %s executable must be a regular executable file", m.ID)
		}
		for _, language := range m.Languages {
			if !pluginName.MatchString(language) {
				return nil, fmt.Errorf("invalid language in plugin %s", m.ID)
			}
			if _, found := r.languages[language]; found {
				return nil, fmt.Errorf("multiple plugins claim %s", language)
			}
			r.languages[language] = m
		}
	}
	return r, nil
}

// Reject oversized output while reading it, rather than allocating first.
type boundedBuffer struct {
	bytes.Buffer
	limit int
}

func (b *boundedBuffer) Write(p []byte) (int, error) {
	if len(p) > b.limit-b.Len() {
		return 0, errors.New("plugin output limit exceeded")
	}
	return b.Buffer.Write(p)
}

func (r *pluginRegistry) render(language string, source []byte) (*pluginResult, string, error) {
	m, found := r.languages[language]
	if !found {
		return nil, "", nil
	}
	if len(source) > maxPluginSource {
		return nil, m.ID, errors.New("diagram source exceeds 64 KiB")
	}
	if r.diagrams >= maxPluginDiagrams {
		return nil, m.ID, errors.New("document exceeds 16 plugin diagrams")
	}
	if r.deadline.IsZero() {
		r.deadline = time.Now().Add(30 * time.Second)
	}
	deadline := time.Now().Add(time.Duration(m.TimeoutMilliseconds) * time.Millisecond)
	if deadline.After(r.deadline) {
		deadline = r.deadline
	}
	if time.Now().After(deadline) {
		return nil, m.ID, errors.New("document plugin time budget exhausted")
	}
	r.diagrams++
	input, _ := json.Marshal(struct {
		Protocol int    `json:"protocol"`
		Language string `json:"language"`
		Source   string `json:"source"`
		Width    int    `json:"width"`
	}{1, language, string(source), 900})
	ctx, cancel := context.WithDeadline(pluginParent, deadline)
	defer cancel()
	command := exec.CommandContext(ctx, m.path)
	command.Stdin = bytes.NewReader(input)
	// A timed-out plugin cannot leave ordinary descendants in its process group.
	command.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	command.Cancel = func() error { return syscall.Kill(-command.Process.Pid, syscall.SIGKILL) }
	command.WaitDelay = 250 * time.Millisecond
	output := &boundedBuffer{limit: maxPluginOutput}
	diagnostic := &boundedBuffer{limit: 4096}
	command.Stdout = output
	command.Stderr = diagnostic
	if err := command.Run(); err != nil {
		if ctx.Err() != nil {
			return nil, m.ID, errors.New("renderer timed out")
		}
		return nil, m.ID, fmt.Errorf("renderer failed: %w", err)
	}
	var result pluginResult
	if err := json.Unmarshal(output.Bytes(), &result); err != nil {
		return nil, m.ID, errors.New("renderer returned invalid JSON")
	}
	if err := r.accept(&result); err != nil {
		return nil, m.ID, err
	}
	return &result, m.ID, nil
}

// accept validates one plugin result and charges it to the document's vector budgets.
func (r *pluginRegistry) accept(result *pluginResult) error {
	if result.Protocol != 1 || result.Width < 1 || result.Width > 4096 || result.Height < 1 || result.Height > 4096 || result.Width*result.Height > 4_000_000 || len(result.PDF) > 4<<20 || len(result.SVG) > 2<<20 || !bytes.HasPrefix(result.PDF, []byte("%PDF-")) || !bytes.Contains(result.PDF, []byte("%%EOF")) {
		return errors.New("renderer returned invalid or oversized vector output")
	}
	decoder := xml.NewDecoder(strings.NewReader(result.SVG))
	var root struct{ XMLName xml.Name }
	if err := decoder.Decode(&root); err != nil || root.XMLName.Local != "svg" || root.XMLName.Space != "http://www.w3.org/2000/svg" {
		return errors.New("renderer did not return SVG")
	}
	size := len(result.PDF) + len(result.SVG)
	area := result.Width * result.Height
	if r.vectorBytes+size > 16<<20 || r.area+area > 16_000_000 {
		return errors.New("document diagram memory budget exhausted")
	}
	r.vectorBytes += size
	r.area += area
	return nil
}

// renderAll renders every deferred diagram and reports each as it finishes. A plugin whose
// manifest says "batch" gets all its diagrams in one process (protocol 2); others get one
// process per diagram (protocol 1). deliver returns false when nobody is listening any more.
func (r *pluginRegistry) renderAll(jobs []deferredDiagram, deliver func(i int, result *pluginResult, id string, err error) bool) {
	var order []string
	groups := map[string][]int{}
	for i, j := range jobs {
		id := r.languages[j.language].ID
		if _, seen := groups[id]; !seen {
			order = append(order, id)
		}
		groups[id] = append(groups[id], i)
	}
	for _, id := range order {
		indexes := groups[id]
		if m := r.languages[jobs[indexes[0]].language]; m.Batch {
			if !r.renderBatch(m, indexes, jobs, deliver) {
				return
			}
			continue
		}
		for _, i := range indexes {
			if pluginParent.Err() != nil {
				return
			}
			result, id, err := r.render(jobs[i].language, jobs[i].source)
			if !deliver(i, result, id, err) {
				return
			}
		}
	}
}

// renderBatch sends one request holding every source and reads one JSON line per diagram,
// in order, as the plugin finishes each. A line with an error fails only that diagram; a
// plugin that stalls, exits or misbehaves fails the diagrams it has not reached.
func (r *pluginRegistry) renderBatch(m pluginManifest, indexes []int, jobs []deferredDiagram, deliver func(int, *pluginResult, string, error) bool) bool {
	var pending []int // jobs actually sent to the plugin, in request order
	var sources []string
	for _, i := range indexes {
		switch {
		case len(jobs[i].source) > maxPluginSource:
			if !deliver(i, nil, m.ID, errors.New("diagram source exceeds 64 KiB")) {
				return false
			}
		case r.diagrams >= maxPluginDiagrams:
			if !deliver(i, nil, m.ID, errors.New("document exceeds 16 plugin diagrams")) {
				return false
			}
		default:
			r.diagrams++
			pending = append(pending, i)
			sources = append(sources, string(jobs[i].source))
		}
	}
	if len(pending) == 0 {
		return true
	}
	failRest := func(from int, err error) bool {
		for _, i := range pending[from:] {
			if !deliver(i, nil, m.ID, err) {
				return false
			}
		}
		return true
	}
	if r.deadline.IsZero() {
		r.deadline = time.Now().Add(30 * time.Second)
	}
	if time.Now().After(r.deadline) {
		return failRest(0, errors.New("document plugin time budget exhausted"))
	}
	input, _ := json.Marshal(struct {
		Protocol int      `json:"protocol"`
		Language string   `json:"language"`
		Sources  []string `json:"sources"`
		Width    int      `json:"width"`
	}{2, jobs[pending[0]].language, sources, 900})
	ctx, cancel := context.WithDeadline(pluginParent, r.deadline)
	defer cancel()
	command := exec.CommandContext(ctx, m.path)
	command.Stdin = bytes.NewReader(input)
	command.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	command.Cancel = func() error { return syscall.Kill(-command.Process.Pid, syscall.SIGKILL) }
	command.WaitDelay = 250 * time.Millisecond
	reader, writer := io.Pipe()
	command.Stdout = writer
	diagnostic := &boundedBuffer{limit: 4096}
	command.Stderr = diagnostic
	if err := command.Start(); err != nil {
		return failRest(0, fmt.Errorf("renderer failed: %w", err))
	}
	exited := make(chan error, 1)
	go func() { exited <- command.Wait(); writer.Close() }()
	lines := make(chan []byte)
	go func() {
		defer close(lines)
		scanner := bufio.NewScanner(reader)
		scanner.Buffer(make([]byte, 64<<10), maxPluginOutput)
		for scanner.Scan() {
			line := append([]byte(nil), scanner.Bytes()...)
			select {
			case lines <- line:
			case <-ctx.Done():
				io.Copy(io.Discard, reader)
				return
			}
		}
		io.Copy(io.Discard, reader)
	}()
	// Each diagram gets the manifest's time. The first also pays for the renderer's start-up,
	// which a loaded machine can stretch, so it gets twice as long.
	idle := time.NewTimer(2 * time.Duration(m.TimeoutMilliseconds) * time.Millisecond)
	defer idle.Stop()
	next, ok := 0, true
	var stopped error
	for next < len(pending) && stopped == nil {
		select {
		case line, open := <-lines:
			if !open {
				stopped = errors.New("renderer exited before finishing this diagram")
				break
			}
			var result pluginResult
			if err := json.Unmarshal(line, &result); err != nil {
				stopped = errors.New("renderer returned invalid JSON")
				break
			}
			if result.Index != next {
				stopped = errors.New("renderer returned results out of order")
				break
			}
			var failure error
			if result.Error != "" {
				failure = errors.New(result.Error)
			} else if failure = r.accept(&result); failure != nil {
				result = pluginResult{}
			}
			if failure != nil {
				ok = deliver(pending[next], nil, m.ID, failure)
			} else {
				ok = deliver(pending[next], &result, m.ID, nil)
			}
			next++
			if !ok {
				stopped = errors.New("reader went away")
			}
			if !idle.Stop() {
				select {
				case <-idle.C:
				default:
				}
			}
			idle.Reset(time.Duration(m.TimeoutMilliseconds) * time.Millisecond)
		case <-idle.C:
			stopped = errors.New("renderer timed out")
		case <-ctx.Done():
			stopped = errors.New("renderer timed out")
		}
	}
	cancel()
	<-exited
	if !ok {
		return false
	}
	if stopped != nil && next < len(pending) {
		return failRest(next, stopped)
	}
	return true
}
