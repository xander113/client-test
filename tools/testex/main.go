package main

import (
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
)

const solution = "Client_2016.sln"

type buildStep struct {
	name            string
	configuration   string
	targets         string
	output          string
	generateScripts bool
}

var buildSteps = []buildStep{
	{
		name:          "shared dependencies",
		configuration: "ReleaseStudio",
		targets:       `3rd Party\boost_static;3rd Party\zlib;3rd Party\libcurl;3rd Party\SDL2;Rendering\LibOVR;qtnribbon;sgCore`,
	},
	{
		name:          "ShaderCompiler",
		configuration: "ReleaseStudio",
		targets:       `Shaders\ShaderCompiler`,
		output:        "Rendering/ShaderCompiler/ShaderCompiler.exe",
	},
	{
		name:            "CoreScript converter",
		configuration:   "Release",
		targets:         "CoreScriptConverter2",
		output:          "CoreScriptConverter2/tool/win32/rsc.exe",
		generateScripts: true,
	},
	{
		name:          "Zbloc Player",
		configuration: "Release",
		targets:       "WindowsClient",
		output:        "WindowsClient/Win32/Release/RobloxPlayerBeta.exe",
	},
	{
		name:          "Zbloc Studio",
		configuration: "ReleaseStudio",
		targets:       "RobloxStudio",
		output:        "RobloxStudio/bin/Release/RobloxStudioBeta.exe",
	},
}

func runLogged(args []string, stdout, stderr io.Writer) int {
	logFile, err := os.CreateTemp("", "TESTEX-*.log")
	if err != nil {
		fmt.Fprintf(stderr, "Could not create a build log: %v\n", err)
	} else {
		defer logFile.Close()
		stdout = io.MultiWriter(stdout, logFile)
		stderr = io.MultiWriter(stderr, logFile)
		fmt.Fprintln(stdout, "Build log:", logFile.Name())
	}
	fmt.Fprintln(stdout, "TESTEX builds Zbloc Player and Studio.")
	if err := run(args, stdout, stderr); err != nil {
		if errors.Is(err, flag.ErrHelp) {
			return 0
		}
		fmt.Fprintln(stderr, "TESTEX:", err)
		return 1
	}
	fmt.Fprintln(stdout, "\nBuild complete.")
	return 0
}

func run(args []string, stdout, stderr io.Writer) error {
	flags := flag.NewFlagSet("TESTEX.exe", flag.ContinueOnError)
	flags.SetOutput(stderr)
	repo := flags.String("repo", "", "Path to the source checkout (defaults to the executable directory or current directory)")
	msbuildPath := flags.String("msbuild", "", "Explicit path to MSBuild.exe (defaults to PATH or MSBuild 4.0)")
	flags.Usage = func() {
		fmt.Fprintln(stderr, "TESTEX.exe builds Zbloc Player and Zbloc Studio for Win32.")
		flags.PrintDefaults()
	}
	if err := flags.Parse(args); err != nil {
		return err
	}
	if flags.NArg() != 0 {
		return fmt.Errorf("unexpected arguments: %s", strings.Join(flags.Args(), " "))
	}
	if runtime.GOOS != "windows" {
		return errors.New("building Player and Studio requires Windows and the Visual Studio 2012 C++ toolchain")
	}

	root, err := findRepo(*repo)
	if err != nil {
		return err
	}
	fmt.Fprintln(stdout, "Checkout:", root)
	vcTargets, err := findVCTargets()
	if err != nil {
		return err
	}
	msbuild, err := findMSBuild(*msbuildPath)
	if err != nil {
		return err
	}
	fmt.Fprintln(stdout, "MSBuild:", msbuild)
	fmt.Fprintln(stdout, "Visual C++ targets:", vcTargets.path)
	return build(root, msbuild, vcTargets, stdout, stderr)
}

func findRepo(path string) (string, error) {
	if path == "" {
		executable, err := os.Executable()
		if err != nil {
			return "", err
		}
		path = filepath.Dir(executable)
		if !isFile(filepath.Join(path, solution)) {
			path = "."
		}
	}
	root, err := filepath.Abs(path)
	if err != nil {
		return "", err
	}
	if !isFile(filepath.Join(root, solution)) {
		return "", fmt.Errorf("could not find %s in %q. Download or clone the full client-test repository and run TESTEX.exe from its root, or select that directory with -repo", solution, root)
	}
	return root, nil
}

type vcTargetSet struct {
	path    string
	version string
}

func findVCTargets() (vcTargetSet, error) {
	if path := filepath.Clean(os.Getenv("VCTargetsPath")); hasVCTargets(path) {
		version := os.Getenv("VisualStudioVersion")
		if strings.EqualFold(filepath.Base(path), "V110") {
			version = "11.0"
		}
		return vcTargetSet{path: path, version: version}, nil
	}

	// VS 2012 uses the 32-bit MSBuild extensions tree, even on 64-bit Windows.
	for _, variable := range []string{"MSBuildExtensionsPath32", "ProgramFiles(x86)", "ProgramW6432", "ProgramFiles"} {
		root := os.Getenv(variable)
		if root == "" {
			continue
		}
		if variable != "MSBuildExtensionsPath32" {
			root = filepath.Join(root, "MSBuild")
		}
		path := filepath.Join(root, "Microsoft.Cpp", "v4.0", "V110")
		if hasVCTargets(path) {
			return vcTargetSet{path: path, version: "11.0"}, nil
		}
	}
	return vcTargetSet{}, errors.New("Visual C++ MSBuild targets were not found (Microsoft.Cpp.Default.props). Install or repair Visual Studio 2012 Update 5 with Visual C++, MFC, and the v110/v110_xp toolsets, then run TESTEX.exe from the Visual Studio 2012 Developer Command Prompt")
}

func hasVCTargets(path string) bool {
	return filepath.IsAbs(path) &&
		isFile(filepath.Join(path, "Microsoft.Cpp.Default.props")) &&
		isFile(filepath.Join(path, "Microsoft.Cpp.props")) &&
		isFile(filepath.Join(path, "Microsoft.Cpp.targets"))
}

func findMSBuild(path string) (string, error) {
	if path != "" {
		absolute, err := filepath.Abs(path)
		if err != nil {
			return "", err
		}
		if !isFile(absolute) {
			return "", fmt.Errorf("MSBuild does not exist at %q", absolute)
		}
		return absolute, nil
	}
	if found, err := exec.LookPath("MSBuild.exe"); err == nil {
		return filepath.Abs(found)
	}
	if windows := os.Getenv("SystemRoot"); windows != "" {
		legacy := filepath.Join(windows, "Microsoft.NET", "Framework", "v4.0.30319", "MSBuild.exe")
		if isFile(legacy) {
			return legacy, nil
		}
	}
	return "", errors.New("MSBuild.exe is unavailable; use a Visual Studio Developer Command Prompt or pass -msbuild")
}

func build(root, msbuild string, vcTargets vcTargetSet, stdout, stderr io.Writer) error {
	contrib := filepath.Join(root, "Contribs")
	for _, step := range buildSteps {
		fmt.Fprintf(stdout, "\nBuilding %s (%s|Win32)\n", step.name, step.configuration)
		args := []string{solution, "/nologo", "/m:1", "/nodeReuse:false",
			"/p:Configuration=" + step.configuration, "/p:Platform=Win32", "/t:" + step.targets,
			"/p:VCTargetsPath=" + vcTargets.path + string(filepath.Separator)}
		if vcTargets.version != "" {
			args = append(args, "/p:VisualStudioVersion="+vcTargets.version)
		}
		command := exec.Command(msbuild, args...)
		command.Dir = root
		command.Env = append(os.Environ(), "CONTRIB_PATH="+contrib)
		command.Stdout = stdout
		command.Stderr = stderr
		if err := command.Run(); err != nil {
			return fmt.Errorf("%s build failed: %w", step.name, err)
		}
		if step.output != "" {
			outputPath := filepath.Join(root, step.output)
			if !isFile(outputPath) {
				return fmt.Errorf("%s build did not produce %s", step.name, outputPath)
			}
			fmt.Fprintf(stdout, "%s: %s\n", step.name, outputPath)
		}
		if step.generateScripts {
			fmt.Fprintln(stdout, "\nGenerating CoreScripts for Zbloc Player")
			scripts := exec.Command("cmd.exe", "/d", "/c", `CoreScriptConverter2\tool\win32\BuildCoreScripts.bat`)
			scripts.Dir = root
			scripts.Stdout = stdout
			scripts.Stderr = stderr
			if err := scripts.Run(); err != nil {
				return fmt.Errorf("CoreScript generation failed: %w", err)
			}
		}
	}
	return nil
}

func isFile(path string) bool {
	info, err := os.Stat(path)
	return err == nil && info.Mode().IsRegular() && info.Size() > 0
}
