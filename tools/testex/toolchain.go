package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
)

type vcTargetSet struct {
	path    string
	version string
	msbuild string
}

type visualStudioInstallation struct {
	Path    string `json:"installationPath"`
	Version string `json:"installationVersion"`
	Name    string `json:"displayName"`
}

var requiredToolsets = []string{"v110", "v110_xp"}

func visualStudioInstallations(stdout io.Writer) []visualStudioInstallation {
	for _, variable := range []string{"ProgramFiles(x86)", "ProgramW6432", "ProgramFiles"} {
		root := os.Getenv(variable)
		if root == "" {
			continue
		}
		vswhere := filepath.Join(root, "Microsoft Visual Studio", "Installer", "vswhere.exe")
		if !isFile(vswhere) {
			continue
		}
		output, err := exec.Command(vswhere, "-all", "-products", "*", "-legacy", "-format", "json", "-utf8").Output()
		if err != nil {
			fmt.Fprintf(stdout, "Visual Studio Installer discovery failed: %v\n", err)
			break
		}
		var installations []visualStudioInstallation
		if err := json.Unmarshal(output, &installations); err != nil {
			fmt.Fprintf(stdout, "Could not read the Visual Studio Installer results: %v\n", err)
			break
		}
		for _, installation := range installations {
			name := installation.Name
			if name == "" {
				name = "Visual Studio"
			}
			fmt.Fprintf(stdout, "%s %s: %s\n", name, installation.Version, installation.Path)
		}
		return installations
	}
	fmt.Fprintln(stdout, "Visual Studio Installer inventory unavailable. Checking registered legacy paths and the current environment.")
	return nil
}

func registeredVCTargets() []vcTargetSet {
	windows := os.Getenv("SystemRoot")
	if windows == "" {
		return nil
	}
	reg := filepath.Join(windows, "System32", "reg.exe")
	const key = "HKLM\\SOFTWARE\\Microsoft\\MSBuild\\ToolsVersions\\4.0"
	var candidates []vcTargetSet
	for _, view := range []string{"/reg:32", "/reg:64"} {
		output, err := exec.Command(reg, "query", key, "/v", "VCTargetsPath11", view).Output()
		if err != nil {
			continue
		}
		path := registryTargetPath(string(output))
		if filepath.IsAbs(path) {
			candidates = append(candidates, vcTargetSet{path: path, version: "11.0"})
		}
	}
	return candidates
}

func registryTargetPath(output string) string {
	for _, line := range strings.Split(output, "\n") {
		name, rest, _ := strings.Cut(strings.TrimSpace(line), " ")
		if name != "VCTargetsPath11" {
			continue
		}
		kind, value, _ := strings.Cut(strings.TrimSpace(rest), " ")
		if kind == "REG_SZ" || kind == "REG_EXPAND_SZ" {
			return strings.TrimSpace(value)
		}
	}
	return ""
}

func findVCTargets(installations []visualStudioInstallation, registered []vcTargetSet, stdout io.Writer) (vcTargetSet, error) {
	candidates := append(legacyVCTargets(), registered...)
	for _, installation := range installations {
		candidates = append(candidates, installationTargets(installation)...)
	}
	if path := os.Getenv("VSINSTALLDIR"); path != "" {
		candidates = append(candidates, installationTargets(visualStudioInstallation{Path: path, Version: os.Getenv("VisualStudioVersion")})...)
	}
	if path := os.Getenv("VCTargetsPath"); path != "" {
		version := os.Getenv("VisualStudioVersion")
		if strings.EqualFold(filepath.Base(filepath.Clean(path)), "V110") {
			version = "11.0"
		}
		candidates = append(candidates, vcTargetSet{path: path, version: version})
	}

	seen := map[string]bool{}
	var selected vcTargetSet
	for _, candidate := range candidates {
		candidate.path = filepath.Clean(candidate.path)
		key := strings.ToLower(candidate.path)
		if seen[key] || !hasVCTargets(candidate.path) {
			continue
		}
		seen[key] = true
		var missing []string
		for _, toolset := range requiredToolsets {
			folder := filepath.Join(candidate.path, "Platforms", "Win32", "PlatformToolsets", toolset)
			if !isFile(filepath.Join(folder, "Toolset.props")) || !isFile(filepath.Join(folder, "Toolset.targets")) {
				missing = append(missing, toolset)
			}
		}
		if len(missing) != 0 {
			fmt.Fprintf(stdout, "Visual C++ targets at %s are missing Win32 toolsets: %s\n", candidate.path, strings.Join(missing, ", "))
			continue
		}
		if selected.path == "" {
			selected = candidate
		}
	}
	if selected.path != "" {
		return selected, nil
	}
	if len(seen) != 0 {
		return vcTargetSet{}, errors.New("the detected Visual C++ target directories lack one or both required Win32 toolsets (v110 and v110_xp). Install or repair the Visual Studio 2012 C++ tools and Windows XP support")
	}
	return vcTargetSet{}, errors.New("no Visual C++ MSBuild targets (Microsoft.Cpp.Default.props) were detected. If Visual C++ 2012 is installed, run TESTEX from its x86 Native Tools Command Prompt to expose its configuration")
}

func legacyVCTargets() []vcTargetSet {
	var candidates []vcTargetSet
	for _, variable := range []string{"MSBuildExtensionsPath32", "ProgramFiles(x86)", "ProgramW6432", "ProgramFiles"} {
		root := os.Getenv(variable)
		if root == "" {
			continue
		}
		if variable != "MSBuildExtensionsPath32" {
			root = filepath.Join(root, "MSBuild")
		}
		path := filepath.Join(root, "Microsoft.Cpp", "v4.0", "V110")
		candidates = append(candidates, vcTargetSet{path: path, version: "11.0"})
	}
	return candidates
}

func installationTargets(installation visualStudioInstallation) []vcTargetSet {
	if !filepath.IsAbs(installation.Path) {
		return nil
	}
	major, _, _ := strings.Cut(installation.Version, ".")
	if major == "11" {
		root := filepath.Dir(filepath.Clean(installation.Path))
		return []vcTargetSet{{path: filepath.Join(root, "MSBuild", "Microsoft.Cpp", "v4.0", "V110"), version: "11.0"}}
	}
	msbuild := ""
	for _, layout := range []string{"Current", major + ".0"} {
		candidate := filepath.Join(installation.Path, "MSBuild", layout, "Bin", "MSBuild.exe")
		if isFile(candidate) {
			msbuild = candidate
			break
		}
	}
	directories, _ := filepath.Glob(filepath.Join(installation.Path, "MSBuild", "Microsoft", "VC", "v*"))
	var candidates []vcTargetSet
	for _, path := range directories {
		version := ""
		if major != "" {
			version = major + ".0"
		}
		candidates = append(candidates, vcTargetSet{path: path, version: version, msbuild: msbuild})
	}
	return candidates
}

func hasVCTargets(path string) bool {
	return filepath.IsAbs(path) &&
		isFile(filepath.Join(path, "Microsoft.Cpp.Default.props")) &&
		isFile(filepath.Join(path, "Microsoft.Cpp.props")) &&
		isFile(filepath.Join(path, "Microsoft.Cpp.targets"))
}
