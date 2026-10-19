package main

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestRoutes(t *testing.T) {
	cases := []struct {
		path     string
		wantCode int
		wantBody string
	}{
		{path: "/", wantCode: http.StatusOK, wantBody: "hello from shop"},
		{path: "/healthz", wantCode: http.StatusOK, wantBody: "ok"},
		// Only the exact root path greets; anything else is not found.
		{path: "/unknown", wantCode: http.StatusNotFound, wantBody: ""},
	}
	mux := newMux()
	for _, tc := range cases {
		rec := httptest.NewRecorder()
		mux.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, tc.path, nil))
		if rec.Code != tc.wantCode {
			t.Errorf("%s: status %d, want %d", tc.path, rec.Code, tc.wantCode)
		}
		if !strings.Contains(rec.Body.String(), tc.wantBody) {
			t.Errorf("%s: body %q does not contain %q", tc.path, rec.Body.String(), tc.wantBody)
		}
	}
}
