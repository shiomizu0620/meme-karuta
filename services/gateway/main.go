package main

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"net/http/httputil"
	"net/url"
	"os"
	"os/signal"
	"sort"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"time"
)

// ---- 統一エラーレスポンス ----

type APIError struct {
	Code      string `json:"code"`
	Message   string `json:"message"`
	RequestID string `json:"request_id,omitempty"`
	Details   any    `json:"details,omitempty"`
}

const (
	ErrCodeRateLimit       = "RATE_LIMIT_EXCEEDED"
	ErrCodeUpstream        = "UPSTREAM_ERROR"
	ErrCodeCircuitOpen     = "CIRCUIT_OPEN"
	ErrCodeRequestTooLarge = "REQUEST_TOO_LARGE"
	ErrCodeInternalError   = "INTERNAL_ERROR"
	ErrCodeNotFound        = "NOT_FOUND"
	ErrCodeMethodNotAllowed = "METHOD_NOT_ALLOWED"
	ErrCodeBadRequest      = "BAD_REQUEST"
)

func writeError(w http.ResponseWriter, r *http.Request, status int, code, message string, details any) {
	rid := requestIDFromContext(r.Context())
	resp := APIError{
		Code:      code,
		Message:   message,
		RequestID: rid,
		Details:   details,
	}
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	json.NewEncoder(w).Encode(resp)
}

// ---- 設定 ----

type RouteRateLimit struct {
	Limit int
	Burst int
}

type UpstreamTimeouts struct {
	CardGen    time.Duration
	Shuffle    time.Duration
	Judge      time.Duration
	Queue      time.Duration
	Serializer time.Duration
}

type Config struct {
	ListenAddr       string
	CardGenURL       string
	ShuffleURL       string
	JudgeURL         string
	QueueURL         string
	SerializerURL    string
	RateLimit        int
	RateBurst        int
	ReadTimeout      time.Duration
	WriteTimeout     time.Duration
	IdleTimeout      time.Duration
	MaxRequestBytes  int64
	CacheTTL         time.Duration
	CBThreshold      int
	CBOpenTimeout    time.Duration
	AdminToken       string
	RetryMax         int
	RetryBaseDelay   time.Duration
	UpstreamTimeouts UpstreamTimeouts
	RouteRateLimits  map[string]RouteRateLimit
}

func loadConfig() Config {
	return Config{
		ListenAddr:      getEnv("LISTEN_ADDR", ":8080"),
		CardGenURL:      getEnv("CARD_GEN_URL", "http://card-gen:5000"),
		ShuffleURL:      getEnv("SHUFFLE_URL", "http://shuffle:5001"),
		JudgeURL:        getEnv("JUDGE_URL", "http://judge:5002"),
		QueueURL:        getEnv("QUEUE_URL", "http://queue:5003"),
		SerializerURL:   getEnv("SERIALIZER_URL", "http://serializer:5004"),
		RateLimit:       getEnvInt("RATE_LIMIT", 100),
		RateBurst:       getEnvInt("RATE_BURST", 20),
		ReadTimeout:     getEnvDuration("READ_TIMEOUT", 15*time.Second),
		WriteTimeout:    getEnvDuration("WRITE_TIMEOUT", 30*time.Second),
		IdleTimeout:     getEnvDuration("IDLE_TIMEOUT", 60*time.Second),
		MaxRequestBytes: int64(getEnvInt("MAX_REQUEST_BYTES", 1<<20)),
		CacheTTL:        getEnvDuration("CACHE_TTL", 30*time.Second),
		CBThreshold:     getEnvInt("CB_THRESHOLD", 5),
		CBOpenTimeout:   getEnvDuration("CB_OPEN_TIMEOUT", 30*time.Second),
		AdminToken:     getEnv("ADMIN_TOKEN", ""),
		RetryMax:       getEnvInt("RETRY_MAX", 2),
		RetryBaseDelay: getEnvDuration("RETRY_BASE_DELAY", 100*time.Millisecond),
		// shuffle は Fisher-Yates で重いので長めに、judge は先着判定なので短めに
		UpstreamTimeouts: UpstreamTimeouts{
			CardGen:    getEnvDuration("TIMEOUT_CARD_GEN", 5*time.Second),
			Shuffle:    getEnvDuration("TIMEOUT_SHUFFLE", 10*time.Second),
			Judge:      getEnvDuration("TIMEOUT_JUDGE", 3*time.Second),
			Queue:      getEnvDuration("TIMEOUT_QUEUE", 5*time.Second),
			Serializer: getEnvDuration("TIMEOUT_SERIALIZER", 5*time.Second),
		},
		// judge は競合リクエストが集中するので制限を厳しめに、shuffle は重い処理なので緩めに
		RouteRateLimits: map[string]RouteRateLimit{
			"/api/judge":   {Limit: 200, Burst: 50},
			"/api/shuffle": {Limit: 30, Burst: 10},
			"/api/cards":   {Limit: 50, Burst: 20},
			"/api/serial":  {Limit: 50, Burst: 20},
			"/api/queue":   {Limit: 100, Burst: 30},
		},
	}
}

func (cfg Config) upstreamTimeout(name string) time.Duration {
	switch name {
	case "card-gen":
		return cfg.UpstreamTimeouts.CardGen
	case "shuffle":
		return cfg.UpstreamTimeouts.Shuffle
	case "judge":
		return cfg.UpstreamTimeouts.Judge
	case "queue":
		return cfg.UpstreamTimeouts.Queue
	case "serializer":
		return cfg.UpstreamTimeouts.Serializer
	default:
		return 5 * time.Second
	}
}

func validateConfig(cfg Config) error {
	for name, rawURL := range map[string]string{
		"CARD_GEN_URL":    cfg.CardGenURL,
		"SHUFFLE_URL":     cfg.ShuffleURL,
		"JUDGE_URL":       cfg.JudgeURL,
		"QUEUE_URL":       cfg.QueueURL,
		"SERIALIZER_URL":  cfg.SerializerURL,
	} {
		if _, err := url.Parse(rawURL); err != nil {
			return fmt.Errorf("%s is invalid URL %q: %w", name, rawURL, err)
		}
	}
	if cfg.RateLimit <= 0 {
		return fmt.Errorf("RATE_LIMIT must be positive, got %d", cfg.RateLimit)
	}
	if cfg.RateBurst <= 0 {
		return fmt.Errorf("RATE_BURST must be positive, got %d", cfg.RateBurst)
	}
	if cfg.CBThreshold <= 0 {
		return fmt.Errorf("CB_THRESHOLD must be positive, got %d", cfg.CBThreshold)
	}
	if cfg.MaxRequestBytes <= 0 {
		return fmt.Errorf("MAX_REQUEST_BYTES must be positive, got %d", cfg.MaxRequestBytes)
	}
	return nil
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
	mu       sync.Mutex
	buckets  map[string]*tokenBucket
	limit    float64
	burst    float64
	cleanTTL time.Duration
}

func newRateLimiter(limit, burst int) *RateLimiter {
	rl := &RateLimiter{
		buckets:  make(map[string]*tokenBucket),
		limit:    float64(limit),
		burst:    float64(burst),
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
		b = &tokenBucket{tokens: rl.burst, lastTime: now}
		rl.buckets[key] = b
	}

	elapsed := now.Sub(b.lastTime).Seconds()
	b.tokens += elapsed * rl.limit
	if b.tokens > rl.burst {
		b.tokens = rl.burst
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

// ルートごとに独立したレートリミッターを管理し、グローバル制限と組み合わせる
type RateLimiterManager struct {
	mu       sync.RWMutex
	limiters map[string]*RateLimiter
	global   *RateLimiter
}

func newRateLimiterManager(global *RateLimiter, configs map[string]RouteRateLimit) *RateLimiterManager {
	m := &RateLimiterManager{
		limiters: make(map[string]*RateLimiter, len(configs)),
		global:   global,
	}
	for route, cfg := range configs {
		m.limiters[route] = newRateLimiter(cfg.Limit, cfg.Burst)
	}
	return m
}

// Allow はルート固有のリミットとグローバルリミットの両方を通過したときだけ true を返す
func (m *RateLimiterManager) Allow(route, ip string) bool {
	m.mu.RLock()
	rl, ok := m.limiters[route]
	m.mu.RUnlock()
	if ok && !rl.Allow(ip) {
		return false
	}
	return m.global.Allow(ip)
}

// ---- メトリクス ----

type LatencyTracker struct {
	mu      sync.Mutex
	samples []float64
	maxSize int
}

func newLatencyTracker(maxSize int) *LatencyTracker {
	return &LatencyTracker{
		samples: make([]float64, 0, maxSize),
		maxSize: maxSize,
	}
}

func (lt *LatencyTracker) Record(ms float64) {
	lt.mu.Lock()
	defer lt.mu.Unlock()
	if len(lt.samples) >= lt.maxSize {
		copy(lt.samples, lt.samples[1:])
		lt.samples = lt.samples[:lt.maxSize-1]
	}
	lt.samples = append(lt.samples, ms)
}

func (lt *LatencyTracker) Percentile(p float64) float64 {
	lt.mu.Lock()
	defer lt.mu.Unlock()
	if len(lt.samples) == 0 {
		return 0
	}
	sorted := make([]float64, len(lt.samples))
	copy(sorted, lt.samples)
	sort.Float64s(sorted)
	idx := int(float64(len(sorted)-1) * p)
	return sorted[idx]
}

type RouteMetrics struct {
	requests atomic.Int64
	errors   atomic.Int64
	latency  *LatencyTracker
}

type Metrics struct {
	totalRequests  atomic.Int64
	totalErrors    atomic.Int64
	rateLimitHits  atomic.Int64
	upstreamErrors atomic.Int64
	cacheHits      atomic.Int64
	cacheMisses    atomic.Int64
	circuitOpen    atomic.Int64
	mu             sync.RWMutex
	routes         map[string]*RouteMetrics
}

func newMetrics() *Metrics {
	return &Metrics{routes: make(map[string]*RouteMetrics)}
}

func (m *Metrics) routeMetrics(route string) *RouteMetrics {
	m.mu.RLock()
	rm, ok := m.routes[route]
	m.mu.RUnlock()
	if ok {
		return rm
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	if rm, ok = m.routes[route]; ok {
		return rm
	}
	rm = &RouteMetrics{latency: newLatencyTracker(500)}
	m.routes[route] = rm
	return rm
}

func (m *Metrics) RecordRequest(route string, statusCode int, latencyMs float64) {
	m.totalRequests.Add(1)
	rm := m.routeMetrics(route)
	rm.requests.Add(1)
	rm.latency.Record(latencyMs)
	if statusCode >= 500 {
		m.totalErrors.Add(1)
		rm.errors.Add(1)
	}
}

func (m *Metrics) snapshot() map[string]any {
	m.mu.RLock()
	defer m.mu.RUnlock()
	routeStats := make(map[string]any, len(m.routes))
	for route, rm := range m.routes {
		routeStats[route] = map[string]any{
			"requests":       rm.requests.Load(),
			"errors":         rm.errors.Load(),
			"latency_p50_ms": rm.latency.Percentile(0.50),
			"latency_p95_ms": rm.latency.Percentile(0.95),
		}
	}
	return map[string]any{
		"total_requests":  m.totalRequests.Load(),
		"total_errors":    m.totalErrors.Load(),
		"rate_limit_hits": m.rateLimitHits.Load(),
		"upstream_errors": m.upstreamErrors.Load(),
		"cache_hits":      m.cacheHits.Load(),
		"cache_misses":    m.cacheMisses.Load(),
		"circuit_open":    m.circuitOpen.Load(),
		"routes":          routeStats,
	}
}

// ---- レスポンスキャッシュ ----

type cacheEntry struct {
	body        []byte
	status      int
	contentType string
	storedAt    time.Time
	ttl         time.Duration
}

func (e *cacheEntry) expired() bool {
	return time.Since(e.storedAt) > e.ttl
}

type ResponseCache struct {
	mu      sync.RWMutex
	entries map[string]*cacheEntry
	ttl     time.Duration
}

func newResponseCache(ttl time.Duration) *ResponseCache {
	rc := &ResponseCache{
		entries: make(map[string]*cacheEntry),
		ttl:     ttl,
	}
	go rc.cleanupLoop()
	return rc
}

func (rc *ResponseCache) cacheKey(r *http.Request) string {
	return r.Method + ":" + r.URL.String()
}

func (rc *ResponseCache) Get(r *http.Request) (*cacheEntry, bool) {
	if r.Method != http.MethodGet {
		return nil, false
	}
	key := rc.cacheKey(r)
	rc.mu.RLock()
	e, ok := rc.entries[key]
	rc.mu.RUnlock()
	if !ok || e.expired() {
		return nil, false
	}
	return e, true
}

func (rc *ResponseCache) Set(r *http.Request, status int, contentType string, body []byte) {
	if r.Method != http.MethodGet || status != http.StatusOK {
		return
	}
	key := rc.cacheKey(r)
	copied := make([]byte, len(body))
	copy(copied, body)
	rc.mu.Lock()
	rc.entries[key] = &cacheEntry{
		body:        copied,
		status:      status,
		contentType: contentType,
		storedAt:    time.Now(),
		ttl:         rc.ttl,
	}
	rc.mu.Unlock()
}

func (rc *ResponseCache) Invalidate(prefix string) int {
	rc.mu.Lock()
	defer rc.mu.Unlock()
	count := 0
	for key := range rc.entries {
		if strings.Contains(key, prefix) {
			delete(rc.entries, key)
			count++
		}
	}
	return count
}

func (rc *ResponseCache) Stats() map[string]int {
	rc.mu.RLock()
	defer rc.mu.RUnlock()
	live, expired := 0, 0
	for _, e := range rc.entries {
		if e.expired() {
			expired++
		} else {
			live++
		}
	}
	return map[string]int{"live": live, "expired": expired, "total": live + expired}
}

func (rc *ResponseCache) cleanupLoop() {
	ticker := time.NewTicker(rc.ttl)
	for range ticker.C {
		rc.mu.Lock()
		for key, e := range rc.entries {
			if e.expired() {
				delete(rc.entries, key)
			}
		}
		rc.mu.Unlock()
	}
}

// ---- ヘルスチェッカー ----

type UpstreamHealth struct {
	Name      string  `json:"name"`
	URL       string  `json:"url"`
	Status    string  `json:"status"`
	Code      int     `json:"code,omitempty"`
	LatencyMs float64 `json:"latency_ms"`
	CheckedAt string  `json:"checked_at"`
}

type HealthSnapshot struct {
	Results   []UpstreamHealth `json:"results"`
	CheckedAt time.Time        `json:"checked_at"`
	AllUp     bool             `json:"all_up"`
}

type HealthChecker struct {
	upstreams  []struct{ name, url string }
	client     *http.Client
	mu         sync.RWMutex
	history    []HealthSnapshot
	maxHistory int
}

func newHealthChecker(cfg Config) *HealthChecker {
	hc := &HealthChecker{
		client: &http.Client{Timeout: 3 * time.Second},
		upstreams: []struct{ name, url string }{
			{"card-gen", cfg.CardGenURL + "/health"},
			{"shuffle", cfg.ShuffleURL + "/health"},
			{"judge", cfg.JudgeURL + "/health"},
			{"queue", cfg.QueueURL + "/health"},
			{"serializer", cfg.SerializerURL + "/health"},
		},
		maxHistory: 10,
	}
	go hc.backgroundCheck()
	return hc
}

func (hc *HealthChecker) checkAll() []UpstreamHealth {
	results := make([]UpstreamHealth, len(hc.upstreams))
	var wg sync.WaitGroup
	for i, u := range hc.upstreams {
		wg.Add(1)
		go func(idx int, name, rawURL string) {
			defer wg.Done()
			start := time.Now()
			resp, err := hc.client.Get(rawURL)
			latency := float64(time.Since(start).Nanoseconds()) / 1e6
			ts := time.Now().Format(time.RFC3339)
			if err != nil {
				results[idx] = UpstreamHealth{
					Name: name, URL: rawURL, Status: "down",
					LatencyMs: latency, CheckedAt: ts,
				}
				return
			}
			defer resp.Body.Close()
			status := "up"
			if resp.StatusCode >= 500 {
				status = "down"
			} else if resp.StatusCode >= 400 {
				status = "degraded"
			}
			results[idx] = UpstreamHealth{
				Name: name, URL: rawURL, Status: status,
				Code: resp.StatusCode, LatencyMs: latency, CheckedAt: ts,
			}
		}(i, u.name, u.url)
	}
	wg.Wait()
	return results
}

func (hc *HealthChecker) backgroundCheck() {
	ticker := time.NewTicker(30 * time.Second)
	for range ticker.C {
		results := hc.checkAll()
		allUp := true
		for _, r := range results {
			if r.Status != "up" {
				allUp = false
				break
			}
		}
		snap := HealthSnapshot{Results: results, CheckedAt: time.Now(), AllUp: allUp}
		hc.mu.Lock()
		hc.history = append(hc.history, snap)
		if len(hc.history) > hc.maxHistory {
			hc.history = hc.history[len(hc.history)-hc.maxHistory:]
		}
		hc.mu.Unlock()
	}
}

func (hc *HealthChecker) History() []HealthSnapshot {
	hc.mu.RLock()
	defer hc.mu.RUnlock()
	out := make([]HealthSnapshot, len(hc.history))
	copy(out, hc.history)
	return out
}

// ---- サーキットブレーカー ----

type CircuitState string

const (
	StateClosed   CircuitState = "closed"
	StateOpen     CircuitState = "open"
	StateHalfOpen CircuitState = "half-open"
)

type cbEntry struct {
	failures   int
	successes  int
	openedAt   time.Time
	isOpen     bool
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

func (cb *CircuitBreaker) entry(upstream string) *cbEntry {
	e, ok := cb.entries[upstream]
	if !ok {
		e = &cbEntry{}
		cb.entries[upstream] = e
	}
	return e
}

func (cb *CircuitBreaker) Allow(upstream string) bool {
	cb.mu.Lock()
	defer cb.mu.Unlock()
	e := cb.entry(upstream)
	if !e.isOpen {
		return true
	}
	if time.Since(e.openedAt) >= cb.openTimeout {
		// half-open: リクエストを少数通して回復を確認する
		return e.successes < cb.halfOpenMax
	}
	return false
}

func (cb *CircuitBreaker) RecordSuccess(upstream string) {
	cb.mu.Lock()
	defer cb.mu.Unlock()
	e := cb.entry(upstream)
	if e.isOpen {
		e.successes++
		if e.successes >= cb.halfOpenMax {
			e.isOpen = false
			e.failures = 0
			e.successes = 0
			log.Printf("[CB] circuit closed for %s after recovery", upstream)
		}
	} else {
		e.failures = 0
	}
}

func (cb *CircuitBreaker) RecordFailure(upstream string) {
	cb.mu.Lock()
	defer cb.mu.Unlock()
	e := cb.entry(upstream)
	e.failures++
	if !e.isOpen && e.failures >= cb.threshold {
		e.isOpen = true
		e.openedAt = time.Now()
		e.successes = 0
		log.Printf("[CB] circuit opened for %s after %d consecutive failures", upstream, e.failures)
	}
}

func (cb *CircuitBreaker) State(upstream string) CircuitState {
	cb.mu.Lock()
	defer cb.mu.Unlock()
	e := cb.entry(upstream)
	if !e.isOpen {
		return StateClosed
	}
	if time.Since(e.openedAt) >= cb.openTimeout {
		return StateHalfOpen
	}
	return StateOpen
}

// Reset は指定されたアップストリームのサーキットブレーカーを強制的に閉じる。
// 障害復旧後のオペレーター手動介入用。
func (cb *CircuitBreaker) Reset(upstream string) {
	cb.mu.Lock()
	defer cb.mu.Unlock()
	if e, ok := cb.entries[upstream]; ok {
		e.isOpen = false
		e.failures = 0
		e.successes = 0
		log.Printf("[CB] circuit manually reset for %s", upstream)
	}
}

// ResetAll は全アップストリームのサーキットブレーカーをリセットする。
func (cb *CircuitBreaker) ResetAll() []string {
	cb.mu.Lock()
	defer cb.mu.Unlock()
	reset := make([]string, 0, len(cb.entries))
	for name, e := range cb.entries {
		e.isOpen = false
		e.failures = 0
		e.successes = 0
		reset = append(reset, name)
	}
	log.Printf("[CB] all circuits manually reset: %v", reset)
	return reset
}

func (cb *CircuitBreaker) States() map[string]CircuitState {
	cb.mu.Lock()
	defer cb.mu.Unlock()
	out := make(map[string]CircuitState, len(cb.entries))
	for name, e := range cb.entries {
		if !e.isOpen {
			out[name] = StateClosed
		} else if time.Since(e.openedAt) >= cb.openTimeout {
			out[name] = StateHalfOpen
		} else {
			out[name] = StateOpen
		}
	}
	return out
}

// ---- リバースプロキシ（CB・キャッシュ統合） ----

type upstreamProxy struct {
	name     string
	proxy    *httputil.ReverseProxy
	cb       *CircuitBreaker
	metrics  *Metrics
	cache    *ResponseCache
	timeout  time.Duration
	retryMax int
	baseURL  string
}

func newUpstreamProxy(name, target string, metrics *Metrics, cb *CircuitBreaker, cache *ResponseCache, timeout time.Duration, retryMax int) *upstreamProxy {
	u, err := url.Parse(target)
	if err != nil {
		log.Fatalf("invalid upstream URL %q: %v", target, err)
	}
	up := &upstreamProxy{
		name:     name,
		cb:       cb,
		metrics:  metrics,
		cache:    cache,
		timeout:  timeout,
		retryMax: retryMax,
		baseURL:  target,
	}
	p := httputil.NewSingleHostReverseProxy(u)
	p.ErrorHandler = func(w http.ResponseWriter, r *http.Request, err error) {
		metrics.upstreamErrors.Add(1)
		cb.RecordFailure(name)
		log.Printf("[PROXY ERROR] upstream=%s %s %s -> %v", name, r.Method, r.URL.Path, err)
		writeError(w, r, http.StatusBadGateway, ErrCodeUpstream, "upstream service unavailable", map[string]string{"upstream": name})
	}
	up.proxy = p
	return up
}

// retryGet は GET リクエストを指数バックオフで最大 retryMax 回リトライする。
// POST など状態変更を伴うメソッドはリトライしない。
func (up *upstreamProxy) retryGet(path string) (*http.Response, error) {
	client := &http.Client{Timeout: up.timeout}
	target := strings.TrimRight(up.baseURL, "/") + path

	var lastErr error
	delay := 100 * time.Millisecond
	for attempt := 0; attempt <= up.retryMax; attempt++ {
		if attempt > 0 {
			time.Sleep(delay)
			delay *= 2
			log.Printf("[RETRY] upstream=%s attempt=%d path=%s", up.name, attempt, path)
		}
		resp, err := client.Get(target)
		if err != nil {
			lastErr = err
			continue
		}
		if resp.StatusCode < 500 {
			return resp, nil
		}
		// 5xx はリトライ対象
		resp.Body.Close()
		lastErr = fmt.Errorf("upstream returned %d", resp.StatusCode)
	}
	return nil, fmt.Errorf("all %d attempts failed for %s: %w", up.retryMax+1, target, lastErr)
}

func (up *upstreamProxy) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	if !up.cb.Allow(up.name) {
		up.metrics.circuitOpen.Add(1)
		writeError(w, r, http.StatusServiceUnavailable, ErrCodeCircuitOpen,
			fmt.Sprintf("upstream %s is temporarily unavailable", up.name),
			map[string]string{"upstream": up.name, "state": string(up.cb.State(up.name))})
		return
	}

	if up.cache != nil {
		if entry, ok := up.cache.Get(r); ok {
			up.metrics.cacheHits.Add(1)
			w.Header().Set("Content-Type", entry.contentType)
			w.Header().Set("X-Cache", "HIT")
			w.WriteHeader(entry.status)
			w.Write(entry.body)
			return
		}
		up.metrics.cacheMisses.Add(1)
		w.Header().Set("X-Cache", "MISS")
	}

	// GET はリトライ可能なのでカスタムHTTPクライアントで処理し、それ以外は httputil.ReverseProxy に委譲する
	if r.Method == http.MethodGet && up.retryMax > 0 {
		up.serveWithRetry(w, r)
		return
	}

	ctx, cancel := context.WithTimeout(r.Context(), up.timeout)
	defer cancel()
	r2 := r.WithContext(ctx)

	crw := &capturingResponseWriter{ResponseWriter: w, status: http.StatusOK}
	up.proxy.ServeHTTP(crw, r2)

	if crw.status >= 500 {
		up.cb.RecordFailure(up.name)
	} else {
		up.cb.RecordSuccess(up.name)
		if up.cache != nil {
			up.cache.Set(r, crw.status, crw.Header().Get("Content-Type"), crw.body.Bytes())
		}
	}
}

func (up *upstreamProxy) serveWithRetry(w http.ResponseWriter, r *http.Request) {
	resp, err := up.retryGet(r.URL.RequestURI())
	if err != nil {
		up.metrics.upstreamErrors.Add(1)
		up.cb.RecordFailure(up.name)
		writeError(w, r, http.StatusBadGateway, ErrCodeUpstream, "upstream service unavailable",
			map[string]string{"upstream": up.name, "detail": err.Error()})
		return
	}
	defer resp.Body.Close()
	up.cb.RecordSuccess(up.name)

	for k, vs := range resp.Header {
		for _, v := range vs {
			w.Header().Add(k, v)
		}
	}
	body, _ := io.ReadAll(resp.Body)
	w.WriteHeader(resp.StatusCode)
	w.Write(body)

	if up.cache != nil {
		up.cache.Set(r, resp.StatusCode, resp.Header.Get("Content-Type"), body)
	}
}

// capturingResponseWriter はレスポンスボディをキャプチャしてキャッシュに保存するために使う
type capturingResponseWriter struct {
	http.ResponseWriter
	status int
	body   bytes.Buffer
}

func (c *capturingResponseWriter) WriteHeader(status int) {
	c.status = status
	c.ResponseWriter.WriteHeader(status)
}

func (c *capturingResponseWriter) Write(b []byte) (int, error) {
	c.body.Write(b)
	return c.ResponseWriter.Write(b)
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

func loggingMiddleware(metrics *Metrics, next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		rw := &responseWriter{ResponseWriter: w, status: http.StatusOK}
		next.ServeHTTP(rw, r)
		dur := time.Since(start)
		ms := float64(dur.Nanoseconds()) / 1e6
		rid := requestIDFromContext(r.Context())
		route := routePrefix(r.URL.Path)
		metrics.RecordRequest(route, rw.status, ms)
		log.Printf("[%s] %s %s status=%d latency=%s ip=%s bytes=%d",
			rid, r.Method, r.URL.Path, rw.status,
			dur.Round(time.Millisecond), clientIP(r), r.ContentLength)
	})
}

func routePrefix(path string) string {
	parts := strings.SplitN(strings.TrimPrefix(path, "/"), "/", 3)
	if len(parts) >= 2 {
		return "/" + parts[0] + "/" + parts[1]
	}
	return path
}

func rateLimitMiddleware(rlm *RateLimiterManager, metrics *Metrics, next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		ip := clientIP(r)
		route := routePrefix(r.URL.Path)
		if !rlm.Allow(route, ip) {
			metrics.rateLimitHits.Add(1)
			w.Header().Set("Retry-After", "1")
			writeError(w, r, http.StatusTooManyRequests, ErrCodeRateLimit, "rate limit exceeded",
				map[string]string{"route": route})
			return
		}
		next.ServeHTTP(w, r)
	})
}

func requestSizeLimitMiddleware(maxBytes int64, next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.ContentLength > maxBytes {
			writeError(w, r, http.StatusRequestEntityTooLarge, ErrCodeRequestTooLarge,
				fmt.Sprintf("request body exceeds limit of %d bytes", maxBytes),
				map[string]int64{"limit": maxBytes, "received": r.ContentLength})
			return
		}
		r.Body = http.MaxBytesReader(w, r.Body, maxBytes)
		next.ServeHTTP(w, r)
	})
}

// adminAuthMiddleware は /admin/* パスを Bearer token で保護する。
// ADMIN_TOKEN が空の場合は認証をスキップする（開発環境向け）。
func adminAuthMiddleware(token string, next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if !strings.HasPrefix(r.URL.Path, "/admin/") {
			next.ServeHTTP(w, r)
			return
		}
		if token == "" {
			next.ServeHTTP(w, r)
			return
		}
		auth := r.Header.Get("Authorization")
		const prefix = "Bearer "
		if !strings.HasPrefix(auth, prefix) || strings.TrimPrefix(auth, prefix) != token {
			w.Header().Set("WWW-Authenticate", `Bearer realm="meme-karuta-admin"`)
			writeError(w, r, http.StatusUnauthorized, "UNAUTHORIZED", "valid Bearer token required", nil)
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
				writeError(w, r, http.StatusInternalServerError, ErrCodeInternalError, "internal server error", nil)
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
		return strings.TrimSpace(strings.SplitN(ip, ",", 2)[0])
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

// ---- サーバー ----

type server struct {
	cfg           Config
	metrics       *Metrics
	healthChecker *HealthChecker
	rlManager     *RateLimiterManager
	cb            *CircuitBreaker
	cache         *ResponseCache
}

func newServer(cfg Config) *server {
	globalRL := newRateLimiter(cfg.RateLimit, cfg.RateBurst)
	metrics  := newMetrics()
	cb       := newCircuitBreaker(cfg.CBThreshold, cfg.CBOpenTimeout)
	cache    := newResponseCache(cfg.CacheTTL)
	return &server{
		cfg:           cfg,
		metrics:       metrics,
		healthChecker: newHealthChecker(cfg),
		rlManager:     newRateLimiterManager(globalRL, cfg.RouteRateLimits),
		cb:            cb,
		cache:         cache,
	}
}

func (s *server) buildMux() *http.ServeMux {
	t := s.cfg.UpstreamTimeouts
	rm := s.cfg.RetryMax
	// カードデータとシリアライザーはGETが多くキャッシュ対象、judge/shuffle はリクエストごとに異なる
	cardGenProxy    := newUpstreamProxy("card-gen",   s.cfg.CardGenURL,    s.metrics, s.cb, s.cache, t.CardGen,    rm)
	shuffleProxy    := newUpstreamProxy("shuffle",    s.cfg.ShuffleURL,    s.metrics, s.cb, nil,     t.Shuffle,    0)
	judgeProxy      := newUpstreamProxy("judge",      s.cfg.JudgeURL,      s.metrics, s.cb, nil,     t.Judge,      0)
	queueProxy      := newUpstreamProxy("queue",      s.cfg.QueueURL,      s.metrics, s.cb, nil,     t.Queue,      0)
	serializerProxy := newUpstreamProxy("serializer", s.cfg.SerializerURL, s.metrics, s.cb, s.cache, t.Serializer, rm)

	mux := http.NewServeMux()

	mux.Handle("/api/cards/",   stripPrefix("/api/cards", cardGenProxy))
	mux.Handle("/api/cards",    stripPrefix("/api/cards", cardGenProxy))
	mux.Handle("/api/shuffle/", stripPrefix("/api/shuffle", shuffleProxy))
	mux.Handle("/api/shuffle",  stripPrefix("/api/shuffle", shuffleProxy))
	mux.Handle("/api/judge/",   stripPrefix("/api/judge", judgeProxy))
	mux.Handle("/api/judge",    stripPrefix("/api/judge", judgeProxy))
	mux.Handle("/api/queue/",   stripPrefix("/api/queue", queueProxy))
	mux.Handle("/api/queue",    stripPrefix("/api/queue", queueProxy))
	mux.Handle("/api/serial/",  stripPrefix("/api/serial", serializerProxy))
	mux.Handle("/api/serial",   stripPrefix("/api/serial", serializerProxy))

	mux.HandleFunc("/health",           s.handleHealth)
	mux.HandleFunc("/health/upstreams", s.handleHealthUpstreams)
	mux.HandleFunc("/health/history",   s.handleHealthHistory)
	mux.HandleFunc("/metrics",          s.handleMetrics)
	mux.HandleFunc("/admin/status",     s.handleAdminStatus)
	mux.HandleFunc("/admin/cache/invalidate",   s.handleCacheInvalidate)
	mux.HandleFunc("/admin/circuit/reset",      s.handleCircuitReset)

	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/" {
			writeError(w, r, http.StatusNotFound, ErrCodeNotFound, "endpoint not found",
				map[string]string{"path": r.URL.Path})
			return
		}
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(map[string]string{
			"service": "meme-karuta-gateway",
			"version": "1.0.0",
		})
	})

	return mux
}

func (s *server) handleHealth(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string]any{
		"status":    "ok",
		"timestamp": time.Now().Format(time.RFC3339),
	})
}

func (s *server) handleHealthUpstreams(w http.ResponseWriter, r *http.Request) {
	results := s.healthChecker.checkAll()
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
		"timestamp": time.Now().Format(time.RFC3339),
	})
}

func (s *server) handleHealthHistory(w http.ResponseWriter, r *http.Request) {
	history := s.healthChecker.History()
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string]any{
		"count":   len(history),
		"history": history,
	})
}

func (s *server) handleMetrics(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(s.metrics.snapshot())
}

func (s *server) handleAdminStatus(w http.ResponseWriter, r *http.Request) {
	cbStates := s.cb.States()
	strStates := make(map[string]string, len(cbStates))
	for k, v := range cbStates {
		strStates[k] = string(v)
	}
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string]any{
		"metrics":         s.metrics.snapshot(),
		"circuit_breaker": strStates,
		"cache":           s.cache.Stats(),
		"timestamp":       time.Now().Format(time.RFC3339),
	})
}

func (s *server) handleCacheInvalidate(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeError(w, r, http.StatusMethodNotAllowed, ErrCodeMethodNotAllowed, "use POST", nil)
		return
	}
	prefix := r.URL.Query().Get("prefix")
	if prefix == "" {
		writeError(w, r, http.StatusBadRequest, ErrCodeBadRequest, "prefix query param required", nil)
		return
	}
	count := s.cache.Invalidate(prefix)
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string]any{
		"status":    "invalidated",
		"prefix":    prefix,
		"evicted":   count,
	})
}

func (s *server) handleCircuitReset(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeError(w, r, http.StatusMethodNotAllowed, ErrCodeMethodNotAllowed, "use POST", nil)
		return
	}
	upstream := r.URL.Query().Get("upstream")
	w.Header().Set("Content-Type", "application/json")
	if upstream == "" {
		reset := s.cb.ResetAll()
		json.NewEncoder(w).Encode(map[string]any{
			"status":  "reset",
			"targets": reset,
		})
		return
	}
	s.cb.Reset(upstream)
	json.NewEncoder(w).Encode(map[string]any{
		"status":   "reset",
		"upstream": upstream,
		"state":    string(s.cb.State(upstream)),
	})
}

// ---- メイン ----

func main() {
	cfg := loadConfig()
	if err := validateConfig(cfg); err != nil {
		log.Fatalf("invalid config: %v", err)
	}

	srv := newServer(cfg)
	mux := srv.buildMux()

	handler := recoveryMiddleware(
		requestIDMiddleware(
			loggingMiddleware(srv.metrics,
				rateLimitMiddleware(srv.rlManager, srv.metrics,
					requestSizeLimitMiddleware(cfg.MaxRequestBytes,
						adminAuthMiddleware(cfg.AdminToken,
							corsMiddleware(mux)))))))

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
