package main

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

func TestRateLimiterAllowsWithinCapacity(t *testing.T) {
	rl := NewRateLimiter(5, 1)
	defer rl.Stop()

	for i := 0; i < 5; i++ {
		if !rl.Allow("1.2.3.4") {
			t.Fatalf("expected to allow request %d within capacity", i+1)
		}
	}
}

func TestRateLimiterBlocksWhenExhausted(t *testing.T) {
	rl := NewRateLimiter(2, 0.01)
	defer rl.Stop()

	if !rl.Allow("1.2.3.4") {
		t.Fatal("first request should be allowed")
	}
	if !rl.Allow("1.2.3.4") {
		t.Fatal("second request should be allowed")
	}
	if rl.Allow("1.2.3.4") {
		t.Fatal("third request should be blocked")
	}
}

func TestRateLimiterIsolatesByKey(t *testing.T) {
	rl := NewRateLimiter(1, 0.01)
	defer rl.Stop()

	if !rl.Allow("a") {
		t.Fatal("a should be allowed")
	}
	if rl.Allow("a") {
		t.Fatal("a second request should be blocked")
	}
	if !rl.Allow("b") {
		t.Fatal("b should be allowed independently")
	}
}

func TestRateLimiterRefillsOverTime(t *testing.T) {
	rl := NewRateLimiter(1, 100)
	defer rl.Stop()

	if !rl.Allow("k") {
		t.Fatal("first allow")
	}
	if rl.Allow("k") {
		t.Fatal("second immediate should fail")
	}
	time.Sleep(20 * time.Millisecond)
	if !rl.Allow("k") {
		t.Fatal("should refill after sleep")
	}
}

func TestMiddlewareReturns429WhenLimited(t *testing.T) {
	rl := NewRateLimiter(1, 0.01)
	defer rl.Stop()

	handler := rl.Middleware(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
	}))

	req := httptest.NewRequest("GET", "/api/test", nil)
	req.RemoteAddr = "10.0.0.1:1234"

	w1 := httptest.NewRecorder()
	handler.ServeHTTP(w1, req)
	if w1.Code != http.StatusOK {
		t.Fatalf("expected 200 on first request, got %d", w1.Code)
	}

	w2 := httptest.NewRecorder()
	handler.ServeHTTP(w2, req)
	if w2.Code != http.StatusTooManyRequests {
		t.Fatalf("expected 429 on second, got %d", w2.Code)
	}
	if w2.Header().Get("Retry-After") == "" {
		t.Error("expected Retry-After header")
	}
	var body map[string]string
	if err := json.Unmarshal(w2.Body.Bytes(), &body); err != nil {
		t.Fatalf("decode body: %v", err)
	}
	if body["code"] != "rate_limited" {
		t.Errorf("expected code=rate_limited, got %s", body["code"])
	}
}

func TestTrustedProxyHonorsXForwardedFor(t *testing.T) {
	rl := NewRateLimiter(1, 0.01)
	defer rl.Stop()
	rl.TrustProxies("127.0.0.1")

	handler := rl.Middleware(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
	}))

	makeReq := func(xff string) *http.Request {
		r := httptest.NewRequest("GET", "/x", nil)
		r.RemoteAddr = "127.0.0.1:9999"
		r.Header.Set("X-Forwarded-For", xff)
		return r
	}

	w1 := httptest.NewRecorder()
	handler.ServeHTTP(w1, makeReq("9.9.9.1"))
	if w1.Code != http.StatusOK {
		t.Fatal("first should pass")
	}
	w2 := httptest.NewRecorder()
	handler.ServeHTTP(w2, makeReq("9.9.9.2"))
	if w2.Code != http.StatusOK {
		t.Fatal("different forwarded IP should pass")
	}
}

func TestUntrustedProxyIgnoresXForwardedFor(t *testing.T) {
	rl := NewRateLimiter(1, 0.01)
	defer rl.Stop()

	if !rl.Allow("9.9.9.9") {
		t.Fatal("setup: real IP should pass once")
	}

	r := httptest.NewRequest("GET", "/x", nil)
	r.RemoteAddr = "10.10.10.10:1234"
	r.Header.Set("X-Forwarded-For", "9.9.9.9")
	key := rl.clientKey(r)
	if strings.HasPrefix(key, "9.") {
		t.Errorf("untrusted proxy should not honor XFF, got key=%s", key)
	}
}
