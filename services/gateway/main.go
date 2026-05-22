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
	"sync/atomic"
	"syscall"
	"time"
)

// ---- 設定 ----

type Config struct {
	ListenAddr    string
	CardGenURL    string
	ShuffleURL    string
	JudgeURL      string
	QueueURL      string
	SerializerURL string
	RateLimit     int
	RateBurst     int
	ReadTimeout   time.Duration
	WriteTimeout  time.Duration
	IdleTimeout   time.Duration
}

func loadConfig() Config {
	return Config{
		ListenAddr:    getEnv("LISTEN_ADDR", ":8080"),
		CardGenURL:    getEnv("CARD_GEN_URL", "http://card-gen:5000"),
		ShuffleURL:    getEnv("SHUFFLE_URL", "http://shuffle:5001"),
		JudgeURL:      getEnv("JUDGE_URL", "http://judge:5002"),
		QueueURL:      getEnv("QUEUE_URL", "http://queue:5003"),
		SerializerURL: getEnv("SERIALIZER_URL", "http://serializer:5004"),
		RateLimit:     getEnvInt("RATE_LIMIT", 100),
		RateBurst:     getEnvInt("RATE_BURST", 20),
		ReadTimeout:   getEnvDuration("READ_TIMEOUT", 15*time.Second),
		WriteTimeout:  getEnvDuration("WRITE_TIMEOUT", 30*time.Second),
		IdleTimeout:   getEnvDuration("IDLE_TIMEOUT", 60*time.Second),
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

type RateLimiter struct {
	mu       sync.Mutex
	buckets  map[string]*tokenBucket
	limit    int
	burst    int
	cleanTTL time.Duration
}

type tokenBucket struct {
	tokens   float64
	lastTime time.Time
}

func newRateLimiter(limit, burst int) *RateLimiter {
	rl := &RateLimiter{
		buckets:  make(map[string]*tokenBucket),
		limit:    limit,
		burst:    burst,
		cleanTTL: 5 * time.Minute,
	}
	go rl.cleanupLoop()
	return rl
}

func (rl *RateLimiter) Allow(key string) bool {
	rl.mu.Lock()
	defer rl.mu.Unlock()

	now := time.Now()
	b, ok := rl.buckets[key]
	if !ok {
		b = &tokenBucket{tokens: float64(rl.burst), lastTime: now}
		rl.buckets[key] = b
	}

	elapsed := now.Sub(b.lastTime).Seconds()
	b.tokens += elapsed * float64(rl.limit)
	if b.tokens > float64(rl.burst) {
		b.tokens = float64(rl.burst)
	}
	b.lastTime = now

	if b.tokens < 1 {
		return false
	}
	b.tokens--
	return true
}

func (rl *RateLimiter) cleanupLoop() {
	ticker := time.NewTicker(rl.cleanTTL)
	for range ticker.C {
		rl.mu.Lock()
		cutoff := time.Now().Add(-rl.cleanTTL)
		for key, b := range rl.buckets {
			if b.lastTime.Before(cutoff) {
				delete(rl.buckets, key)
			}
		}
		rl.mu.Unlock()
	}
}

// ---- メトリクス ----

type Metrics struct {
	totalRequests  atomic.Int64
	totalErrors    atomic.Int64
	rateLimitHits  atomic.Int64
	upstreamErrors atomic.Int64
}

func (m *Metrics) snapshot() map[string]int64 {
	return map[string]int64{
		"total_requests":   m.totalRequests.Load(),
		"total_errors":     m.totalErrors.Load(),
		"rate_limit_hits":  m.rateLimitHits.Load(),
		"upstream_errors":  m.upstreamErrors.Load(),
	}
}

// ---- ヘルスチェッカー ----

type UpstreamHealth struct {
	Name   string `json:"name"`
	URL    string `json:"url"`
	Status string `json:"status"`
	Code   int    `json:"code"`
}

type HealthChecker struct {
	upstreams []struct{ name, url string }
	client    *http.Client
}

func newHealthChecker(cfg Config) *HealthChecker {
	return &HealthChecker{
		client: &http.Client{Timeout: 3 * time.Second},
		upstreams: []struct{ name, url string }{
			{"card-gen", cfg.CardGenURL + "/health"},
			{"shuffle", cfg.ShuffleURL + "/health"},
			{"judge", cfg.JudgeURL + "/health"},
			{"queue", cfg.QueueURL + "/health"},
			{"serializer", cfg.SerializerURL + "/health"},
		},
	}
}

func (hc *HealthChecker) checkAll() []UpstreamHealth {
	results := make([]UpstreamHealth, len(hc.upstreams))
	var wg sync.WaitGroup
	for i, u := range hc.upstreams {
		wg.Add(1)
		go func(idx int, name, url string) {
			defer wg.Done()
			resp, err := hc.client.Get(url)
			if err != nil {
				results[idx] = UpstreamHealth{name, url, "down", 0}
				return
			}
			defer resp.Body.Close()
			status := "up"
			if resp.StatusCode >= 400 {
				status = "degraded"
			}
			results[idx] = UpstreamHealth{name, url, status, resp.StatusCode}
		}(i, u.name, u.url)
	}
	wg.Wait()
	return results
}

// ---- リバースプロキシ ----

func newReverseProxy(target string, metrics *Metrics) *httputil.ReverseProxy {
	u, err := url.Parse(target)
	if err != nil {
		log.Fatalf("invalid upstream URL %q: %v", target, err)
	}
	proxy := httputil.NewSingleHostReverseProxy(u)
	proxy.ErrorHandler = func(w http.ResponseWriter, r *http.Request, err error) {
		metrics.upstreamErrors.Add(1)
		log.Printf("[PROXY ERROR] %s %s -> %v", r.Method, r.URL.Path, err)
		http.Error(w, `{"error":"upstream unavailable"}`, http.StatusBadGateway)
	}
	return proxy
}

func stripPrefix(prefix string, proxy *httputil.ReverseProxy) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		r2 := r.Clone(r.Context())
		r2.URL.Path = strings.TrimPrefix(r.URL.Path, prefix)
		if r2.URL.Path == "" {
			r2.URL.Path = "/"
		}
		r2.URL.RawPath = strings.TrimPrefix(r.URL.RawPath, prefix)
		proxy.ServeHTTP(w, r2)
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

func loggingMiddleware(metrics *Metrics, next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		metrics.totalRequests.Add(1)
		rw := &responseWriter{ResponseWriter: w, status: http.StatusOK}
		next.ServeHTTP(rw, r)
		dur := time.Since(start)
		rid := requestIDFromContext(r.Context())
		log.Printf("[%s] %s %s %d %s ip=%s", rid, r.Method, r.URL.Path, rw.status, dur.Round(time.Millisecond), clientIP(r))
		if rw.status >= 500 {
			metrics.totalErrors.Add(1)
		}
	})
}

func rateLimitMiddleware(rl *RateLimiter, metrics *Metrics, next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		ip := clientIP(r)
		if !rl.Allow(ip) {
			metrics.rateLimitHits.Add(1)
			w.Header().Set("Content-Type", "application/json")
			w.Header().Set("Retry-After", "1")
			w.WriteHeader(http.StatusTooManyRequests)
			w.Write([]byte(`{"error":"rate limit exceeded"}`))
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
				http.Error(w, `{"error":"internal server error"}`, http.StatusInternalServerError)
			}
		}()
		next.ServeHTTP(w, r)
	})
}

type responseWriter struct {
	http.ResponseWriter
	status int
}

func (rw *responseWriter) WriteHeader(status int) {
	rw.status = status
	rw.ResponseWriter.WriteHeader(status)
}

func clientIP(r *http.Request) string {
	if ip := r.Header.Get("X-Forwarded-For"); ip != "" {
		parts := strings.SplitN(ip, ",", 2)
		return strings.TrimSpace(parts[0])
	}
	if ip := r.Header.Get("X-Real-IP"); ip != "" {
		return ip
	}
	addr := r.RemoteAddr
	if idx := strings.LastIndex(addr, ":"); idx >= 0 {
		return addr[:idx]
	}
	return addr
}

// ---- リクエストID / トレース ----

type ctxKey int

const requestIDKey ctxKey = 1

func generateRequestID() string {
	const charset = "abcdefghijklmnopqrstuvwxyz0123456789"
	b := make([]byte, 16)
	now := time.Now().UnixNano()
	for i := range b {
		b[i] = charset[int(now>>uint(i*3))%len(charset)]
	}
	return string(b)
}

func requestIDMiddleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		rid := r.Header.Get("X-Request-ID")
		if rid == "" {
			rid = generateRequestID()
		}
		w.Header().Set("X-Request-ID", rid)
		ctx := context.WithValue(r.Context(), requestIDKey, rid)
		r.Header.Set("X-Request-ID", rid)
		next.ServeHTTP(w, r.WithContext(ctx))
	})
}

func requestIDFromContext(ctx context.Context) string {
	if v, ok := ctx.Value(requestIDKey).(string); ok {
		return v
	}
	return "-"
}

// ---- サーキットブレーカー ----

type CircuitBreaker struct {
	mu          sync.Mutex
	failures    map[string]int
	openedAt    map[string]time.Time
	threshold   int
	openTimeout time.Duration
}

func newCircuitBreaker(threshold int, openTimeout time.Duration) *CircuitBreaker {
	return &CircuitBreaker{
		failures:    make(map[string]int),
		openedAt:    make(map[string]time.Time),
		threshold:   threshold,
		openTimeout: openTimeout,
	}
}

func (cb *CircuitBreaker) Allow(upstream string) bool {
	cb.mu.Lock()
	defer cb.mu.Unlock()
	if openedAt, open := cb.openedAt[upstream]; open {
		if time.Since(openedAt) < cb.openTimeout {
			return false
		}
		delete(cb.openedAt, upstream)
		cb.failures[upstream] = 0
	}
	return true
}

func (cb *CircuitBreaker) RecordSuccess(upstream string) {
	cb.mu.Lock()
	defer cb.mu.Unlock()
	cb.failures[upstream] = 0
}

func (cb *CircuitBreaker) RecordFailure(upstream string) {
	cb.mu.Lock()
	defer cb.mu.Unlock()
	cb.failures[upstream]++
	if cb.failures[upstream] >= cb.threshold {
		cb.openedAt[upstream] = time.Now()
	}
}

func (cb *CircuitBreaker) State(upstream string) string {
	cb.mu.Lock()
	defer cb.mu.Unlock()
	if openedAt, open := cb.openedAt[upstream]; open && time.Since(openedAt) < cb.openTimeout {
		return "open"
	}
	if cb.failures[upstream] > 0 {
		return "half-open"
	}
	return "closed"
}

// ---- ルーター構築 ----

func buildMux(cfg Config, metrics *Metrics, healthChecker *HealthChecker) *http.ServeMux {
	cardGenProxy   := newReverseProxy(cfg.CardGenURL, metrics)
	shuffleProxy   := newReverseProxy(cfg.ShuffleURL, metrics)
	judgeProxy     := newReverseProxy(cfg.JudgeURL, metrics)
	queueProxy     := newReverseProxy(cfg.QueueURL, metrics)
	serializerProxy := newReverseProxy(cfg.SerializerURL, metrics)

	mux := http.NewServeMux()

	mux.Handle("/api/cards/", stripPrefix("/api/cards", cardGenProxy))
	mux.Handle("/api/cards",  stripPrefix("/api/cards", cardGenProxy))

	mux.Handle("/api/shuffle/", stripPrefix("/api/shuffle", shuffleProxy))
	mux.Handle("/api/shuffle",  stripPrefix("/api/shuffle", shuffleProxy))

	mux.Handle("/api/judge/", stripPrefix("/api/judge", judgeProxy))
	mux.Handle("/api/judge",  stripPrefix("/api/judge", judgeProxy))

	mux.Handle("/api/queue/", stripPrefix("/api/queue", queueProxy))
	mux.Handle("/api/queue",  stripPrefix("/api/queue", queueProxy))

	mux.Handle("/api/serial/", stripPrefix("/api/serial", serializerProxy))
	mux.Handle("/api/serial",  stripPrefix("/api/serial", serializerProxy))

	mux.HandleFunc("/health", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusOK)
		json.NewEncoder(w).Encode(map[string]string{"status": "ok"})
	})

	mux.HandleFunc("/health/upstreams", func(w http.ResponseWriter, r *http.Request) {
		results := healthChecker.checkAll()
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
		json.NewEncoder(w).Encode(map[string]interface{}{
			"gateway": "up",
			"upstreams": results,
		})
	})

	mux.HandleFunc("/metrics", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(metrics.snapshot())
	})

	return mux
}

// ---- メイン ----

func main() {
	cfg           := loadConfig()
	metrics       := &Metrics{}
	healthChecker := newHealthChecker(cfg)
	rl            := newRateLimiter(cfg.RateLimit, cfg.RateBurst)

	mux := buildMux(cfg, metrics, healthChecker)

	handler := recoveryMiddleware(
		requestIDMiddleware(
			loggingMiddleware(metrics,
				rateLimitMiddleware(rl, metrics,
					corsMiddleware(mux)))))

	srv := &http.Server{
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
		if err := srv.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			log.Fatalf("server failed: %v", err)
		}
	}()

	<-stop
	log.Println("gateway shutting down...")
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	if err := srv.Shutdown(ctx); err != nil {
		log.Printf("graceful shutdown failed: %v", err)
	}
	log.Println("gateway stopped")
}
