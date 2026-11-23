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
		targets:       `3rd Party\boost_static;3rd Party\zlib;3rd Party\libcurl;3rd Party\SDL2;Rendering\LibOVR`,
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
		name:          "Studio dependencies",
		configuration: "ReleaseStudio",
		targets:       "qtnribbon;sgCore",
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
	return 0
}

func run(args []string, stdout, stderr io.Writer) error {
	flags := flag.NewFlagSet("TESTEX.exe", flag.ContinueOnError)
	flags.SetOutput(stderr)
	repo := flags.String("repo", "", "Path to the source checkout (defaults to the executable directory or current directory)")
	msbuildPath := flags.String("msbuild", "", "Explicit path to MSBuild.exe")
	diagnose := flags.Bool("diagnose", false, "List the detected Visual Studio toolchain without building")
	toolset := flags.String("toolset", "auto", "Windows C++ toolset (auto, v143, v145, or legacy)")
	component := flags.String("component", "all", "Build all, player, or studio")
	qt := flags.String("qt", os.Getenv("ZBLOC_QT_ROOT"), "Path to compatible 32-bit Qt 4.8.5 tools, libraries and DLLs")
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
	switch *toolset {
	case "auto", "v143", "v145", "legacy":
	default:
		return fmt.Errorf("unknown toolset %q", *toolset)
	}
	switch *component {
	case "all", "player", "studio":
	default:
		return fmt.Errorf("unknown component %q", *component)
	}
	if runtime.GOOS != "windows" {
		return errors.New("building Player and Studio requires Windows and the Visual Studio C++ tools")
	}

	var root string
	if !*diagnose {
		var err error
		root, err = findRepo(*repo)
		if err != nil {
			return err
		}
		fmt.Fprintln(stdout, "Checkout:", root)
	}
	installations := visualStudioInstallations(stdout)
	vcTargets, err := findVCTargets(installations, registeredVCTargets(), *toolset, stdout)
	if err != nil {
		return err
	}
	msbuild, err := findMSBuild(*msbuildPath, vcTargets)
	if err != nil {
		return err
	}
	fmt.Fprintln(stdout, "MSBuild:", msbuild)
	fmt.Fprintln(stdout, "Visual C++ targets:", vcTargets.path)
	if vcTargets.toolset != "" {
		fmt.Fprintln(stdout, "Win32 toolset:", vcTargets.toolset)
	} else {
		fmt.Fprintln(stdout, "Win32 toolsets: v110, v110_xp")
	}
	if *diagnose {
		return nil
	}
	var qtDir string
	var studioErr error
	buildComponent := *component
	if buildComponent != "player" {
		qtDir, studioErr = resolveQt(root, *qt, vcTargets.toolset != "")
		if studioErr == nil {
			fmt.Fprintln(stdout, "Studio Qt SDK:", qtDir)
		} else if buildComponent == "studio" {
			return studioErr
		} else {
			fmt.Fprintln(stderr, "Studio prerequisites:", studioErr)
			buildComponent = "player"
		}
	}
	if err := build(root, msbuild, vcTargets, qtDir, buildComponent, stdout, stderr); err != nil {
		return errors.Join(err, studioErr)
	}
	if studioErr != nil {
		return studioErr
	}
	fmt.Fprintln(stdout, "\nBuild complete.")
	return nil
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

func findMSBuild(path string, targets vcTargetSet) (string, error) {
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
	if targets.msbuild != "" {
		return targets.msbuild, nil
	}
	if windows := os.Getenv("SystemRoot"); windows != "" && targets.version == "11.0" {
		legacy := filepath.Join(windows, "Microsoft.NET", "Framework", "v4.0.30319", "MSBuild.exe")
		if isFile(legacy) {
			return legacy, nil
		}
	}
	if found, err := exec.LookPath("MSBuild.exe"); err == nil {
		return filepath.Abs(found)
	}
	return "", errors.New("MSBuild.exe is unavailable; use a Visual Studio Developer Command Prompt or pass -msbuild")
}

func build(root, msbuild string, vcTargets vcTargetSet, qtDir, component string, stdout, stderr io.Writer) error {
	contrib := filepath.Join(root, "Contribs")
	for _, step := range stepsFor(component, vcTargets.toolset != "") {
		fmt.Fprintf(stdout, "\nBuilding %s (%s|Win32)\n", step.name, step.configuration)
		args := []string{solution, "/nologo", "/m:1", "/nodeReuse:false",
			"/p:Configuration=" + step.configuration, "/p:Platform=Win32", "/t:" + step.targets,
			"/p:VCTargetsPath=" + vcTargets.path + string(filepath.Separator)}
		if vcTargets.toolset != "" {
			args = append(args, "/p:PlatformToolset="+vcTargets.toolset,
				"/p:WindowsTargetPlatformVersion=10.0", "/p:ZblocModernWindows=true",
				"/p:ForceImportBeforeCppTargets="+filepath.Join(root, "tools", "testex", "ModernCpp.targets"))
		}
		if qtDir != "" {
			args = append(args, "/p:ZblocQtDir="+qtDir)
		}
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
