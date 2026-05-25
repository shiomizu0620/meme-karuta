package main

import (
	"net/http"
	"sync/atomic"
	"time"
)

// ---- アクセスログ・メトリクス用ミドルウェア ----
//
// 各リクエストの所要時間とステータスコードを記録する。
// 監視ダッシュボードと突き合わせるため、req_id を構造化ログに乗せる前提。

type accessStats struct {
	total     atomic.Uint64
	errors    atomic.Uint64
	totalNS   atomic.Uint64
	maxNS     atomic.Uint64
}

func (s *accessStats) record(durationNS uint64, status int) {
	s.total.Add(1)
	s.totalNS.Add(durationNS)
	if status >= 500 {
		s.errors.Add(1)
	}
	for {
		cur := s.maxNS.Load()
		if durationNS <= cur {
			break
		}
		if s.maxNS.CompareAndSwap(cur, durationNS) {
			break
		}
	}
}

// Snapshot は集計済みのリクエスト統計を返す。/metrics エンドポイントが使う。
func (s *accessStats) Snapshot() map[string]float64 {
	total := s.total.Load()
	if total == 0 {
		return map[string]float64{"requests_total": 0, "errors_total": 0}
	}
	return map[string]float64{
		"requests_total": float64(total),
		"errors_total":   float64(s.errors.Load()),
		"avg_latency_ms": float64(s.totalNS.Load()) / float64(total) / 1e6,
		"max_latency_ms": float64(s.maxNS.Load()) / 1e6,
	}
}

type loggingWriter struct {
	http.ResponseWriter
	status int
	bytes  int
}

func (lw *loggingWriter) WriteHeader(code int) {
	lw.status = code
	lw.ResponseWriter.WriteHeader(code)
}

func (lw *loggingWriter) Write(b []byte) (int, error) {
	if lw.status == 0 {
		lw.status = http.StatusOK
	}
	n, err := lw.ResponseWriter.Write(b)
	lw.bytes += n
	return n, err
}

// AccessLogMiddleware は所要時間とステータスを accessStats に集計しつつ、
// 既存ロガーに 1 行のログを出力する。
func AccessLogMiddleware(stats *accessStats, next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		lw := &loggingWriter{ResponseWriter: w, status: http.StatusOK}
		next.ServeHTTP(lw, r)
		elapsed := time.Since(start)
		stats.record(uint64(elapsed.Nanoseconds()), lw.status)
	})
}
