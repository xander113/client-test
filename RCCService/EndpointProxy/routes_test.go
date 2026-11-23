package main

import (
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func configJSON(t *testing.T, routes ...routeConfig) []byte {
	t.Helper()
	data, err := json.Marshal(map[string][]routeConfig{"routes": routes})
	if err != nil {
		t.Fatal(err)
	}
	return data
}

func request(handler http.Handler, host, method, target string, body io.Reader) *httptest.ResponseRecorder {
	r := httptest.NewRequest(method, target, body)
	r.Host = host
	w := httptest.NewRecorder()
	handler.ServeHTTP(w, r)
	return w
}

func TestProxyPreservesRequestAndResponse(t *testing.T) {
	type receivedRequest struct {
		method, target, body string
		headers              http.Header
	}
	received := make(chan receivedRequest, 1)
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		body, err := io.ReadAll(r.Body)
		if err != nil {
			http.Error(w, "could not read request", http.StatusBadRequest)
			return
		}
		received <- receivedRequest{r.Method, r.RequestURI, string(body), r.Header.Clone()}
		w.Header().Set("X-Upstream", "website")
		w.WriteHeader(http.StatusCreated)
		_, _ = io.WriteString(w, "created")
	}))
	defer upstream.Close()
	router, err := parseRoutes(configJSON(t, routeConfig{
		From: "https://play.example.invalid/asset/",
		To:   upstream.URL + "/v1/assets/",
	}))
	if err != nil {
		t.Fatal(err)
	}
	r := httptest.NewRequest(http.MethodPost, "/asset/a%20b?item=1&item=2&signature=a%2Bb", strings.NewReader("payload"))
	r.Host = "Play.Example.Invalid"
	r.Header.Set("Content-Type", "application/octet-stream")
	r.Header.Set("X-Forwarded-Host", "spoof.example.invalid")
	w := httptest.NewRecorder()
	router.ServeHTTP(w, r)
	if w.Code != http.StatusCreated || w.Body.String() != "created" || w.Header().Get("X-Upstream") != "website" {
		t.Fatalf("unexpected upstream response: %d %s %v", w.Code, w.Body, w.Header())
	}
	got := <-received
	if got.method != http.MethodPost || got.target != "/v1/assets/a%20b?item=1&item=2&signature=a%2Bb" || got.body != "payload" {
		t.Fatalf("unexpected forwarded request: %+v", got)
	}
	if got.headers.Get("Content-Type") != "application/octet-stream" || got.headers.Get("X-Forwarded-Host") != r.Host ||
		got.headers.Get("X-Forwarded-Proto") != "https" {
		t.Fatalf("unexpected forwarded headers: %v", got.headers)
	}
}

func TestRoutingByHostAndPath(t *testing.T) {
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = io.WriteString(w, r.RequestURI)
	}))
	defer upstream.Close()
	router, err := parseRoutes(configJSON(t,
		routeConfig{From: "https://play.example.invalid/api/", To: upstream.URL + "/website/"},
		routeConfig{From: "https://play.example.invalid/api/auth/", To: upstream.URL + "/accounts/"},
		routeConfig{From: "https://play.example.invalid/api/auth/Login.ashx", To: upstream.URL + "/login"},
		routeConfig{From: "https://assets.example.invalid/api/", To: upstream.URL + "/assets/"},
	))
	if err != nil {
		t.Fatal(err)
	}
	for _, test := range []struct {
		host, target, body string
		status             int
	}{
		{"play.example.invalid", "/api/", "/website/", http.StatusOK},
		{"play.example.invalid", "/api/auth/user", "/accounts/user", http.StatusOK},
		{"play.example.invalid", "/api/auth/Login.ashx?version=2", "/login?version=2", http.StatusOK},
		{"assets.example.invalid", "/api/data", "/assets/data", http.StatusOK},
		{"play.example.invalid", "/apiv2/data", "", http.StatusNotFound},
		{"other.example.invalid", "/api/auth/user", "", http.StatusNotFound},
		{"play.example.invalid", "/api/%2e%2e/anything", "", http.StatusBadRequest},
		{"play.example.invalid", "http://other.example.invalid/api/", "", http.StatusBadRequest},
	} {
		w := request(router, test.host, http.MethodGet, test.target, nil)
		if w.Code != test.status || (test.status == http.StatusOK && w.Body.String() != test.body) {
			t.Errorf("%s %s returned %d %q, want %d %q", test.host, test.target, w.Code, w.Body, test.status, test.body)
		}
	}
}

func TestReloadKeepsEveryRouteOnInvalidEdit(t *testing.T) {
	oldUpstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = io.WriteString(w, "old "+r.RequestURI)
	}))
	defer oldUpstream.Close()
	newUpstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = io.WriteString(w, "new "+r.RequestURI)
	}))
	defer newUpstream.Close()
	config := &routeFile{path: filepath.Join(t.TempDir(), "endpoints.json")}
	writeConfig := func(data []byte) {
		t.Helper()
		if err := os.WriteFile(config.path, data, 0600); err != nil {
			t.Fatal(err)
		}
	}
	checkBody := func(target, want string) {
		t.Helper()
		w := request(config, "play.example.invalid", http.MethodGet, target, nil)
		if w.Code != http.StatusOK || w.Body.String() != want {
			t.Fatalf("%s returned %d %q, want %q", target, w.Code, w.Body, want)
		}
	}
	from := "https://play.example.invalid"
	old := configJSON(t,
		routeConfig{From: from + "/login", To: oldUpstream.URL + "/login"},
		routeConfig{From: from + "/assets/", To: oldUpstream.URL + "/assets/"},
	)
	writeConfig(old)
	if changed, err := config.reload(); err != nil || !changed {
		t.Fatalf("initial routes did not load: %v", err)
	}
	checkBody("/login", "old /login")
	writeConfig(configJSON(t,
		routeConfig{From: from + "/login", To: newUpstream.URL + "/auth"},
		routeConfig{From: from + "/assets/", To: newUpstream.URL + "/missing-trailing-slash"},
	))
	if changed, err := config.reload(); err == nil || changed {
		t.Fatalf("invalid routes were not rejected: changed=%v err=%v", changed, err)
	}
	checkBody("/login", "old /login")
	checkBody("/assets/model", "old /assets/model")
	writeConfig(configJSON(t, routeConfig{From: from + "/login", To: newUpstream.URL + "/auth"}))
	if changed, err := config.reload(); err != nil || !changed {
		t.Fatalf("valid replacement did not load: %v", err)
	}
	checkBody("/login?ticket=a%2Bb", "new /auth?ticket=a%2Bb")
	writeConfig(old)
	if changed, err := config.reload(); err != nil || !changed {
		t.Fatalf("original routes did not reload: %v", err)
	}
	checkBody("/login", "old /login")
}

func TestRejectsInvalidEndpointConfig(t *testing.T) {
	for _, value := range []string{
		`{"routes":[]}`,
		`{"routes":[{"from":"https://play.example.invalid/path","to":"http://127.0.0.1/path?value=1"}]}`,
		`{"routes":[{"from":"https://play.example.invalid/path","to":"https://user:password@backend.example.invalid/path"}]}`,
		`{"routes":[{"from":"https://play.example.invalid/path","to":"file:///tmp/endpoint"}]}`,
		`{"routes":[{"from":"https://play.example.invalid/path","to":"http://127.0.0.1:70000/path"}]}`,
		`{"routes":[{"from":"https://play.example.invalid/path","to":"http://backend:8080:9000/path"}]}`,
		`{"routes":[{"from":"https://play.example.invalid/path","to":"http://127.0.0.1/path/../elsewhere"}]}`,
		`{"routes":[{"from":"https://play.example.invalid/api/","to":"https://play.example.invalid/api/new/"}]}`,
		`{"routes":[{"from":"https://play.example.invalid/path","to":"http://127.0.0.1/path","enabled":true}]}`,
		`{"routes":[]}{}`,
	} {
		if _, err := parseRoutes([]byte(value)); err == nil {
			t.Errorf("accepted invalid configuration %s", value)
		}
	}
	duplicates := configJSON(t,
		routeConfig{From: "https://play.example.invalid/path", To: "http://127.0.0.1/one"},
		routeConfig{From: "https://PLAY.example.invalid/path", To: "http://127.0.0.1/two"},
	)
	if _, err := parseRoutes(duplicates); err == nil {
		t.Fatal("accepted duplicate public host and path")
	}
}
