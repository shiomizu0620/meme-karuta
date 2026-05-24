package main

import (
	"bytes"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

func TestRateLimiterAllowsBurstThenBlocks(t *testing.T) {
	rl := newRateLimiter(1, 3)
	for i := 0; i < 3; i++ {
		if !rl.Allow("1.2.3.4") {
			t.Fatalf("burst token %d should be allowed", i)
		}
	}
	if rl.Allow("1.2.3.4") {
		t.Fatal("4th immediate request should be blocked")
	}
	if !rl.Allow("9.9.9.9") {
		t.Fatal("different key should have its own bucket")
	}
}

func TestCircuitBreakerOpensAfterThreshold(t *testing.T) {
	cb := newCircuitBreaker(3, 50*time.Millisecond)
	for i := 0; i < 3; i++ {
		cb.RecordFailure("svc")
	}
	if cb.Allow("svc") {
		t.Fatal("breaker should be open after reaching threshold")
	}
	time.Sleep(60 * time.Millisecond)
	if !cb.Allow("svc") {
		t.Fatal("breaker should allow half-open probe after timeout")
	}
}

func TestJSONValidatorRejectsInvalidJSON(t *testing.T) {
	called := false
	h := jsonValidator(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { called = true }))
	body := strings.NewReader("not json")
	r := httptest.NewRequest(http.MethodPost, "/api/anything", body)
	r.Header.Set("Content-Type", "application/json")
	r.ContentLength = int64(body.Len())
	w := httptest.NewRecorder()
	h.ServeHTTP(w, r)
	if w.Code != http.StatusBadRequest {
		t.Fatalf("expected 400, got %d", w.Code)
	}
	if called {
		t.Fatal("downstream should not be called for invalid JSON")
	}
	var apiErr APIError
	if err := json.Unmarshal(w.Body.Bytes(), &apiErr); err != nil {
		t.Fatalf("response is not APIError JSON: %v", err)
	}
	if apiErr.Code != "INVALID_BODY" {
		t.Fatalf("expected code INVALID_BODY got %q", apiErr.Code)
	}
}

func TestJSONValidatorPassesValidJSON(t *testing.T) {
	var seen []byte
	h := jsonValidator(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		seen, _ = io.ReadAll(r.Body)
	}))
	body := []byte(`{"hello":"world"}`)
	r := httptest.NewRequest(http.MethodPost, "/api/x", bytes.NewReader(body))
	r.Header.Set("Content-Type", "application/json")
	r.ContentLength = int64(len(body))
	h.ServeHTTP(httptest.NewRecorder(), r)
	if !bytes.Equal(seen, body) {
		t.Fatalf("downstream did not receive body intact: got %q", seen)
	}
}

func TestBodyLimitRejectsLarge(t *testing.T) {
	h := bodyLimitMiddleware(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {}))
	r := httptest.NewRequest(http.MethodPost, "/", strings.NewReader(""))
	r.ContentLength = maxBodyBytes + 1
	w := httptest.NewRecorder()
	h.ServeHTTP(w, r)
	if w.Code != http.StatusRequestEntityTooLarge {
		t.Fatalf("expected 413, got %d", w.Code)
	}
}

func TestETagReturns304OnMatch(t *testing.T) {
	inner := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = w.Write([]byte(`{"hello":"world"}`))
	})
	h := etagMiddleware(inner)

	r1 := httptest.NewRequest(http.MethodGet, "/api/x", nil)
	w1 := httptest.NewRecorder()
	h.ServeHTTP(w1, r1)
	etag := w1.Header().Get("ETag")
	if etag == "" {
		t.Fatal("ETag header missing on first response")
	}

	r2 := httptest.NewRequest(http.MethodGet, "/api/x", nil)
	r2.Header.Set("If-None-Match", etag)
	w2 := httptest.NewRecorder()
	h.ServeHTTP(w2, r2)
	if w2.Code != http.StatusNotModified {
		t.Fatalf("expected 304 on matching ETag, got %d", w2.Code)
	}
	if w2.Body.Len() != 0 {
		t.Fatal("304 response must have empty body")
	}
}

func TestNormalizeRoute(t *testing.T) {
	cases := map[string]string{
		"/api/cards":          "/api/cards",
		"/api/cards/list":     "/api/cards",
		"/api/judge/room/123": "/api/judge",
		"/health":             "/health",
		"/metrics":            "/metrics",
	}
	for in, want := range cases {
		if got := normalizeRoute(in); got != want {
			t.Errorf("normalizeRoute(%q)=%q want %q", in, got, want)
		}
	}
}

func TestMetricsRenderIncludesCounters(t *testing.T) {
	m := newMetrics()
	m.Record("GET", "/api/cards", 200, 12.5)
	m.Record("GET", "/api/cards", 500, 250.0)
	m.SetUpstream("card-gen", true)
	var buf bytes.Buffer
	m.Render(&buf)
	out := buf.String()
	for _, want := range []string{
		"gateway_requests_total",
		"gateway_responses_total",
		"gateway_latency_ms_bucket",
		"gateway_upstream_up",
		"gateway_errors_total 1",
	} {
		if !strings.Contains(out, want) {
			t.Errorf("metrics output missing %q\n%s", want, out)
		}
	}
}

func TestWriteErrorIncludesRequestID(t *testing.T) {
	r := httptest.NewRequest(http.MethodGet, "/", nil)
	r = r.WithContext(contextWithRequestID(r.Context(), "abc-123"))
	w := httptest.NewRecorder()
	writeError(w, r, http.StatusBadGateway, "UPSTREAM_ERROR", "down")
	var apiErr APIError
	if err := json.Unmarshal(w.Body.Bytes(), &apiErr); err != nil {
		t.Fatalf("invalid JSON response: %v", err)
	}
	if apiErr.RequestID != "abc-123" {
		t.Fatalf("request_id not propagated, got %q", apiErr.RequestID)
	}
	if apiErr.Code != "UPSTREAM_ERROR" {
		t.Fatalf("unexpected code %q", apiErr.Code)
	}
}
