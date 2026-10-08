package main

import (
	"net/http"
	"testing"
)

func TestSecurityHeaders_PresentOnAllRoutes(t *testing.T) {
	srv := newTestServer(t)
	want := map[string]string{
		"X-Content-Type-Options":       "nosniff",
		"Cache-Control":                "no-store",
		"Cross-Origin-Resource-Policy": "same-origin",
		"Content-Security-Policy":      "default-src 'none'; frame-ancestors 'none'",
	}
	for _, target := range []string{"/health", "/notes", "/does-not-exist"} {
		rec := do(t, srv, http.MethodGet, target, nil)
		for k, v := range want {
			if got := rec.Header().Get(k); got != v {
				t.Errorf("%s: header %s = %q, want %q", target, k, got, v)
			}
		}
	}
}
