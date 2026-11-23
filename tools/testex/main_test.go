package main

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestRunLoggedPreservesStartupFailure(t *testing.T) {
	temp := t.TempDir()
	t.Setenv("TMPDIR", temp)
	t.Setenv("TEMP", temp)
	t.Setenv("TMP", temp)

	var stdout, stderr bytes.Buffer
	if code := runLogged([]string{"unexpected-argument"}, &stdout, &stderr); code != 1 {
		t.Fatalf("exit code = %d, want 1", code)
	}
	const wantError = "TESTEX: unexpected arguments: unexpected-argument"
	if !strings.Contains(stderr.String(), wantError) {
		t.Fatalf("stderr = %q, want %q", &stderr, wantError)
	}
	paths, err := filepath.Glob(filepath.Join(temp, "TESTEX-*.log"))
	if err != nil || len(paths) != 1 {
		t.Fatalf("expected one log, got %v (%v)", paths, err)
	}
	if !strings.Contains(stdout.String(), paths[0]) {
		t.Fatalf("startup did not report the log location: %q", &stdout)
	}
	log, err := os.ReadFile(paths[0])
	if err != nil || !strings.Contains(string(log), wantError) {
		t.Fatalf("startup error missing from log: %q (%v)", log, err)
	}
}

func TestFindRepoExplainsMissingCheckout(t *testing.T) {
	_, err := findRepo(t.TempDir())
	if err == nil || !strings.Contains(err.Error(), solution) || !strings.Contains(err.Error(), "full client-test repository") {
		t.Fatalf("expected a missing-checkout error with recovery instructions, got %v", err)
	}
}

func TestFindVCTargets(t *testing.T) {
	for _, variable := range []string{"VCTargetsPath", "VisualStudioVersion", "MSBuildExtensionsPath32", "ProgramFiles(x86)", "ProgramW6432", "ProgramFiles"} {
		t.Setenv(variable, "")
	}
	install := filepath.Join(t.TempDir(), "Program Files (x86)")
	writeTargets := func(t *testing.T, path string) {
		t.Helper()
		if err := os.MkdirAll(path, 0755); err != nil {
			t.Fatal(err)
		}
		for _, name := range []string{"Microsoft.Cpp.Default.props", "Microsoft.Cpp.props", "Microsoft.Cpp.targets"} {
			if err := os.WriteFile(filepath.Join(path, name), []byte("<Project />\n"), 0644); err != nil {
				t.Fatal(err)
			}
		}
	}

	t.Run("missing C++ targets", func(t *testing.T) {
		t.Setenv("VCTargetsPath", install)
		_, err := findVCTargets()
		if err == nil || !strings.Contains(err.Error(), "Microsoft.Cpp.Default.props") || !strings.Contains(err.Error(), "Visual Studio 2012 Update 5") {
			t.Fatalf("expected an actionable error for missing Visual C++ targets, got %v", err)
		}
	})

	t.Run("find VS 2012 with an invalid inherited path", func(t *testing.T) {
		t.Setenv("VCTargetsPath", install)
		t.Setenv("ProgramFiles(x86)", install)
		path := filepath.Join(install, "MSBuild", "Microsoft.Cpp", "v4.0", "V110")
		writeTargets(t, path)
		want := vcTargetSet{path: path, version: "11.0"}
		got, err := findVCTargets()
		if err != nil || got != want {
			t.Fatalf("findVCTargets() = (%+v, %v), want %+v", got, err, want)
		}
	})

	t.Run("preserve a valid developer environment", func(t *testing.T) {
		path := filepath.Join(t.TempDir(), "Custom VC Targets")
		writeTargets(t, path)
		t.Setenv("VCTargetsPath", path+string(filepath.Separator))
		t.Setenv("VisualStudioVersion", "17.0")
		want := vcTargetSet{path: path, version: "17.0"}
		got, err := findVCTargets()
		if err != nil || got != want {
			t.Fatalf("findVCTargets() = (%+v, %v), want %+v", got, err, want)
		}
	})
}
