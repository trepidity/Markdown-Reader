package main

import (
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

const vectorRecord uint32 = 1 << 30
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
	if r.diagrams >= 16 {
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
	ctx, cancel := context.WithDeadline(context.Background(), deadline)
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
	if result.Protocol != 1 || result.Width < 1 || result.Width > 4096 || result.Height < 1 || result.Height > 4096 || result.Width*result.Height > 4_000_000 || len(result.PDF) > 4<<20 || len(result.SVG) > 2<<20 || !bytes.HasPrefix(result.PDF, []byte("%PDF-")) || !bytes.Contains(result.PDF, []byte("%%EOF")) {
		return nil, m.ID, errors.New("renderer returned invalid or oversized vector output")
	}
	decoder := xml.NewDecoder(strings.NewReader(result.SVG))
	var root struct{ XMLName xml.Name }
	if err := decoder.Decode(&root); err != nil || root.XMLName.Local != "svg" || root.XMLName.Space != "http://www.w3.org/2000/svg" {
		return nil, m.ID, errors.New("renderer did not return SVG")
	}
	size := len(result.PDF) + len(result.SVG)
	area := result.Width * result.Height
	if r.vectorBytes+size > 16<<20 || r.area+area > 16_000_000 {
		return nil, m.ID, errors.New("document diagram memory budget exhausted")
	}
	r.vectorBytes += size
	r.area += area
	return &result, m.ID, nil
}
