package main

import (
	"archive/tar"
	"archive/zip"
	"bytes"
	"compress/gzip"
	"encoding/json"
	"io"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"

	"github.com/ecosyste-ms/parser/internal/parser"
)

const (
	npmManifest  = "package.json"
	rubyManifest = "Gemfile"
)

func invoke(t *testing.T, args ...string) parser.Report {
	t.Helper()
	var output, diagnostics bytes.Buffer
	if err := run(args, &output, &diagnostics); err != nil {
		t.Fatalf("run: %v (%s)", err, &diagnostics)
	}
	var report parser.Report
	if err := json.Unmarshal(output.Bytes(), &report); err != nil {
		t.Fatal(err)
	}
	if report.Manifests == nil {
		t.Fatal("manifests must be an array")
	}
	return report
}

func writeFile(t *testing.T, dir, name, content string) string {
	t.Helper()
	filename := filepath.Join(dir, name)
	if err := os.MkdirAll(filepath.Dir(filename), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filename, []byte(content), 0o600); err != nil {
		t.Fatal(err)
	}
	return filename
}

func TestArchiveFixtures(t *testing.T) {
	for _, tc := range []struct {
		filename string
		paths    []string
		counts   []int
	}{
		{"main.zip", []string{"Dockerfile", "package-lock.json", npmManifest}, []int{1, 6, 2}},
		{"vald-client-clj-v1.5.6.jar", []string{"leiningen/vald-client-clj/vald-client-clj/project.clj", "maven/vald-client-clj/vald-client-clj/pom.xml"}, []int{5, 7}},
	} {
		t.Run(tc.filename, func(t *testing.T) {
			report := invoke(t, "-strip-components", "1", filepath.Join("../../test/fixtures/files", tc.filename))
			if len(report.Manifests) != len(tc.paths) {
				t.Fatalf("manifests: %+v", report.Manifests)
			}
			for i, manifest := range report.Manifests {
				if manifest.Path != tc.paths[i] || len(manifest.Dependencies) != tc.counts[i] || !manifest.Success {
					t.Fatalf("manifest %d: %+v", i, manifest)
				}
			}
		})
	}
}

func TestSingleManifestCompatibility(t *testing.T) {
	for _, tc := range []struct {
		name, content, ecosystem, kind, dependency, requirement string
	}{
		{rubyManifest, "gem 'rack', '~> 3.0'\n", "rubygems", "manifest", "rack", "~> 3.0"},
		{"go.sum", "example.org/module v1.2.3 h1:abc\n", "go", "lockfile", "example.org/module", "v1.2.3"},
		{"composer.json", `{"require":{"vendor/package":"^1.0"}}`, "packagist", "manifest", "vendor/package", "^1.0"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			filename := writeFile(t, t.TempDir(), tc.name, tc.content)
			report := invoke(t, filename)
			if len(report.Manifests) != 1 {
				t.Fatalf("manifests: %+v", report.Manifests)
			}
			manifest := report.Manifests[0]
			if manifest.Ecosystem != tc.ecosystem || manifest.Kind != tc.kind || manifest.Path != tc.name || !manifest.Success {
				t.Fatalf("manifest: %+v", manifest)
			}
			if manifest.RelatedPaths != nil {
				t.Fatalf("single-file related_paths: %+v", manifest.RelatedPaths)
			}
			if len(manifest.Dependencies) != 1 || manifest.Dependencies[0].Name != tc.dependency || manifest.Dependencies[0].Requirement != tc.requirement {
				t.Fatalf("dependencies: %+v", manifest.Dependencies)
			}
		})
	}
}

func TestDirectoryRelationshipsAndFailures(t *testing.T) {
	dir := t.TempDir()
	writeFile(t, dir, npmManifest, `{"dependencies":{"z":"^2","a":"file:../a"}}`)
	writeFile(t, dir, "package-lock.json", `{"lockfileVersion":3,"packages":{}}`)
	writeFile(t, dir, "nested/package.json", "{")
	writeFile(t, dir, "node_modules/ignored/package.json", `{"dependencies":{"ignored":"1"}}`)
	report := invoke(t, dir)
	if len(report.Manifests) != 3 {
		t.Fatalf("manifests: %+v", report.Manifests)
	}
	byPath := make(map[string]parser.Manifest)
	for _, item := range report.Manifests {
		byPath[item.Path] = item
	}
	manifest := byPath[npmManifest]
	if !reflect.DeepEqual(manifest.RelatedPaths, []string{"package-lock.json"}) {
		t.Fatalf("related paths: %v", manifest.RelatedPaths)
	}
	lock := byPath["package-lock.json"]
	if !reflect.DeepEqual(lock.RelatedPaths, []string{npmManifest}) || lock.Dependencies == nil || !lock.Success {
		t.Fatalf("lockfile: %+v", lock)
	}
	broken := byPath["nested/package.json"]
	if broken.Success || broken.Dependencies != nil || broken.RelatedPaths == nil {
		t.Fatalf("broken manifest: %+v", broken)
	}
	if len(manifest.Dependencies) != 2 || manifest.Dependencies[0].Name != "a" || manifest.Dependencies[0].Local == nil || !*manifest.Dependencies[0].Local {
		t.Fatalf("local dependency: %+v", manifest.Dependencies)
	}
	if !reflect.DeepEqual(report, invoke(t, dir)) {
		t.Fatal("output changed across repeated parses")
	}
}

type zipEntry struct {
	name, body string
	mode       os.FileMode
}

func writeZIP(t *testing.T, entries ...zipEntry) string {
	t.Helper()
	var buffer bytes.Buffer
	writer := zip.NewWriter(&buffer)
	for _, entry := range entries {
		header := &zip.FileHeader{Name: entry.name, Method: zip.Deflate}
		header.SetMode(entry.mode)
		file, err := writer.CreateHeader(header)
		if err != nil {
			t.Fatal(err)
		}
		if _, err := io.WriteString(file, entry.body); err != nil {
			t.Fatal(err)
		}
	}
	if err := writer.Close(); err != nil {
		t.Fatal(err)
	}
	return writeFile(t, t.TempDir(), "archive.zip", buffer.String())
}

func TestArchivePaths(t *testing.T) {
	for _, tc := range []struct {
		name    string
		entries []zipEntry
		message string
	}{
		{"traversal", []zipEntry{{name: "../package.json", body: "{}"}}, "unsafe archive path"},
		{"absolute", []zipEntry{{name: "/package.json", body: "{}"}}, "unsafe archive path"},
		{"duplicate", []zipEntry{{name: npmManifest, body: "{}"}, {name: "./package.json", body: "{}"}}, "duplicate archive path"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			filename := writeZIP(t, tc.entries...)
			var output bytes.Buffer
			err := run([]string{filename}, &output, io.Discard)
			if err == nil || !strings.Contains(err.Error(), tc.message) || output.Len() != 0 {
				t.Fatalf("error=%v output=%s", err, &output)
			}
		})
	}
	filename := writeZIP(t, zipEntry{name: npmManifest, body: "{}"}, zipEntry{name: rubyManifest, body: "/etc/passwd", mode: os.ModeSymlink})
	report := invoke(t, filename)
	if len(report.Manifests) != 1 || report.Manifests[0].Path != npmManifest {
		t.Fatalf("manifests: %+v", report.Manifests)
	}
}

func TestCompressedTarAndGem(t *testing.T) {
	var buffer bytes.Buffer
	compressed := gzip.NewWriter(&buffer)
	writer := tar.NewWriter(compressed)
	body := `{"dependencies":{"example":"^1"}}`
	if err := writer.WriteHeader(&tar.Header{Name: "package/package.json", Size: int64(len(body)), Mode: 0o644}); err != nil {
		t.Fatal(err)
	}
	if _, err := io.WriteString(writer, body); err != nil {
		t.Fatal(err)
	}
	if err := writer.Close(); err != nil {
		t.Fatal(err)
	}
	if err := compressed.Close(); err != nil {
		t.Fatal(err)
	}
	tarFile := writeFile(t, t.TempDir(), "package.tgz", buffer.String())
	report := invoke(t, "-strip-components", "1", tarFile)
	if len(report.Manifests) != 1 || report.Manifests[0].Path != npmManifest {
		t.Fatalf("manifests: %+v", report.Manifests)
	}
	var gem bytes.Buffer
	outer := tar.NewWriter(&gem)
	if err := outer.WriteHeader(&tar.Header{Name: "data.tar.gz", Size: int64(buffer.Len()), Mode: 0o644}); err != nil {
		t.Fatal(err)
	}
	if _, err := outer.Write(buffer.Bytes()); err != nil {
		t.Fatal(err)
	}
	if err := outer.Close(); err != nil {
		t.Fatal(err)
	}
	gemFile := writeFile(t, t.TempDir(), "package.gem", gem.String())
	if !reflect.DeepEqual(report, invoke(t, "-strip-components", "1", gemFile)) {
		t.Fatal("gem inner archive differs")
	}
}

func TestSizeLimits(t *testing.T) {
	filename := filepath.Join(t.TempDir(), npmManifest)
	file, err := os.Create(filename)
	if err != nil {
		t.Fatal(err)
	}
	if err := file.Truncate(parser.MaxEntryBytes + 1); err != nil {
		t.Fatal(err)
	}
	if err := file.Close(); err != nil {
		t.Fatal(err)
	}
	if err := run([]string{filename}, io.Discard, io.Discard); err == nil {
		t.Fatal("accepted oversized manifest")
	}
	var buffer bytes.Buffer
	writer := tar.NewWriter(&buffer)
	if err := writer.WriteHeader(&tar.Header{Name: "ignored.bin", Size: parser.MaxEntryBytes + 1, Mode: 0o644}); err != nil {
		t.Fatal(err)
	}
	archive := writeFile(t, t.TempDir(), "oversized.tar", buffer.String())
	if err := run([]string{archive}, io.Discard, io.Discard); err == nil || !strings.Contains(err.Error(), "size limit") {
		t.Fatalf("oversized archive entry: %v", err)
	}
}

func TestIdentifyAndUnknownFiles(t *testing.T) {
	for _, tc := range []struct {
		name      string
		supported bool
	}{{rubyManifest, true}, {npmManifest, true}, {"main.zip", false}, {"README.md", false}} {
		var output bytes.Buffer
		if err := run([]string{"-identify", "--", tc.name}, &output, io.Discard); err != nil {
			t.Fatal(err)
		}
		var result struct {
			Supported bool `json:"supported"`
		}
		if err := json.Unmarshal(output.Bytes(), &result); err != nil {
			t.Fatal(err)
		}
		if result.Supported != tc.supported {
			t.Fatalf("%s: %s", tc.name, &output)
		}
	}
	filename := writeFile(t, t.TempDir(), "README.md", "hello")
	if len(invoke(t, filename).Manifests) != 0 {
		t.Fatal("unknown file produced manifests")
	}
	if err := run(nil, io.Discard, io.Discard); err == nil {
		t.Fatal("accepted missing arguments")
	}
}
