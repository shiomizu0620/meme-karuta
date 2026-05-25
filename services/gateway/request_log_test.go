package main

import (
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestAccessStatsRecords(t *testing.T) {
	s := &accessStats{}
	s.record(1_000_000, 200)
	s.record(2_000_000, 500)
	snap := s.Snapshot()
	if snap["requests_total"] != 2 || snap["errors_total"] != 1 {
		t.Errorf("got %v", snap)
	}
}

func TestAccessLogStatus(t *testing.T) {
	h := AccessLogMiddleware(&accessStats{}, http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusTeapot)
	}))
	w := httptest.NewRecorder()
	h.ServeHTTP(w, httptest.NewRequest("GET", "/", nil))
	if w.Code != http.StatusTeapot {
		t.Errorf("status=%d", w.Code)
	}
}
