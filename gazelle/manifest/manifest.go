package manifest

import (
	"encoding/json"
	"fmt"
	"os"
)

// PipRepository represents the pip repository configuration.
type PipRepository struct {
	Name string `json:"name"`
}

// Manifest represents the gazelle manifest.
type Manifest struct {
	ModulesMapping        map[string]string `json:"modules_mapping"`
	PipDepsRepositoryName string            `json:"pip_deps_repository_name"`
	PipRepository         *PipRepository    `json:"pip_repository"`
}

// File wraps a manifest file.
type File struct {
	Manifest *Manifest
}

// Decode reads and parses the manifest file at the given path.
func (f *File) Decode(path string) error {
	data, err := os.ReadFile(path)
	if err != nil {
		return fmt.Errorf("failed to read manifest file: %w", err)
	}

	f.Manifest = new(Manifest)
	if err := json.Unmarshal(data, f.Manifest); err == nil {
		return nil
	}

	// Fallback: try YAML-like JSON or plain object wrapper.
	var wrapper struct {
		Manifest *Manifest `json:"manifest"`
	}
	if err := json.Unmarshal(data, &wrapper); err == nil && wrapper.Manifest != nil {
		f.Manifest = wrapper.Manifest
		return nil
	}

	return fmt.Errorf("failed to parse manifest file %q", path)
}
