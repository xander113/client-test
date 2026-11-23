package main

import (
	"bytes"
	"io"
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
	for _, variable := range []string{"VCTargetsPath", "VisualStudioVersion", "MSBuildExtensionsPath32", "ProgramFiles(x86)", "ProgramW6432", "ProgramFiles", "VSINSTALLDIR"} {
		t.Setenv(variable, "")
	}
	install := filepath.Join(t.TempDir(), "Program Files (x86)")
	writeTargets := func(t *testing.T, path string, toolsets ...string) {
		t.Helper()
		if err := os.MkdirAll(path, 0755); err != nil {
			t.Fatal(err)
		}
		files := []string{"Microsoft.Cpp.Default.props", "Microsoft.Cpp.props", "Microsoft.Cpp.targets"}
		for _, toolset := range toolsets {
			folder := filepath.Join("Platforms", "Win32", "PlatformToolsets", toolset)
			if err := os.MkdirAll(filepath.Join(path, folder), 0755); err != nil {
				t.Fatal(err)
			}
			files = append(files, filepath.Join(folder, "Toolset.props"), filepath.Join(folder, "Toolset.targets"))
		}
		for _, name := range files {
			if err := os.WriteFile(filepath.Join(path, name), []byte("<Project />\n"), 0644); err != nil {
				t.Fatal(err)
			}
		}
	}

	t.Run("missing C++ targets", func(t *testing.T) {
		t.Setenv("VCTargetsPath", install)
		_, err := findVCTargets(nil, nil, io.Discard)
		if err == nil || !strings.Contains(err.Error(), "Microsoft.Cpp.Default.props") {
			t.Fatalf("expected an actionable error for missing Visual C++ targets, got %v", err)
		}
	})

	t.Run("find VS 2012 with an invalid inherited path", func(t *testing.T) {
		t.Setenv("VCTargetsPath", install)
		t.Setenv("ProgramFiles(x86)", install)
		path := filepath.Join(install, "MSBuild", "Microsoft.Cpp", "v4.0", "V110")
		writeTargets(t, path, "v110", "v110_xp")
		want := vcTargetSet{path: path, version: "11.0"}
		got, err := findVCTargets(nil, nil, io.Discard)
		if err != nil || got != want {
			t.Fatalf("findVCTargets(nil, nil, io.Discard) = (%+v, %v), want %+v", got, err, want)
		}
	})

	t.Run("preserve a valid developer environment", func(t *testing.T) {
		path := filepath.Join(t.TempDir(), "Custom VC Targets")
		writeTargets(t, path, "v110", "v110_xp")
		t.Setenv("VCTargetsPath", path+string(filepath.Separator))
		t.Setenv("VisualStudioVersion", "17.0")
		want := vcTargetSet{path: path, version: "17.0"}
		got, err := findVCTargets(nil, nil, io.Discard)
		if err != nil || got != want {
			t.Fatalf("findVCTargets(nil, nil, io.Discard) = (%+v, %v), want %+v", got, err, want)
		}
	})
}

func TestFindVCTargetsFromInstaller(t *testing.T) {
	for _, name := range []string{"MSBuildExtensionsPath32", "ProgramFiles(x86)", "ProgramW6432", "ProgramFiles", "VSINSTALLDIR", "VCTargetsPath"} {
		t.Setenv(name, "")
	}
	root := filepath.Join(t.TempDir(), "Custom VS Build Tools")
	path := filepath.Join(root, "MSBuild", "Microsoft", "VC", "v170")
	msbuild := filepath.Join(root, "MSBuild", "Current", "Bin", "MSBuild.exe")
	write := func(path string) {
		t.Helper()
		if err := os.MkdirAll(filepath.Dir(path), 0755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(path, []byte("fixture"), 0644); err != nil {
			t.Fatal(err)
		}
	}
	write(msbuild)
	for _, name := range []string{"Microsoft.Cpp.Default.props", "Microsoft.Cpp.props", "Microsoft.Cpp.targets"} {
		write(filepath.Join(path, name))
	}
	addToolset := func(name string) {
		folder := filepath.Join(path, "Platforms", "Win32", "PlatformToolsets", name)
		write(filepath.Join(folder, "Toolset.props"))
		write(filepath.Join(folder, "Toolset.targets"))
	}
	install := []visualStudioInstallation{{Path: root, Version: "17.14.3"}}
	addToolset("v143")
	var report bytes.Buffer
	_, err := findVCTargets(install, nil, &report)
	if err == nil || !strings.Contains(report.String(), "missing Win32 toolsets: v110, v110_xp") {
		t.Fatalf("expected to identify the missing legacy toolsets, got %v and %q", err, &report)
	}

	addToolset("v110")
	addToolset("v110_xp")
	targets, err := findVCTargets(install, nil, io.Discard)
	if err != nil || targets != (vcTargetSet{path: path, version: "17.0", msbuild: msbuild}) {
		t.Fatalf("did not find the compatible custom installation: %+v (%v)", targets, err)
	}
	engine, err := findMSBuild("", targets)
	if err != nil || engine != msbuild {
		t.Fatalf("expected MSBuild from the discovered installation, got %q (%v)", engine, err)
	}
}

func TestRegistryTargetPath(t *testing.T) {
	output := "HKEY_LOCAL_MACHINE\\SOFTWARE\\Microsoft\\MSBuild\\ToolsVersions\\4.0\r\n    VCTargetsPath11    REG_SZ    D:\\Custom MSBuild\\Microsoft.Cpp\\v4.0\\V110\\\r\n"
	const expected = "D:\\Custom MSBuild\\Microsoft.Cpp\\v4.0\\V110\\"
	if got := registryTargetPath(output); got != expected {
		t.Fatalf("registryTargetPath = %q, want %q", got, expected)
	}
}
