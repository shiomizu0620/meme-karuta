package main

import (
	"encoding/json"
	"net"
	"net/http"
	"strings"
	"sync"
	"time"
)

// ---- レートリミッタ ----
//
// IP 単位のトークンバケット。AI モードの「次の札」連打や悪意ある連投で
// バックエンドを過負荷にしないため。メモリ上のみ・sweep で期限切れ削除。
// nginx 配下なので X-Forwarded-For を尊重する。

type tokenBucket struct {
	tokens     float64
	lastRefill time.Time
}

type RateLimiter struct {
	mu             sync.Mutex
	buckets        map[string]*tokenBucket
	capacity       float64
	refillPerSec   float64
	sweepInterval  time.Duration
	bucketTTL      time.Duration
	stopCh         chan struct{}
	trustedProxies []string
}

// NewRateLimiter は capacity トークン、毎秒 refillPerSec で補充される
// レートリミッタを返す。例: capacity=20, refillPerSec=5 → バースト 20 req、
// 平常時 5 req/sec まで許容。
func NewRateLimiter(capacity, refillPerSec float64) *RateLimiter {
	rl := &RateLimiter{
		buckets:       map[string]*tokenBucket{},
		capacity:      capacity,
		refillPerSec:  refillPerSec,
		sweepInterval: 60 * time.Second,
		bucketTTL:     10 * time.Minute,
		stopCh:        make(chan struct{}),
	}
	go rl.sweepLoop()
	return rl
}

// TrustProxies は X-Forwarded-For を信頼する送信元プロキシの CIDR/IP を登録する。
// 信頼できるプロキシ経由でない場合は X-Forwarded-For を無視し、RemoteAddr を使う。
func (rl *RateLimiter) TrustProxies(cidrs ...string) {
	rl.trustedProxies = append(rl.trustedProxies, cidrs...)
}

// Allow は与えられた key (通常は IP) に対してトークンを 1 つ消費しようと試みる。
// 残量があれば true、無ければ false を返す。
func (rl *RateLimiter) Allow(key string) bool {
	rl.mu.Lock()
	defer rl.mu.Unlock()

	now := time.Now()
	b, ok := rl.buckets[key]
	if !ok {
		b = &tokenBucket{tokens: rl.capacity, lastRefill: now}
		rl.buckets[key] = b
	}

	elapsed := now.Sub(b.lastRefill).Seconds()
	b.tokens += elapsed * rl.refillPerSec
	if b.tokens > rl.capacity {
		b.tokens = rl.capacity
	}
	b.lastRefill = now

	if b.tokens < 1.0 {
		return false
	}
	b.tokens -= 1.0
	return true
}

// Middleware は HTTP ハンドラを RateLimiter で包む。
// 制限超過時は 429 Too Many Requests と Retry-After ヘッダを返す。
func (rl *RateLimiter) Middleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		key := rl.clientKey(r)
		if !rl.Allow(key) {
			retryAfter := rl.retryAfterSeconds()
			w.Header().Set("Retry-After", retryAfter)
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(http.StatusTooManyRequests)
			_ = json.NewEncoder(w).Encode(map[string]string{
				"code":        "rate_limited",
				"message":     "too many requests",
				"retry_after": retryAfter,
			})
			return
		}
		next.ServeHTTP(w, r)
	})
}

// Stop は内部の sweep goroutine を止める。シャットダウン時に呼ぶ。
func (rl *RateLimiter) Stop() {
	close(rl.stopCh)
}

// Stats は監視用の現在のバケット状況を返す。
func (rl *RateLimiter) Stats() map[string]float64 {
	rl.mu.Lock()
	defer rl.mu.Unlock()
	out := make(map[string]float64, len(rl.buckets))
	for k, b := range rl.buckets {
		out[k] = b.tokens
	}
	return out
}

// ---- 内部ヘルパ ----

func (rl *RateLimiter) clientKey(r *http.Request) string {
	remote := r.RemoteAddr
	if host, _, err := net.SplitHostPort(remote); err == nil {
		remote = host
	}

	if !rl.isTrustedProxy(remote) {
		return remote
	}

	xff := r.Header.Get("X-Forwarded-For")
	if xff == "" {
		return remote
	}
	parts := strings.Split(xff, ",")
	first := strings.TrimSpace(parts[0])
	if first == "" {
		return remote
	}
	return first
}

func (rl *RateLimiter) isTrustedProxy(ip string) bool {
	if len(rl.trustedProxies) == 0 {
		return false
	}
	parsed := net.ParseIP(ip)
	if parsed == nil {
		return false
	}
	for _, entry := range rl.trustedProxies {
		if !strings.Contains(entry, "/") {
			if entry == ip {
				return true
			}
			continue
		}
		_, network, err := net.ParseCIDR(entry)
		if err != nil {
			continue
		}
		if network.Contains(parsed) {
			return true
		}
	}
	return false
}

func (rl *RateLimiter) retryAfterSeconds() string {
	if rl.refillPerSec <= 0 {
		return "60"
	}
	seconds := 1.0 / rl.refillPerSec
	if seconds < 1 {
		seconds = 1
	}
	return strconvFloat(seconds)
}

func strconvFloat(f float64) string {
	// 単純に整数秒で返す（細かい小数は意味が薄いので切り上げ）
	intVal := int64(f)
	if float64(intVal) < f {
		intVal++
	}
	if intVal < 1 {
		intVal = 1
	}
	return itoaInt64(intVal)
}

func itoaInt64(n int64) string {
	if n == 0 {
		return "0"
	}
	neg := n < 0
	if neg {
		n = -n
	}
	var buf [20]byte
	i := len(buf)
	for n > 0 {
		i--
		buf[i] = byte('0' + n%10)
		n /= 10
	}
	if neg {
		i--
		buf[i] = '-'
	}
	return string(buf[i:])
}

func (rl *RateLimiter) sweepLoop() {
	ticker := time.NewTicker(rl.sweepInterval)
	defer ticker.Stop()
	for {
		select {
		case <-rl.stopCh:
			return
		case now := <-ticker.C:
			rl.sweep(now)
		}
	}
}

func (rl *RateLimiter) sweep(now time.Time) {
	rl.mu.Lock()
	defer rl.mu.Unlock()
	for k, b := range rl.buckets {
		if now.Sub(b.lastRefill) > rl.bucketTTL {
			delete(rl.buckets, k)
		}
	}
}
