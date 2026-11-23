package place

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestBinaryFileAndLegacyImport(t *testing.T) {
	starter, err := Samples()
	if err != nil || len(starter) != 3 {
		t.Fatalf("load bundled projects: %v", err)
	}
	part := &starter[0].Parts[0]
	part.Rotation = Vec3{12.5, 90, -45}
	file := filepath.Join(t.TempDir(), "Scene with spaces.pot")
	if err := Save(file, starter[0]); err != nil {
		t.Fatal(err)
	}
	bits, err := os.ReadFile(file)
	if err != nil || !bytes.HasPrefix(bits, fileHeader) {
		t.Fatal("save did not write the Pot file magic", err)
	}
	scene, err := Load(file)
	if err != nil || scene.Parts[0].Rotation != part.Rotation {
		t.Fatalf("rotation failed to round-trip: %v", err)
	}
	if _, err := FromWire(append(bits[len(fileHeader):], 0)); err == nil {
		t.Fatal("accepted trailing project data")
	}
	legacy := []byte(`{"schemaVersion":1,"id":"old","name":"Old project","description":"","spawn":{"x":0,"y":0,"z":0},"objects":[{"id":"part","name":"Part","kind":"box","position":[1,2,3],"size":[2,2,4],"color":"#09B734","solid":true}]}`)
	old, err := decodeFile(legacy)
	if err != nil || old.Version != Version || old.Parts[0].Rotation != (Vec3{}) || old.Parts[0].Color != "#09b734" {
		t.Fatalf("legacy project migration failed: %v", err)
	}
	if err := Save(file, old); err != nil {
		t.Fatal(err)
	}
	rewritten, err := Load(file)
	if err != nil || rewritten.ID != old.ID {
		t.Fatalf("replacing existing file failed: %v", err)
	}
}

func TestValidateWorld(t *testing.T) {
	worlds, err := Samples()
	if err != nil {
		t.Fatal(err)
	}
	scene := worlds[1]
	scene.Parts = append(scene.Parts, scene.Parts[0])
	if err := scene.Validate(); err == nil || !strings.Contains(err.Error(), "unique") {
		t.Fatal("duplicate ID was accepted")
	}
	scene.Parts = scene.Parts[:len(scene.Parts)-1]
	scene.Parts[0].Rotation[0] = 360
	if err := scene.Validate(); err == nil {
		t.Fatal("unbounded rotation was accepted")
	}
	scene.Parts[0].Rotation[0] = 0
	scene.ID = "../invalid"
	if err := scene.Validate(); err == nil {
		t.Fatal("path used as an ID")
	}
}
