package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/http/httputil"
	"net/netip"
	"net/url"
	"path"
	"sort"
	"strconv"
	"strings"
)

type routeConfig struct {
	From string `json:"from"`
	To   string `json:"to"`
}

type endpointRoute struct {
	path   string
	prefix bool
	proxy  *httputil.ReverseProxy
}

type router struct {
	byHost map[string][]endpointRoute
}

func parseRoutes(data []byte) (*router, error) {
	var config struct {
		Routes []routeConfig `json:"routes"`
	}
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&config); err != nil {
		return nil, fmt.Errorf("invalid endpoint config: %w", err)
	}
	if err := decoder.Decode(new(json.RawMessage)); err != io.EOF {
		return nil, errors.New("endpoint config must contain one JSON object")
	}
	if len(config.Routes) == 0 {
		return nil, errors.New("endpoint config must contain at least one route")
	}
	routes := &router{byHost: make(map[string][]endpointRoute)}
	seen := make(map[string]bool)
	for i, route := range config.Routes {
		from, err := parseEndpoint(route.From)
		if err != nil {
			return nil, fmt.Errorf("route %d from: %w", i+1, err)
		}
		to, err := parseEndpoint(route.To)
		if err != nil {
			return nil, fmt.Errorf("route %d to: %w", i+1, err)
		}
		host := strings.ToLower(from.Host)
		fromPath := from.EscapedPath()
		toPath := to.EscapedPath()
		prefix := strings.HasSuffix(fromPath, "/")
		if prefix && !strings.HasSuffix(toPath, "/") {
			return nil, fmt.Errorf("route %d: a directory route requires a trailing slash on both URLs", i+1)
		}
		if strings.EqualFold(from.Host, to.Host) && (fromPath == toPath || (prefix && strings.HasPrefix(toPath, fromPath))) {
			return nil, fmt.Errorf("route %d: destination points back to the public route", i+1)
		}
		key := host + fromPath
		if seen[key] {
			return nil, fmt.Errorf("route %d: duplicate public host and path", i+1)
		}
		seen[key] = true
		routes.byHost[host] = append(routes.byHost[host], endpointRoute{
			path:   fromPath,
			prefix: prefix,
			proxy:  newProxy(from, to, prefix),
		})
	}
	for _, entries := range routes.byHost {
		sort.Slice(entries, func(i, j int) bool { return len(entries[i].path) > len(entries[j].path) })
	}
	return routes, nil
}

func parseEndpoint(raw string) (*url.URL, error) {
	parsed, err := url.Parse(raw)
	if err != nil || strings.ContainsAny(raw, "\\# \t\r\n") ||
		(parsed.Scheme != "http" && parsed.Scheme != "https") || parsed.Hostname() == "" ||
		parsed.User != nil || parsed.RawQuery != "" || parsed.ForceQuery || parsed.RawPath != "" {
		return nil, errors.New("expected an absolute HTTP(S) URL with a host and a literal path")
	}
	if parsed.Path == "" {
		parsed.Path = "/"
	}
	if port := parsed.Port(); port != "" {
		number, err := strconv.ParseUint(port, 10, 16)
		if err != nil || number == 0 {
			return nil, errors.New("invalid port")
		}
	}
	if strings.HasSuffix(parsed.Host, ":") || !cleanPath(parsed.Path) {
		return nil, errors.New("invalid host or path")
	}
	if strings.ContainsAny(parsed.Host, "[]") || strings.Contains(parsed.Hostname(), ":") {
		address, err := netip.ParseAddr(parsed.Hostname())
		if err != nil || !address.Is6() || !strings.HasPrefix(parsed.Host, "[") {
			return nil, errors.New("invalid IPv6 host")
		}
	}
	return parsed, nil
}

func cleanPath(value string) bool {
	if !strings.HasPrefix(value, "/") || strings.ContainsAny(value, "\\\x00\r\n") {
		return false
	}
	clean := path.Clean(value)
	return value == clean || (clean != "/" && value == clean+"/")
}

func newProxy(from, to *url.URL, prefix bool) *httputil.ReverseProxy {
	fromPath, toPath := from.EscapedPath(), to.EscapedPath()
	return &httputil.ReverseProxy{
		Rewrite: func(request *httputil.ProxyRequest) {
			request.SetURL(to)
			request.Out.URL.Path = to.Path
			request.Out.URL.RawPath = toPath
			if prefix {
				request.Out.URL.Path += strings.TrimPrefix(request.In.URL.Path, from.Path)
				request.Out.URL.RawPath += strings.TrimPrefix(request.In.URL.EscapedPath(), fromPath)
			}
			request.Out.URL.RawQuery = request.In.URL.RawQuery
			request.Out.URL.ForceQuery = request.In.URL.ForceQuery
			request.SetXForwarded()
			request.Out.Header.Set("X-Forwarded-Proto", from.Scheme)
		},
	}
}

func (routes *router) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	if r.Method == http.MethodConnect || r.URL.IsAbs() || !cleanPath(r.URL.Path) {
		http.Error(w, "Invalid request target", http.StatusBadRequest)
		return
	}
	escaped := r.URL.EscapedPath()
	for _, route := range routes.byHost[strings.ToLower(r.Host)] {
		if escaped == route.path || (route.prefix && strings.HasPrefix(escaped, route.path)) {
			route.proxy.ServeHTTP(w, r)
			return
		}
	}
	http.NotFound(w, r)
}
