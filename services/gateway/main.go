package main

import (
	"context"
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"net/http/httputil"
	"net/url"
	"os"
	"os/signal"
	"strings"
	"sync"
	"syscall"
	"time"
)

// ---- エラーレスポンス ----

type APIError struct {
	Code      string `json:"code"`
	Message   string `json:"message"`
	RequestID string `json:"request_id,omitempty"`
}

func writeError(w http.ResponseWriter, r *http.Request, status int, code, msg string) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	json.NewEncoder(w).Encode(APIError{code, msg, requestIDFromContext(r.Context())})
}

// ---- 設定 ----

type Config struct {
	ListenAddr    string
	CardGenURL    string
	ShuffleURL    string
	JudgeURL      string
	QueueURL      string
	SerializerURL string
	PokedexURL    string
	RateLimit     int
	RateBurst     int
	ReadTimeout   time.Duration
	WriteTimeout  time.Duration
	IdleTimeout   time.Duration
	CBThreshold   int
	CBOpenTimeout time.Duration
}

func loadConfig() Config {
	return Config{
		ListenAddr:    getEnv("LISTEN_ADDR", ":8080"),
		CardGenURL:    getEnv("CARD_GEN_URL", "http://card-gen:5000"),
		ShuffleURL:    getEnv("SHUFFLE_URL", "http://shuffle:5001"),
		JudgeURL:      getEnv("JUDGE_URL", "http://judge:5002"),
		QueueURL:      getEnv("QUEUE_URL", "http://queue:5003"),
		SerializerURL: getEnv("SERIALIZER_URL", "http://serializer:5004"),
		PokedexURL:    getEnv("POKEDEX_URL", "http://pokedex:5005"),
		RateLimit:     getEnvInt("RATE_LIMIT", 100),
		RateBurst:     getEnvInt("RATE_BURST", 20),
		ReadTimeout:   getEnvDuration("READ_TIMEOUT", 15*time.Second),
		WriteTimeout:  getEnvDuration("WRITE_TIMEOUT", 30*time.Second),
		IdleTimeout:   getEnvDuration("IDLE_TIMEOUT", 60*time.Second),
		CBThreshold:   getEnvInt("CB_THRESHOLD", 5),
		CBOpenTimeout: getEnvDuration("CB_OPEN_TIMEOUT", 30*time.Second),
	}
}

func getEnv(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}

func getEnvInt(key string, fallback int) int {
	v := os.Getenv(key)
	if v == "" {
		return fallback
	}
	var n int
	if _, err := fmt.Sscanf(v, "%d", &n); err != nil {
		return fallback
	}
	return n
}

func getEnvDuration(key string, fallback time.Duration) time.Duration {
	v := os.Getenv(key)
	if v == "" {
		return fallback
	}
	d, err := time.ParseDuration(v)
	if err != nil {
		return fallback
	}
	return d
}

// ---- レートリミッター（トークンバケット） ----

type tokenBucket struct {
	tokens   float64
	lastTime time.Time
}

type RateLimiter struct {
	mu      sync.Mutex
	buckets map[string]*tokenBucket
	limit   float64
	burst   float64
}

func newRateLimiter(limit, burst int) *RateLimiter {
	rl := &RateLimiter{
		buckets: make(map[string]*tokenBucket),
		limit:   float64(limit),
		burst:   float64(burst),
	}
	go func() {
		for range time.NewTicker(5 * time.Minute).C {
			rl.mu.Lock()
			cutoff := time.Now().Add(-5 * time.Minute)
			for k, b := range rl.buckets {
				if b.lastTime.Before(cutoff) {
					delete(rl.buckets, k)
				}
			}
			rl.mu.Unlock()
		}
	}()
	return rl
}

func (rl *RateLimiter) Allow(key string) bool {
	rl.mu.Lock()
	defer rl.mu.Unlock()
	now := time.Now()
	b, ok := rl.buckets[key]
	if !ok {
		b = &tokenBucket{tokens: rl.burst, lastTime: now}
		rl.buckets[key] = b
	}
	b.tokens = min(b.tokens+now.Sub(b.lastTime).Seconds()*rl.limit, rl.burst)
	b.lastTime = now
	if b.tokens < 1 {
		return false
	}
	b.tokens--
	return true
}

// ---- ヘルスチェッカー ----

type UpstreamHealth struct {
	Name      string  `json:"name"`
	URL       string  `json:"url"`
	Status    string  `json:"status"`
	LatencyMs float64 `json:"latency_ms"`
}

func checkUpstreams(cfg Config) []UpstreamHealth {
	client := &http.Client{Timeout: 3 * time.Second}
	upstreams := []struct{ name, url string }{
		{"card-gen", cfg.CardGenURL + "/health"},
		{"shuffle", cfg.ShuffleURL + "/health"},
		{"judge", cfg.JudgeURL + "/health"},
		{"queue", cfg.QueueURL + "/health"},
		{"serializer", cfg.SerializerURL + "/health"},
		{"pokedex", cfg.PokedexURL + "/health"},
	}
	results := make([]UpstreamHealth, len(upstreams))
	for i, u := range upstreams {
		start := time.Now()
		resp, err := client.Get(u.url)
		latency := float64(time.Since(start).Nanoseconds()) / 1e6
		if err != nil {
			results[i] = UpstreamHealth{u.name, u.url, "down", latency}
			continue
		}
		resp.Body.Close()
		status := "up"
		if resp.StatusCode >= 500 {
			status = "down"
		} else if resp.StatusCode >= 400 {
			status = "degraded"
		}
		results[i] = UpstreamHealth{u.name, u.url, status, latency}
	}
	return results
}

// ---- サーキットブレーカー ----

type cbEntry struct {
	failures  int
	successes int
	openedAt  time.Time
	isOpen    bool
}

type CircuitBreaker struct {
	mu          sync.Mutex
	entries     map[string]*cbEntry
	threshold   int
	openTimeout time.Duration
	halfOpenMax int
}

func newCircuitBreaker(threshold int, openTimeout time.Duration) *CircuitBreaker {
	return &CircuitBreaker{
		entries:     make(map[string]*cbEntry),
		threshold:   threshold,
		openTimeout: openTimeout,
		halfOpenMax: 3,
	}
}

func (cb *CircuitBreaker) Allow(name string) bool {
	cb.mu.Lock()
	defer cb.mu.Unlock()
	e, ok := cb.entries[name]
	if !ok {
		return true
	}
	if !e.isOpen {
		return true
	}
	if time.Since(e.openedAt) >= cb.openTimeout {
		return e.successes < cb.halfOpenMax
	}
	return false
}

func (cb *CircuitBreaker) RecordSuccess(name string) {
	cb.mu.Lock()
	defer cb.mu.Unlock()
	e, ok := cb.entries[name]
	if !ok {
		return
	}
	if e.isOpen {
		e.successes++
		if e.successes >= cb.halfOpenMax {
			e.isOpen = false
			e.failures = 0
			e.successes = 0
			log.Printf("[CB] closed %s", name)
		}
	} else {
		e.failures = 0
	}
}

func (cb *CircuitBreaker) RecordFailure(name string) {
	cb.mu.Lock()
	defer cb.mu.Unlock()
	e, ok := cb.entries[name]
	if !ok {
		e = &cbEntry{}
		cb.entries[name] = e
	}
	e.failures++
	if !e.isOpen && e.failures >= cb.threshold {
		e.isOpen = true
		e.openedAt = time.Now()
		e.successes = 0
		log.Printf("[CB] opened %s after %d failures", name, e.failures)
	}
}

// ---- リバースプロキシ ----

type upstreamProxy struct {
	name  string
	proxy *httputil.ReverseProxy
	cb    *CircuitBreaker
}

func newUpstreamProxy(name, target string, cb *CircuitBreaker) *upstreamProxy {
	u, err := url.Parse(target)
	if err != nil {
		log.Fatalf("invalid upstream URL %q: %v", target, err)
	}
	up := &upstreamProxy{name: name, cb: cb}
	p := httputil.NewSingleHostReverseProxy(u)
	p.ErrorHandler = func(w http.ResponseWriter, r *http.Request, err error) {
		cb.RecordFailure(name)
		log.Printf("[PROXY ERROR] upstream=%s %s -> %v", name, r.URL.Path, err)
		writeError(w, r, http.StatusBadGateway, "UPSTREAM_ERROR", "upstream unavailable")
	}
	up.proxy = p
	return up
}

func (up *upstreamProxy) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	if !up.cb.Allow(up.name) {
		writeError(w, r, http.StatusServiceUnavailable, "CIRCUIT_OPEN",
			fmt.Sprintf("upstream %s is temporarily unavailable", up.name))
		return
	}
	rw := &statusWriter{ResponseWriter: w, status: http.StatusOK}
	up.proxy.ServeHTTP(rw, r)
	if rw.status >= 500 {
		up.cb.RecordFailure(up.name)
	} else {
		up.cb.RecordSuccess(up.name)
	}
}

func stripPrefix(prefix string, h http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		r2 := r.Clone(r.Context())
		r2.URL.Path = strings.TrimPrefix(r.URL.Path, prefix)
		if r2.URL.Path == "" {
			r2.URL.Path = "/"
		}
		r2.URL.RawPath = strings.TrimPrefix(r.URL.RawPath, prefix)
		h.ServeHTTP(w, r2)
	})
}

// ---- ミドルウェア ----

func corsMiddleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Access-Control-Allow-Origin", "*")
		w.Header().Set("Access-Control-Allow-Methods", "GET, POST, PUT, DELETE, OPTIONS")
		w.Header().Set("Access-Control-Allow-Headers", "Content-Type, Authorization, X-Request-ID")
		if r.Method == http.MethodOptions {
			w.WriteHeader(http.StatusNoContent)
			return
		}
		next.ServeHTTP(w, r)
	})
}

func loggingMiddleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		rw := &statusWriter{ResponseWriter: w, status: http.StatusOK}
		next.ServeHTTP(rw, r)
		log.Printf("[%s] %s %s status=%d latency=%s ip=%s",
			requestIDFromContext(r.Context()), r.Method, r.URL.Path,
			rw.status, time.Since(start).Round(time.Millisecond), clientIP(r))
	})
}

func rateLimitMiddleware(rl *RateLimiter, next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if !rl.Allow(clientIP(r)) {
			w.Header().Set("Retry-After", "1")
			writeError(w, r, http.StatusTooManyRequests, "RATE_LIMIT_EXCEEDED", "rate limit exceeded")
			return
		}
		next.ServeHTTP(w, r)
	})
}

func recoveryMiddleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		defer func() {
			if rec := recover(); rec != nil {
				log.Printf("[PANIC] %s %s: %v", r.Method, r.URL.Path, rec)
				writeError(w, r, http.StatusInternalServerError, "INTERNAL_ERROR", "internal server error")
			}
		}()
		next.ServeHTTP(w, r)
	})
}

type statusWriter struct {
	http.ResponseWriter
	status int
}

func (sw *statusWriter) WriteHeader(status int) {
	sw.status = status
	sw.ResponseWriter.WriteHeader(status)
}

func clientIP(r *http.Request) string {
	addr := r.RemoteAddr
	if idx := strings.LastIndex(addr, ":"); idx >= 0 {
		return addr[:idx]
	}
	return addr
}

// ---- リクエストID ----

type ctxKey int

const requestIDKey ctxKey = 1

func requestIDMiddleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		rid := r.Header.Get("X-Request-ID")
		if rid == "" {
			rid = fmt.Sprintf("%x", time.Now().UnixNano())
		}
		w.Header().Set("X-Request-ID", rid)
		r.Header.Set("X-Request-ID", rid)
		next.ServeHTTP(w, r.WithContext(context.WithValue(r.Context(), requestIDKey, rid)))
	})
}

func requestIDFromContext(ctx context.Context) string {
	if v, ok := ctx.Value(requestIDKey).(string); ok {
		return v
	}
	return "-"
}

// ---- サーバー ----

type server struct {
	cfg Config
	rl  *RateLimiter
	cb  *CircuitBreaker
}

func newServer(cfg Config) *server {
	return &server{
		cfg: cfg,
		rl:  newRateLimiter(cfg.RateLimit, cfg.RateBurst),
		cb:  newCircuitBreaker(cfg.CBThreshold, cfg.CBOpenTimeout),
	}
}

func (s *server) buildMux() *http.ServeMux {
	proxy := func(name, target string) *upstreamProxy {
		return newUpstreamProxy(name, target, s.cb)
	}
	routes := []struct{ path, name, target string }{
		{"/api/cards", "card-gen", s.cfg.CardGenURL},
		{"/api/shuffle", "shuffle", s.cfg.ShuffleURL},
		{"/api/judge", "judge", s.cfg.JudgeURL},
		{"/api/queue", "queue", s.cfg.QueueURL},
		{"/api/serial", "serializer", s.cfg.SerializerURL},
		{"/api/pokedex", "pokedex", s.cfg.PokedexURL},
	}

	mux := http.NewServeMux()
	for _, rt := range routes {
		p := proxy(rt.name, rt.target)
		mux.Handle(rt.path+"/", stripPrefix(rt.path, p))
		mux.Handle(rt.path, stripPrefix(rt.path, p))
	}
	mux.HandleFunc("/health", s.handleHealth)
	return mux
}

func (s *server) handleHealth(w http.ResponseWriter, r *http.Request) {
	results := checkUpstreams(s.cfg)
	allUp := true
	for _, u := range results {
		if u.Status != "up" {
			allUp = false
			break
		}
	}
	w.Header().Set("Content-Type", "application/json")
	if !allUp {
		w.WriteHeader(http.StatusServiceUnavailable)
	}
	json.NewEncoder(w).Encode(map[string]any{
		"gateway":   "up",
		"all_up":    allUp,
		"upstreams": results,
	})
}

// ---- メイン ----

func main() {
	cfg := loadConfig()
	srv := newServer(cfg)
	mux := srv.buildMux()

	handler := recoveryMiddleware(
		requestIDMiddleware(
			loggingMiddleware(
				rateLimitMiddleware(srv.rl,
					corsMiddleware(mux)))))

	httpSrv := &http.Server{
		Addr:         cfg.ListenAddr,
		Handler:      handler,
		ReadTimeout:  cfg.ReadTimeout,
		WriteTimeout: cfg.WriteTimeout,
		IdleTimeout:  cfg.IdleTimeout,
	}

	stop := make(chan os.Signal, 1)
	signal.Notify(stop, os.Interrupt, syscall.SIGTERM)

	go func() {
		log.Printf("gateway listening on %s", cfg.ListenAddr)
		if err := httpSrv.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			log.Fatalf("server failed: %v", err)
		}
	}()

	<-stop
	log.Println("gateway shutting down...")
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	if err := httpSrv.Shutdown(ctx); err != nil {
		log.Printf("graceful shutdown failed: %v", err)
	}
	log.Println("gateway stopped")
}
