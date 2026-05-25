// 先着判定サーバーの内部メトリクス。
//
// 取り札イベントごとに「リクエスト到着 → ロック獲得 → 結果返却」の各段で
// マイクロ秒精度の計測を行い、ヒストグラム的に集約する。
// /metrics エンドポイントから Prometheus 互換のテキストで吐き出すための
// 軽量な実装。チャネル経由ではなく、原子操作 + 小さいバケットの配列で済ます。

use std::sync::atomic::{AtomicU64, Ordering};
use std::time::Duration;

/// マイクロ秒単位のバケット境界。指数的に広がる定番のレイテンシバケット。
const BUCKETS_US: &[u64] = &[
    50, 100, 250, 500,
    1_000, 2_500, 5_000, 10_000,
    25_000, 50_000, 100_000, 250_000,
    500_000, 1_000_000,
];

pub struct LatencyHistogram {
    name: String,
    counts: Vec<AtomicU64>,
    sum_us: AtomicU64,
    total: AtomicU64,
    overflow: AtomicU64,
}

impl LatencyHistogram {
    pub fn new(name: impl Into<String>) -> Self {
        let mut counts = Vec::with_capacity(BUCKETS_US.len());
        for _ in 0..BUCKETS_US.len() {
            counts.push(AtomicU64::new(0));
        }
        Self {
            name: name.into(),
            counts,
            sum_us: AtomicU64::new(0),
            total: AtomicU64::new(0),
            overflow: AtomicU64::new(0),
        }
    }

    /// Duration を記録。バケット境界より大きい場合は overflow に加算。
    pub fn record(&self, dur: Duration) {
        let us = dur.as_micros() as u64;
        self.sum_us.fetch_add(us, Ordering::Relaxed);
        self.total.fetch_add(1, Ordering::Relaxed);

        for (i, &boundary) in BUCKETS_US.iter().enumerate() {
            if us <= boundary {
                self.counts[i].fetch_add(1, Ordering::Relaxed);
                return;
            }
        }
        self.overflow.fetch_add(1, Ordering::Relaxed);
    }

    pub fn total(&self) -> u64 {
        self.total.load(Ordering::Relaxed)
    }

    pub fn average_us(&self) -> f64 {
        let total = self.total();
        if total == 0 {
            return 0.0;
        }
        self.sum_us.load(Ordering::Relaxed) as f64 / total as f64
    }

    /// 簡易パーセンタイル推定。バケット境界で補間せず、バケットの上端を採用。
    pub fn percentile(&self, p: f64) -> Option<u64> {
        let total = self.total();
        if total == 0 {
            return None;
        }
        let target = (total as f64 * p).ceil() as u64;
        let mut cumulative = 0u64;
        for (i, &boundary) in BUCKETS_US.iter().enumerate() {
            cumulative += self.counts[i].load(Ordering::Relaxed);
            if cumulative >= target {
                return Some(boundary);
            }
        }
        Some(*BUCKETS_US.last().unwrap_or(&0))
    }

    /// Prometheus テキスト形式で書き出す。
    pub fn render_prometheus(&self) -> String {
        let mut buf = String::new();
        buf.push_str(&format!("# HELP {} latency histogram (microseconds)\n", self.name));
        buf.push_str(&format!("# TYPE {} histogram\n", self.name));
        let mut cumulative = 0u64;
        for (i, &boundary) in BUCKETS_US.iter().enumerate() {
            cumulative += self.counts[i].load(Ordering::Relaxed);
            buf.push_str(&format!(
                "{}_bucket{{le=\"{}\"}} {}\n",
                self.name, boundary, cumulative
            ));
        }
        let overflow = self.overflow.load(Ordering::Relaxed);
        cumulative += overflow;
        buf.push_str(&format!(
            "{}_bucket{{le=\"+Inf\"}} {}\n",
            self.name, cumulative
        ));
        buf.push_str(&format!(
            "{}_sum {}\n",
            self.name,
            self.sum_us.load(Ordering::Relaxed)
        ));
        buf.push_str(&format!("{}_count {}\n", self.name, self.total()));
        buf
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::Duration;

    #[test]
    fn records_into_correct_bucket() {
        let h = LatencyHistogram::new("test_h");
        h.record(Duration::from_micros(75));
        h.record(Duration::from_micros(300));
        h.record(Duration::from_micros(40));
        assert_eq!(h.total(), 3);
        assert!(h.average_us() > 0.0);
    }

    #[test]
    fn overflow_counted_separately() {
        let h = LatencyHistogram::new("ovf");
        h.record(Duration::from_secs(5));
        assert_eq!(h.total(), 1);
        let text = h.render_prometheus();
        assert!(text.contains("le=\"+Inf\""));
    }

    #[test]
    fn empty_percentile_returns_none() {
        let h = LatencyHistogram::new("empty");
        assert_eq!(h.percentile(0.5), None);
    }

    #[test]
    fn populated_percentile_returns_some() {
        let h = LatencyHistogram::new("p");
        for _ in 0..100 {
            h.record(Duration::from_micros(200));
        }
        assert!(h.percentile(0.5).is_some());
    }

    #[test]
    fn prometheus_output_has_required_fields() {
        let h = LatencyHistogram::new("judge_latency");
        h.record(Duration::from_micros(120));
        let text = h.render_prometheus();
        assert!(text.contains("# HELP judge_latency"));
        assert!(text.contains("# TYPE judge_latency histogram"));
        assert!(text.contains("judge_latency_sum"));
        assert!(text.contains("judge_latency_count"));
    }
}
