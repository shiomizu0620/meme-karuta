// ヘルスチェック用の軽量モジュール。
// /health は docker / nginx 上流のヘルスチェックから叩かれる。

use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Duration, Instant};

pub struct HealthState {
    started_at: Instant,
    ready: AtomicBool,
}

impl HealthState {
    pub fn new() -> Self {
        Self { started_at: Instant::now(), ready: AtomicBool::new(false) }
    }

    pub fn mark_ready(&self) { self.ready.store(true, Ordering::SeqCst); }
    pub fn is_ready(&self) -> bool { self.ready.load(Ordering::SeqCst) }
    pub fn uptime(&self) -> Duration { self.started_at.elapsed() }

    pub fn render_summary(&self) -> String {
        let status = if self.is_ready() { "ready" } else { "starting" };
        format!("status={} uptime_secs={}", status, self.uptime().as_secs())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn starts_not_ready() {
        assert!(!HealthState::new().is_ready());
    }

    #[test]
    fn mark_ready_toggles() {
        let h = HealthState::new();
        h.mark_ready();
        assert!(h.is_ready());
    }
}
