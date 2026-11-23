package main

import (
	"encoding/xml"
	"errors"
	"flag"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"time"
)

const (
	clientProject    = "MacClient.xcodeproj"
	studioProject    = "RobloxStudio/RobloxStudio.xcodeproj"
	converterProject = "CoreScriptConverter2/CoreScriptConverter.xcodeproj"
)

var requiredContribs = []string{
	"boost_1_55_0/include/boost/version.hpp",
	"google-breakpad/19OCT2015/src/client/mac/Breakpad.xcodeproj/project.pbxproj",
	"google-breakpad/19OCT2015/src/client/mac/build/Release/Breakpad.framework",
	"TBB/tbb_mac_30_056/lib/libtbb.dylib",
	"TBB/tbb_mac_30_056/lib/libtbbmalloc.dylib",
	"SDL2.0.4/Xcode/SDL/SDL2.framework",
	"darwin/x86/curl/curl-7.43.0/lib/libcurl.a",
	"darwin/x86/openssl/openssl-1.0.2c/lib/libcrypto.a",
	"darwin/x86/openssl/openssl-1.0.2c/lib/libssl.a",
	"Qt/4.8.5/mac/Applications/plugins/imageformats",
	"Qt/4.8.5/mac/Frameworks/QtCore.framework",
	"Qt/4.8.5/mac/Frameworks/QtGui.framework",
	"Qt/4.8.5/mac/Frameworks/QtNetwork.framework",
	"Qt/4.8.5/mac/Frameworks/QtWebKit.framework",
	"Qt/4.8.5/mac/Frameworks/QtXml.framework",
	"Qt/4.8.5/mac/Frameworks/phonon.framework",
}

var nativeTests = []string{"Base.UnitTest", "App.UnitTest", "RobloxTest"}

type workspace struct {
	root     string
	contrib  string
	buildDir string
	stdout   io.Writer
	stderr   io.Writer
}

func main() {
	if err := run(os.Args[1:], os.Stdout, os.Stderr); err != nil && !errors.Is(err, flag.ErrHelp) {
		fmt.Fprintln(os.Stderr, "TEXTEXMAC:", err)
		os.Exit(1)
	}
}

func run(args []string, stdout, stderr io.Writer) error {
	flags := flag.NewFlagSet("TEXTEXMAC", flag.ContinueOnError)
	flags.SetOutput(stderr)
	mode := flags.String("mode", "build", "build, test, check, or rcc")
	repo := flags.String("repo", "", "Path to the source checkout (defaults to beside the executable or current directory)")
	contrib := flags.String("contrib", os.Getenv("CONTRIB_PATH"), "Directory with legacy Mac dependencies (defaults to the checkout's Contribs)")
	endpoint := flags.String("rcc-url", "", "Full URL of a running RCCService SOAP endpoint for -mode rcc")
	if err := flags.Parse(args); err != nil {
		return err
	}
	if flags.NArg() != 0 {
		return fmt.Errorf("unexpected arguments: %s", strings.Join(flags.Args(), " "))
	}
	switch *mode {
	case "rcc":
		version, err := probeRCC(*endpoint)
		if err != nil {
			return err
		}
		fmt.Fprintln(stdout, "RCCService GetVersion passed:", version)
		return nil
	case "build", "test", "check":
		if *endpoint != "" {
			return errors.New("use -mode rcc with -rcc-url")
		}
	default:
		return fmt.Errorf("unknown mode %q", *mode)
	}

	root, err := findRepo(*repo)
	if err != nil {
		return err
	}
	if *contrib == "" {
		*contrib = filepath.Join(root, "Contribs")
	}
	absoluteContrib, err := filepath.Abs(*contrib)
	if err != nil {
		return err
	}
	work := workspace{
		root: root, contrib: absoluteContrib,
		buildDir: filepath.Join(root, "build", "zbloc-mac"),
		stdout:   stdout, stderr: stderr,
	}
	if err := work.check(*mode != "build"); err != nil {
		return err
	}
	if *mode == "check" {
		fmt.Fprintln(stdout, "Native build and test prerequisites found. Run -mode build or -mode test to verify them.")
		return nil
	}
	if err := work.buildApps(); err != nil {
		return err
	}
	if *mode == "test" {
		return work.testApps()
	}
	return nil
}

func findRepo(path string) (string, error) {
	if path == "" {
		executable, err := os.Executable()
		if err != nil {
			return "", err
		}
		path = filepath.Dir(executable)
		if _, err := os.Stat(filepath.Join(path, clientProject, "project.pbxproj")); err != nil {
			path = "."
		}
	}
	path, err := filepath.Abs(path)
	if err != nil {
		return "", err
	}
	if _, err := os.Stat(filepath.Join(path, clientProject, "project.pbxproj")); err != nil {
		return "", fmt.Errorf("cannot find %s in %q; pass -repo with the checkout path", clientProject, path)
	}
	return path, nil
}

func (w workspace) check(includeTests bool) error {
	var problems []error
	if runtime.GOOS != "darwin" || runtime.GOARCH != "amd64" {
		problems = append(problems, errors.New("native build and execution require an Intel Mac running macOS 10.13 or 10.14 with legacy Xcode"))
	} else {
		version, err := exec.Command("/usr/bin/sw_vers", "-productVersion").Output()
		if err != nil {
			problems = append(problems, fmt.Errorf("read macOS version: %w", err))
		} else if parts := strings.Split(strings.TrimSpace(string(version)), "."); len(parts) < 2 || parts[0] != "10" || (parts[1] != "13" && parts[1] != "14") {
			problems = append(problems, fmt.Errorf("macOS %s cannot run this legacy i386 workflow; use Intel macOS 10.13 or 10.14", strings.TrimSpace(string(version))))
		} else {
			if _, err := exec.Command("/usr/bin/xcrun", "--sdk", "macosx", "--show-sdk-path").Output(); err != nil {
				problems = append(problems, fmt.Errorf("cannot resolve a macOS SDK; select legacy Xcode with DEVELOPER_DIR: %w", err))
			}
			for _, tool := range []string{"make", "flex", "bison"} {
				if _, err := exec.LookPath(tool); err != nil {
					problems = append(problems, fmt.Errorf("missing shader compiler prerequisite: %s", tool))
				}
			}
		}
	}
	for _, path := range requiredContribs {
		if _, err := os.Stat(filepath.Join(w.contrib, path)); err != nil {
			problems = append(problems, fmt.Errorf("Mac dependency %s: %w", path, err))
		}
	}
	if includeTests {
		for _, source := range []string{"Base.UnitTest/Base.UnitTest.cpp", "App.UnitTest/App.UnitTest.cpp", "RobloxTest/main.cpp", "RobloxTest/Tests.cpp"} {
			if _, err := os.Stat(filepath.Join(w.root, source)); err != nil {
				problems = append(problems, fmt.Errorf("native test source %s: %w", source, err))
			}
		}
	}
	return errors.Join(problems...)
}

func (w workspace) command(directory, name string, args ...string) *exec.Cmd {
	command := exec.Command(name, args...)
	command.Dir = directory
	command.Env = append(os.Environ(), "CONTRIB_PATH="+w.contrib)
	command.Stdout = w.stdout
	command.Stderr = w.stderr
	return command
}

func (w workspace) product(name string) string {
	return filepath.Join(w.buildDir, "products", "Release", name)
}

func (w workspace) xcode(project, target, converter string) error {
	fmt.Fprintln(w.stdout, "Building", target)
	args := []string{
		"xcodebuild", "-project", project, "-target", target, "-configuration", "Release",
		"SYMROOT=" + filepath.Join(w.buildDir, "products"), "OBJROOT=" + filepath.Join(w.buildDir, "objects"),
		"CONTRIB_PATH=" + w.contrib, "CODE_SIGNING_ALLOWED=NO", "ARCHS=i386", "ONLY_ACTIVE_ARCH=NO",
	}
	if converter != "" {
		args = append(args, "ZBLOC_CORESCRIPT_CONVERTER="+converter)
	}
	if err := w.command(w.root, "/usr/bin/xcrun", append(args, "build")...).Run(); err != nil {
		return fmt.Errorf("build %s: %w", target, err)
	}
	return nil
}

func (w workspace) buildApps() error {
	fmt.Fprintln(w.stdout, "Building ShaderCompiler")
	shaderDir := filepath.Join(w.root, "Rendering", "ShaderCompiler")
	if err := w.command(shaderDir, "make").Run(); err != nil {
		return fmt.Errorf("build ShaderCompiler: %w", err)
	}
	if err := w.xcode(converterProject, "CoreScriptConverter", ""); err != nil {
		return err
	}
	converter := w.product("CoreScriptConverter")
	generate := w.command(w.root, "/bin/bash", "CoreScriptConverter2/tool/osx/ConverterScript.sh", converter)
	if err := generate.Run(); err != nil {
		return fmt.Errorf("generate CoreScripts: %w", err)
	}
	if err := w.xcode(clientProject, "RobloxPlayer", converter); err != nil {
		return err
	}
	if err := w.xcode(studioProject, "RobloxStudio", ""); err != nil {
		return err
	}
	for _, name := range []string{"RobloxPlayer", "RobloxStudio"} {
		bundle := w.product(name + ".app")
		if err := executableFile(filepath.Join(bundle, "Contents", "MacOS", name)); err != nil {
			return err
		}
		fmt.Fprintln(w.stdout, bundle)
	}
	return nil
}

func (w workspace) testApps() error {
	for _, target := range nativeTests {
		if err := w.xcode(clientProject, target, ""); err != nil {
			return err
		}
		executable := w.product(target)
		if err := executableFile(executable); err != nil {
			return err
		}
		fmt.Fprintln(w.stdout, "Running", target)
		if err := w.command(filepath.Dir(executable), executable).Run(); err != nil {
			return fmt.Errorf("run %s: %w", target, err)
		}
	}
	return nil
}

func executableFile(path string) error {
	info, err := os.Stat(path)
	if err != nil {
		return err
	}
	if !info.Mode().IsRegular() || info.Mode().Perm()&0111 == 0 || info.Size() == 0 {
		return fmt.Errorf("expected an executable at %q", path)
	}
	return nil
}

func probeRCC(endpoint string) (string, error) {
	address, err := url.Parse(endpoint)
	if err != nil || address.Host == "" || address.User != nil || address.Fragment != "" || (address.Scheme != "http" && address.Scheme != "https") {
		return "", errors.New("pass a valid HTTP or HTTPS SOAP endpoint with -rcc-url")
	}
	const envelope = `<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"><s:Body><GetVersion xmlns="http://roblox.com/"/></s:Body></s:Envelope>`
	request, err := http.NewRequest("POST", address.String(), strings.NewReader(envelope))
	if err != nil {
		return "", err
	}
	request.Header.Set("Content-Type", "text/xml; charset=utf-8")
	request.Header.Set("SOAPAction", `"http://roblox.com/GetVersion"`)
	client := http.Client{
		Timeout:       10 * time.Second,
		CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse },
	}
	response, err := client.Do(request)
	if err != nil {
		return "", fmt.Errorf("RCCService request failed: %w", err)
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		return "", fmt.Errorf("RCCService returned HTTP %s", response.Status)
	}
	const maxResponse = 1 << 20
	body, err := io.ReadAll(io.LimitReader(response.Body, maxResponse+1))
	if err != nil {
		return "", err
	}
	if len(body) > maxResponse {
		return "", errors.New("RCCService response exceeds " + strconv.Itoa(maxResponse) + " bytes")
	}
	var result struct {
		XMLName xml.Name `xml:"http://schemas.xmlsoap.org/soap/envelope/ Envelope"`
		Version string   `xml:"Body>GetVersionResponse>GetVersionResult"`
	}
	if err := xml.Unmarshal(body, &result); err != nil {
		return "", fmt.Errorf("invalid RCCService SOAP response: %w", err)
	}
	version := strings.TrimSpace(result.Version)
	if version == "" {
		return "", errors.New("RCCService returned an empty or missing GetVersionResult")
	}
	return version, nil
}
