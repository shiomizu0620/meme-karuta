package main

import (
	"bytes"
	"context"
	"crypto/sha1"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"math"
	"net/http"
	"net/http/httputil"
	"net/url"
	"os"
	"os/signal"
	"sort"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"time"
)

// ---- エラーレスポンス ----

type APIError struct {
	Code      string            `json:"code"`
	Message   string            `json:"message"`
	RequestID string            `json:"request_id,omitempty"`
	Details   map[string]string `json:"details,omitempty"`
}

func writeError(w http.ResponseWriter, r *http.Request, status int, code, msg string) {
	writeErrorWithDetails(w, r, status, code, msg, nil)
}

func writeErrorWithDetails(w http.ResponseWriter, r *http.Request, status int, code, msg string, details map[string]string) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	json.NewEncoder(w).Encode(APIError{
		Code:      code,
		Message:   msg,
		RequestID: requestIDFromContext(r.Context()),
		Details:   details,
	})
}

// 既知のエラーコード一覧（ドキュメント代わり兼テスト参照用）
var errorCodes = []string{
	"UPSTREAM_ERROR",
	"CIRCUIT_OPEN",
	"RATE_LIMIT_EXCEEDED",
	"INTERNAL_ERROR",
	"INVALID_BODY",
	"BODY_TOO_LARGE",
	"NOT_MODIFIED",
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

// ---- メトリクス ----

type Metrics struct {
	mu             sync.Mutex
	requests       map[string]uint64 // method+path -> count
	statusCounts   map[int]uint64
	latencyBuckets []float64
	latencyHist    []uint64
	upstreamUp     map[string]int
	totalRequests  atomic.Uint64
	totalErrors    atomic.Uint64
}

func newMetrics() *Metrics {
	return &Metrics{
		requests:       make(map[string]uint64),
		statusCounts:   make(map[int]uint64),
		latencyBuckets: []float64{5, 10, 25, 50, 100, 250, 500, 1000, 2500, 5000},
		latencyHist:    make([]uint64, 11),
		upstreamUp:     make(map[string]int),
	}
}

func (m *Metrics) Record(method, path string, status int, latencyMs float64) {
	m.totalRequests.Add(1)
	if status >= 500 {
		m.totalErrors.Add(1)
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	m.requests[method+" "+path]++
	m.statusCounts[status]++
	idx := len(m.latencyBuckets)
	for i, b := range m.latencyBuckets {
		if latencyMs <= b {
			idx = i
			break
		}
	}
	m.latencyHist[idx]++
}

func (m *Metrics) SetUpstream(name string, up bool) {
	m.mu.Lock()
	defer m.mu.Unlock()
	if up {
		m.upstreamUp[name] = 1
	} else {
		m.upstreamUp[name] = 0
	}
}

func (m *Metrics) Render(w io.Writer) {
	m.mu.Lock()
	defer m.mu.Unlock()
	fmt.Fprintf(w, "# HELP gateway_requests_total Total HTTP requests by route\n")
	fmt.Fprintf(w, "# TYPE gateway_requests_total counter\n")
	keys := make([]string, 0, len(m.requests))
	for k := range m.requests {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	for _, k := range keys {
		parts := strings.SplitN(k, " ", 2)
		fmt.Fprintf(w, "gateway_requests_total{method=%q,path=%q} %d\n", parts[0], parts[1], m.requests[k])
	}
	fmt.Fprintf(w, "# HELP gateway_responses_total Total responses by status\n")
	fmt.Fprintf(w, "# TYPE gateway_responses_total counter\n")
	statuses := make([]int, 0, len(m.statusCounts))
	for s := range m.statusCounts {
		statuses = append(statuses, s)
	}
	sort.Ints(statuses)
	for _, s := range statuses {
		fmt.Fprintf(w, "gateway_responses_total{status=\"%d\"} %d\n", s, m.statusCounts[s])
	}
	fmt.Fprintf(w, "# HELP gateway_latency_ms Histogram of request latency in ms\n")
	fmt.Fprintf(w, "# TYPE gateway_latency_ms histogram\n")
	var cum uint64
	for i, b := range m.latencyBuckets {
		cum += m.latencyHist[i]
		fmt.Fprintf(w, "gateway_latency_ms_bucket{le=\"%g\"} %d\n", b, cum)
	}
	cum += m.latencyHist[len(m.latencyBuckets)]
	fmt.Fprintf(w, "gateway_latency_ms_bucket{le=\"+Inf\"} %d\n", cum)
	fmt.Fprintf(w, "# HELP gateway_upstream_up 1 when upstream healthy, 0 otherwise\n")
	fmt.Fprintf(w, "# TYPE gateway_upstream_up gauge\n")
	names := make([]string, 0, len(m.upstreamUp))
	for n := range m.upstreamUp {
		names = append(names, n)
	}
	sort.Strings(names)
	for _, n := range names {
		fmt.Fprintf(w, "gateway_upstream_up{name=%q} %d\n", n, m.upstreamUp[n])
	}
	fmt.Fprintf(w, "# HELP gateway_errors_total Total 5xx responses\n")
	fmt.Fprintf(w, "# TYPE gateway_errors_total counter\n")
	fmt.Fprintf(w, "gateway_errors_total %d\n", m.totalErrors.Load())
}

func metricsMiddleware(m *Metrics, next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		rw := &statusWriter{ResponseWriter: w, status: http.StatusOK}
		next.ServeHTTP(rw, r)
		latency := float64(time.Since(start).Nanoseconds()) / 1e6
		if math.IsNaN(latency) || math.IsInf(latency, 0) {
			latency = 0
		}
		m.Record(r.Method, normalizeRoute(r.URL.Path), rw.status, latency)
	})
}

func normalizeRoute(p string) string {
	// /api/foo/... を /api/foo に正規化（カーディナリティ抑制）
	if !strings.HasPrefix(p, "/api/") {
		return p
	}
	parts := strings.SplitN(strings.TrimPrefix(p, "/api/"), "/", 2)
	return "/api/" + parts[0]
}

// ---- バリデーション・ETag ----

const maxBodyBytes = 1 << 20 // 1MiB

// bodyLimitMiddleware は Content-Length 過大なリクエストを 413 で拒否する。
func bodyLimitMiddleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.ContentLength > maxBodyBytes {
			writeError(w, r, http.StatusRequestEntityTooLarge, "BODY_TOO_LARGE",
				fmt.Sprintf("request body exceeds %d bytes", maxBodyBytes))
			return
		}
		if r.ContentLength > 0 {
			r.Body = http.MaxBytesReader(w, r.Body, maxBodyBytes)
		}
		next.ServeHTTP(w, r)
	})
}

// jsonValidator は Content-Type が application/json と宣言されたリクエストに対し
// ボディが正規の JSON であることを検証する。空ボディはスルー。
func jsonValidator(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		ct := r.Header.Get("Content-Type")
		if r.ContentLength <= 0 || !strings.HasPrefix(ct, "application/json") {
			next.ServeHTTP(w, r)
			return
		}
		buf, err := io.ReadAll(r.Body)
		if err != nil {
			writeError(w, r, http.StatusBadRequest, "INVALID_BODY", "failed to read request body")
			return
		}
		var probe any
		if err := json.Unmarshal(buf, &probe); err != nil {
			writeErrorWithDetails(w, r, http.StatusBadRequest, "INVALID_BODY",
				"request body is not valid JSON",
				map[string]string{"parse_error": err.Error()})
			return
		}
		r.Body = io.NopCloser(bytes.NewReader(buf))
		r.ContentLength = int64(len(buf))
		next.ServeHTTP(w, r)
	})
}

// etagResponseWriter は本文をバッファし、レスポンスに対する ETag を計算する。
type etagResponseWriter struct {
	http.ResponseWriter
	buf    bytes.Buffer
	status int
}

func (e *etagResponseWriter) WriteHeader(status int) { e.status = status }
func (e *etagResponseWriter) Write(p []byte) (int, error) {
	return e.buf.Write(p)
}

// etagMiddleware は GET の 200 応答に対して ETag を付与し、If-None-Match で 304 を返す。
func etagMiddleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodGet {
			next.ServeHTTP(w, r)
			return
		}
		ew := &etagResponseWriter{ResponseWriter: w, status: http.StatusOK}
		next.ServeHTTP(ew, r)
		if ew.status != http.StatusOK {
			w.WriteHeader(ew.status)
			_, _ = w.Write(ew.buf.Bytes())
			return
		}
		sum := sha1.Sum(ew.buf.Bytes())
		etag := `"` + hex.EncodeToString(sum[:]) + `"`
		w.Header().Set("ETag", etag)
		if match := r.Header.Get("If-None-Match"); match != "" && match == etag {
			w.WriteHeader(http.StatusNotModified)
			return
		}
		w.Header().Set("Content-Length", strconv.Itoa(ew.buf.Len()))
		w.WriteHeader(ew.status)
		_, _ = w.Write(ew.buf.Bytes())
	})
}

// ---- 構造化ログ ----

type logEntry struct {
	Time      string  `json:"ts"`
	Level     string  `json:"level"`
	RequestID string  `json:"request_id,omitempty"`
	Method    string  `json:"method"`
	Path      string  `json:"path"`
	Status    int     `json:"status"`
	LatencyMs float64 `json:"latency_ms"`
	IP        string  `json:"ip,omitempty"`
}

func writeJSONLog(e logEntry) {
	e.Time = time.Now().UTC().Format(time.RFC3339Nano)
	if e.Level == "" {
		e.Level = "info"
	}
	if e.Status >= 500 {
		e.Level = "error"
	} else if e.Status >= 400 {
		e.Level = "warn"
	}
	buf, err := json.Marshal(e)
	if err != nil {
		return
	}
	fmt.Fprintln(os.Stdout, string(buf))
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
		latency := float64(time.Since(start).Nanoseconds()) / 1e6
		writeJSONLog(logEntry{
			RequestID: requestIDFromContext(r.Context()),
			Method:    r.Method,
			Path:      r.URL.Path,
			Status:    rw.status,
			LatencyMs: latency,
			IP:        clientIP(r),
		})
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

func contextWithRequestID(ctx context.Context, rid string) context.Context {
	return context.WithValue(ctx, requestIDKey, rid)
}

// ---- サーバー ----

type server struct {
	cfg     Config
	rl      *RateLimiter
	cb      *CircuitBreaker
	metrics *Metrics
}

func newServer(cfg Config) *server {
	return &server{
		cfg:     cfg,
		rl:      newRateLimiter(cfg.RateLimit, cfg.RateBurst),
		cb:      newCircuitBreaker(cfg.CBThreshold, cfg.CBOpenTimeout),
		metrics: newMetrics(),
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
	mux.HandleFunc("/metrics", s.handleMetrics)
	mux.HandleFunc("/api/errors", s.handleErrors)
	mux.HandleFunc("/debug/config", s.handleConfig)
	mux.HandleFunc("/api/routes", s.handleRoutes)
	return mux
}

func (s *server) handleMetrics(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "text/plain; version=0.0.4; charset=utf-8")
	s.metrics.Render(w)
}

// handleErrors は本ゲートウェイが返却し得るエラーコード一覧を返す。
// クライアント実装でエラーメッセージのローカライズやハンドリング分岐をする際の参照用。
func (s *server) handleErrors(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string]any{"codes": errorCodes})
}

// ---- 設定スナップショット ----
// /debug/config は機微情報を含まない範囲で現在の設定を返す。
// アップストリーム URL のホスト解決状況や CB 状態の確認用に使う想定。

type configSnapshot struct {
	ListenAddr    string `json:"listen_addr"`
	RateLimit     int    `json:"rate_limit"`
	RateBurst     int    `json:"rate_burst"`
	CBThreshold   int    `json:"cb_threshold"`
	CBOpenTimeout string `json:"cb_open_timeout"`
	ReadTimeout   string `json:"read_timeout"`
	WriteTimeout  string `json:"write_timeout"`
	Upstreams     map[string]string `json:"upstreams"`
}

func (s *server) handleConfig(w http.ResponseWriter, r *http.Request) {
	snap := configSnapshot{
		ListenAddr:    s.cfg.ListenAddr,
		RateLimit:     s.cfg.RateLimit,
		RateBurst:     s.cfg.RateBurst,
		CBThreshold:   s.cfg.CBThreshold,
		CBOpenTimeout: s.cfg.CBOpenTimeout.String(),
		ReadTimeout:   s.cfg.ReadTimeout.String(),
		WriteTimeout:  s.cfg.WriteTimeout.String(),
		Upstreams: map[string]string{
			"card-gen":   s.cfg.CardGenURL,
			"shuffle":    s.cfg.ShuffleURL,
			"judge":      s.cfg.JudgeURL,
			"queue":      s.cfg.QueueURL,
			"serializer": s.cfg.SerializerURL,
			"pokedex":    s.cfg.PokedexURL,
		},
	}
	w.Header().Set("Content-Type", "application/json")
	enc := json.NewEncoder(w)
	enc.SetIndent("", "  ")
	enc.Encode(snap)
}

// ---- ルートの簡易ドキュメンテーション ----
// /api/routes は本ゲートウェイが提供する API 一覧を JSON で返す。
// フロントエンドの自動ドキュメント・スモークテストから参照される。

func (s *server) handleRoutes(w http.ResponseWriter, r *http.Request) {
	routes := []map[string]string{
		{"path": "/api/cards",      "upstream": "card-gen",   "desc": "カードデータの取得"},
		{"path": "/api/shuffle",    "upstream": "shuffle",    "desc": "シャッフル API"},
		{"path": "/api/judge",      "upstream": "judge",      "desc": "先着判定 API"},
		{"path": "/api/queue",      "upstream": "queue",      "desc": "イベントキュー API"},
		{"path": "/api/serial",     "upstream": "serializer", "desc": "バイナリシリアライザ"},
		{"path": "/api/pokedex",    "upstream": "pokedex",    "desc": "コレクション管理 API"},
		{"path": "/health",         "upstream": "self",       "desc": "アップストリーム合算ヘルス"},
		{"path": "/metrics",        "upstream": "self",       "desc": "Prometheus メトリクス"},
		{"path": "/api/errors",     "upstream": "self",       "desc": "エラーコード一覧"},
		{"path": "/debug/config",   "upstream": "self",       "desc": "現在の設定スナップショット"},
		{"path": "/api/routes",     "upstream": "self",       "desc": "本一覧"},
	}
	w.Header().Set("Content-Type", "application/json")
	enc := json.NewEncoder(w)
	enc.SetIndent("", "  ")
	enc.Encode(map[string]any{"routes": routes})
}

func (s *server) handleHealth(w http.ResponseWriter, r *http.Request) {
	results := checkUpstreams(s.cfg)
	allUp := true
	for _, u := range results {
		s.metrics.SetUpstream(u.Name, u.Status == "up")
		if u.Status != "up" {
			allUp = false
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
				metricsMiddleware(srv.metrics,
					bodyLimitMiddleware(
						jsonValidator(
							rateLimitMiddleware(srv.rl,
								corsMiddleware(etagMiddleware(mux)))))))))

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
