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
