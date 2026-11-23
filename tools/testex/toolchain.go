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
	toolset string
}

type visualStudioInstallation struct {
	Path    string `json:"installationPath"`
	Version string `json:"installationVersion"`
	Name    string `json:"displayName"`
}

var legacyToolsets = []string{"v110", "v110_xp"}

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

func findVCTargets(installations []visualStudioInstallation, registered []vcTargetSet, requested string, stdout io.Writer) (vcTargetSet, error) {
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
	var legacy, modern vcTargetSet
	for _, candidate := range candidates {
		candidate.path = filepath.Clean(candidate.path)
		key := strings.ToLower(candidate.path)
		if seen[key] || !hasVCTargets(candidate.path) {
			continue
		}
		seen[key] = true
		var missing []string
		for _, toolset := range legacyToolsets {
			if !hasWin32Toolset(candidate.path, toolset) {
				missing = append(missing, toolset)
			}
		}
		if len(missing) == 0 && legacy.path == "" {
			legacy = candidate
		}
		for _, toolset := range []string{"v145", "v143"} {
			if (requested == "auto" || requested == toolset) && hasWin32Toolset(candidate.path, toolset) {
				if modern.path == "" || (modern.toolset == "v143" && toolset == "v145") {
					modern = candidate
					modern.toolset = toolset
				}
				break
			}
		}
		if len(missing) != 0 {
			fmt.Fprintf(stdout, "Visual C++ targets at %s are missing legacy Win32 toolsets: %s\n", candidate.path, strings.Join(missing, ", "))
		}
	}
	if (requested == "legacy" || requested == "auto") && legacy.path != "" {
		return legacy, nil
	}
	if modern.path != "" {
		return modern, nil
	}
	if len(seen) != 0 {
		return vcTargetSet{}, fmt.Errorf("no matching Win32 toolset is available for -toolset %s. Install the MSVC x86/x64 tools and Windows SDK through the Visual Studio Installer", requested)
	}
	return vcTargetSet{}, errors.New("no Visual C++ MSBuild targets (Microsoft.Cpp.Default.props) were detected. Check the Desktop development with C++ workload in the Visual Studio Installer")
}

func hasWin32Toolset(targets, toolset string) bool {
	folder := filepath.Join(targets, "Platforms", "Win32", "PlatformToolsets", toolset)
	return isFile(filepath.Join(folder, "Toolset.props")) && isFile(filepath.Join(folder, "Toolset.targets"))
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

func resolveQt(root, path string, modern bool) (string, error) {
	if path == "" {
		if modern {
			return "", errors.New("Studio requires a Win32 Qt 4.8.5 SDK rebuilt with a compatible MSVC toolset. Pass its root directory with -qt or set ZBLOC_QT_ROOT. Use -component player to build Player independently")
		}
		path = filepath.Join(root, "Contribs", "Qt", "4.8.5", "win_VS2012")
	}
	path, err := filepath.Abs(path)
	if err != nil {
		return "", err
	}
	for _, part := range []string{
		"bin/moc.exe", "bin/uic.exe", "bin/rcc.exe", "include/QtCore/qglobal.h",
		"lib/qtmain.lib", "lib/QtCore4.lib", "lib/QtGui4.lib", "lib/QtNetwork4.lib", "lib/QtXml4.lib", "lib/QtWebKit4.lib",
		"lib/QtCore4.dll", "lib/QtGui4.dll", "lib/QtNetwork4.dll", "lib/QtXml4.dll", "lib/QtWebKit4.dll", "lib/phonon4.dll",
		"plugins/imageformats/qjpeg4.dll", "plugins/imageformats/qgif4.dll",
	} {
		if !isFile(filepath.Join(path, part)) {
			return "", fmt.Errorf("Studio's Qt SDK at %q is incomplete: missing %s", path, part)
		}
	}
	return path, nil
}

func stepsFor(component string, modern bool) []buildStep {
	var steps []buildStep
	for _, step := range buildSteps {
		switch step.name {
		case "CoreScript converter", "Zbloc Player":
			if component == "studio" {
				continue
			}
		case "Studio dependencies", "Zbloc Studio":
			if component == "player" {
				continue
			}
		case "shared dependencies":
			if modern {
				step.targets += ";DSBaseClasses"
			}
		}
		steps = append(steps, step)
	}
	return steps
}
