package parser

import (
	"path"
	"sort"
	"strings"

	"github.com/git-pkgs/manifests"
)

func ecosystemName(name string) string {
	switch name {
	case "gem":
		return "rubygems"
	case "golang":
		return "go"
	case "composer":
		return "packagist"
	case "brew":
		return "homebrew"
	case "crystal":
		return "shards"
	case "swift":
		return "swiftpm"
	case "github-actions":
		return "actions"
	default:
		return name
	}
}

func parseManifest(file inputFile, single bool) Manifest {
	ecosystem, kind, _ := manifests.Identify(file.path)
	if kind == manifests.Supplement {
		kind = manifests.Lockfile
	}
	manifest := Manifest{Ecosystem: ecosystemName(ecosystem), Path: file.path, Kind: string(kind)}
	if !single {
		manifest.RelatedPaths = []string{}
	}
	result, err := manifests.Parse(file.path, file.content)
	if err != nil {
		return manifest
	}
	manifest.Success = true
	manifest.Dependencies = make([]Dependency, 0, len(result.Dependencies))
	for _, dependency := range result.Dependencies {
		dep := Dependency{Name: dependency.Name, Requirement: dependency.Version, Type: string(dependency.Scope)}
		if dep.Requirement == "" {
			dep.Requirement = "*"
		}
		if dep.Type == "" {
			dep.Type = "runtime"
		}
		if hasLocalField(file.path, ecosystem) {
			local := dependency.Source.Kind == manifests.SourcePath || strings.HasPrefix(dependency.Version, "file:")
			dep.Local = &local
		}
		manifest.Dependencies = append(manifest.Dependencies, dep)
	}
	sort.SliceStable(manifest.Dependencies, func(i, j int) bool {
		a, b := manifest.Dependencies[i], manifest.Dependencies[j]
		if a.Name != b.Name {
			return a.Name < b.Name
		}
		if a.Requirement != b.Requirement {
			return a.Requirement < b.Requirement
		}
		return a.Type < b.Type
	})
	return manifest
}

func hasLocalField(name, ecosystem string) bool {
	if ecosystem != "npm" {
		return false
	}
	switch path.Base(name) {
	case "package.json", "package-lock.json", "npm-shrinkwrap.json", "yarn.lock", "bun.lock":
		return true
	default:
		return false
	}
}

func relateManifests(items []Manifest) {
	for i := range items {
		item := &items[i]
		if !canRelate(*item) {
			continue
		}
		for j := range items {
			other := items[j]
			if i == j || item.Ecosystem != other.Ecosystem || path.Dir(item.Path) != path.Dir(other.Path) || !canRelate(other) {
				continue
			}
			if item.Kind != other.Kind || item.Ecosystem == "rubygems" || item.Ecosystem == "docker" {
				item.RelatedPaths = append(item.RelatedPaths, other.Path)
			}
		}
		sort.Strings(item.RelatedPaths)
	}
}

func canRelate(item Manifest) bool {
	switch item.Ecosystem {
	case "actions", "bower", "clojars", "conda", "dub", "haxelib", "nimble", "luarocks":
		return false
	case "cocoapods":
		return !strings.HasSuffix(item.Path, ".podspec")
	case "pypi":
		base := path.Base(item.Path)
		return base != "setup.py" && !strings.HasSuffix(base, ".txt") && !strings.HasSuffix(base, ".pip")
	default:
		return true
	}
}
