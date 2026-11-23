package main

import (
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestProbeRCC(t *testing.T) {
	for _, test := range []struct {
		name, payload, failure string
		status                 int
	}{
		{
			name:    "success",
			status:  http.StatusOK,
			payload: `<GetVersionResponse xmlns="http://roblox.com/"><GetVersionResult>0.75.0.691</GetVersionResult></GetVersionResponse>`,
		},
		{
			name:    "wrong operation",
			status:  http.StatusOK,
			payload: `<GetStatusResponse/>`,
			failure: "missing GetVersionResult",
		},
		{
			name:    "malformed XML",
			status:  http.StatusOK,
			payload: `<GetVersionResponse>`,
			failure: "invalid RCCService SOAP response",
		},
		{
			name:    "service unavailable",
			status:  http.StatusServiceUnavailable,
			failure: "503",
		},
	} {
		t.Run(test.name, func(t *testing.T) {
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				if r.URL.Path != "/rcc" || r.Method != "POST" || r.Header.Get("SOAPAction") != `"http://roblox.com/GetVersion"` {
					t.Errorf("unexpected request method, path or SOAPAction")
				}
				body, err := io.ReadAll(r.Body)
				if err != nil || !strings.Contains(string(body), `<GetVersion xmlns="http://roblox.com/"/>`) {
					t.Errorf("invalid GetVersion request: %s (%v)", body, err)
				}
				w.WriteHeader(test.status)
				fmt.Fprintf(w, `<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"><s:Body>%s</s:Body></s:Envelope>`, test.payload)
			}))
			defer server.Close()
			version, err := probeRCC(server.URL + "/rcc")
			if test.failure != "" {
				if err == nil || !strings.Contains(err.Error(), test.failure) {
					t.Fatalf("expected %q, got %v", test.failure, err)
				}
			} else if err != nil || version != "0.75.0.691" {
				t.Fatalf("expected version 0.75.0.691, got %q (%v)", version, err)
			}
		})
	}
}
