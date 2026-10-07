package parser

import (
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path"
	"path/filepath"
	"sort"
	"strings"

	"github.com/git-pkgs/archives"
	"github.com/git-pkgs/manifests"
)

const (
	MaxInputBytes    = 64 << 20
	MaxEntryBytes    = 16 << 20
	MaxExpandedBytes = 256 << 20
	MaxEntries       = 10000
)

type Report struct {
	Manifests []Manifest `json:"manifests"`
}

type Manifest struct {
	Ecosystem    string       `json:"ecosystem"`
	Path         string       `json:"path"`
	Dependencies []Dependency `json:"dependencies"`
	Kind         string       `json:"kind"`
	Success      bool         `json:"success"`
	RelatedPaths []string     `json:"related_paths"`
}

type Dependency struct {
	Name        string `json:"name"`
	Requirement string `json:"requirement"`
	Type        string `json:"type"`
	Local       *bool  `json:"local,omitempty"`
}

type inputFile struct {
	path    string
	content []byte
}

type scanner struct {
	files    []inputFile
	seen     map[string]bool
	entries  int
	expanded int64
}

func Identify(name string) bool {
	_, _, ok := manifests.Identify(name)
	return ok
}

func Parse(filename string, stripComponents int) (Report, error) {
	report := Report{Manifests: []Manifest{}}
	info, err := os.Stat(filename)
	if err != nil {
		return report, err
	}
	scan := scanner{seen: make(map[string]bool)}
	single := !info.IsDir() && Identify(filepath.Base(filename))
	switch {
	case info.IsDir():
		err = scan.directory(filename)
	case single:
		err = scan.file(filename, filepath.Base(filename), info)
	default:
		err = scan.archive(filename, stripComponents)
	}
	if err != nil {
		return report, err
	}
	for _, file := range scan.files {
		report.Manifests = append(report.Manifests, parseManifest(file, single))
	}
	sort.Slice(report.Manifests, func(i, j int) bool {
		a, b := report.Manifests[i], report.Manifests[j]
		if a.Ecosystem != b.Ecosystem {
			return a.Ecosystem < b.Ecosystem
		}
		return a.Path < b.Path
	})
	if !single {
		relateManifests(report.Manifests)
	}
	return report, nil
}

func (s *scanner) directory(root string) error {
	return filepath.WalkDir(root, func(filename string, entry fs.DirEntry, walkErr error) error {
		if walkErr != nil {
			return walkErr
		}
		if filename == root {
			return nil
		}
		relative, err := filepath.Rel(root, filename)
		if err != nil {
			return err
		}
		name := filepath.ToSlash(relative)
		if entry.IsDir() {
			if ignored(name) {
				return filepath.SkipDir
			}
			return nil
		}
		if !entry.Type().IsRegular() {
			return nil
		}
		info, err := entry.Info()
		if err != nil {
			return err
		}
		return s.file(filename, name, info)
	})
}

func (s *scanner) file(filename, name string, info fs.FileInfo) error {
	if !info.Mode().IsRegular() {
		return fmt.Errorf("not a regular file: %s", name)
	}
	if err := s.count(info.Size()); err != nil {
		return err
	}
	if ignored(name) || !Identify(name) {
		return nil
	}
	file, err := os.Open(filename)
	if err != nil {
		return err
	}
	defer func() { _ = file.Close() }()
	return s.add(name, file)
}

func (s *scanner) archive(filename string, stripComponents int) error {
	file, err := os.Open(filename)
	if err != nil {
		return err
	}
	defer func() { _ = file.Close() }()
	stream, err := archives.OpenStream(filename, file, archives.StreamOptions{
		MaxInputBytes: MaxInputBytes, MaxEntryBytes: MaxEntryBytes,
		MaxExpandedBytes: MaxExpandedBytes, MaxEntries: MaxEntries,
	})
	if errors.Is(err, errors.ErrUnsupported) {
		return nil
	}
	if err != nil {
		return err
	}
	defer func() { _ = stream.Close() }()
	for {
		entry, nextErr := stream.Next()
		if errors.Is(nextErr, io.EOF) {
			return nil
		}
		if nextErr != nil {
			return nextErr
		}
		if entry.IsDir || entry.IsHardlink || !fs.FileMode(entry.Mode).IsRegular() {
			continue
		}
		name, pathErr := archivePath(entry.Path, stripComponents)
		if pathErr != nil {
			return pathErr
		}
		if name == "" {
			continue
		}
		if s.seen[name] {
			return fmt.Errorf("duplicate archive path: %s", name)
		}
		s.seen[name] = true
		if ignored(name) || !Identify(name) {
			continue
		}
		if err := s.add(name, stream); err != nil {
			return err
		}
	}
}

func archivePath(name string, stripComponents int) (string, error) {
	name = strings.ReplaceAll(name, "\\", "/")
	clean := path.Clean(name)
	if strings.ContainsRune(name, '\x00') || strings.Contains(clean, ":") ||
		strings.HasPrefix(clean, "/") || clean == ".." || strings.HasPrefix(clean, "../") {
		return "", fmt.Errorf("unsafe archive path: %s", name)
	}
	for range stripComponents {
		_, clean, _ = strings.Cut(clean, "/")
	}
	return clean, nil
}

func (s *scanner) count(size int64) error {
	s.entries++
	if s.entries > MaxEntries {
		return archives.ErrEntryLimit
	}
	if size > MaxEntryBytes {
		return archives.ErrEntrySizeLimit
	}
	s.expanded += size
	if s.expanded > MaxExpandedBytes {
		return archives.ErrDecompressLimit
	}
	return nil
}

func (s *scanner) add(name string, reader io.Reader) error {
	content, err := io.ReadAll(io.LimitReader(reader, MaxEntryBytes+1))
	if err != nil {
		return err
	}
	if len(content) > MaxEntryBytes {
		return archives.ErrEntrySizeLimit
	}
	s.files = append(s.files, inputFile{path: name, content: content})
	return nil
}

func ignored(name string) bool {
	for _, part := range strings.Split(name, "/") {
		switch part {
		case ".git", "node_modules", "bower_components", "vendor", "dist":
			return true
		}
	}
	return false
}
