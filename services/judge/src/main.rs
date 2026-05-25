use actix_web::{middleware, web, App, HttpResponse, HttpServer};
use chrono::{DateTime, Duration, Utc};
use dashmap::DashMap;
use serde::{Deserialize, Serialize};
use std::sync::Arc;
use std::time::SystemTime;

mod metrics;
mod validation;
mod health;

// ---- リクエスト / レスポンス型 ----

#[derive(Deserialize, Debug, Clone)]
struct JudgeRequest {
    room_id:   String,
    card_id:   u32,
    player_id: String,
    timestamp: DateTime<Utc>,
}

#[derive(Serialize, Deserialize, Debug, Clone)]
struct JudgeResponse {
    result:    String,
    room_id:   String,
    card_id:   u32,
    player_id: String,
    timestamp: DateTime<Utc>,
}

#[derive(Deserialize, Debug)]
struct BatchJudgeRequest {
    items: Vec<JudgeRequest>,
}

#[derive(Serialize, Debug)]
struct BatchJudgeResponse {
    results: Vec<JudgeResponse>,
}

#[derive(Serialize, Debug)]
struct RoomStats {
    room_id:         String,
    cards_judged:    usize,
    player_scores:   std::collections::HashMap<String, u32>,
    avg_response_ms: f64,
    fastest_player:  Option<String>,
    fastest_ms:      Option<i64>,
}

#[derive(Serialize, Debug)]
struct HealthResponse {
    status:      String,
    rooms_active: usize,
    uptime_secs: u64,
}

// ---- プレイヤー単位レート制限 ----

#[derive(Debug)]
struct PlayerRateLimiter {
    last_request: DashMap<String, DateTime<Utc>>,
    min_interval_ms: i64,
    request_counts: DashMap<String, u32>,
    max_per_minute: u32,
}

impl PlayerRateLimiter {
    fn new(min_interval_ms: i64, max_per_minute: u32) -> Self {
        Self {
            last_request: DashMap::new(),
            min_interval_ms,
            request_counts: DashMap::new(),
            max_per_minute,
        }
    }

    fn check(&self, player_id: &str) -> Result<(), &'static str> {
        let now = Utc::now();
        if let Some(prev) = self.last_request.get(player_id) {
            let delta = (now - *prev).num_milliseconds();
            if delta < self.min_interval_ms {
                return Err("rate limit: too fast (one judge per 100ms)");
            }
        }
        self.last_request.insert(player_id.to_string(), now);

        let mut count = self.request_counts.entry(player_id.to_string()).or_insert(0);
        *count += 1;
        if *count > self.max_per_minute {
            return Err("rate limit: per-minute cap exceeded");
        }
        Ok(())
    }

    fn reset_minute_counters(&self) {
        self.request_counts.clear();
    }
}

// ---- 冪等性キー ----

#[derive(Debug)]
struct IdempotencyCache {
    seen: DashMap<String, DateTime<Utc>>,
    ttl_secs: i64,
}

impl IdempotencyCache {
    fn new(ttl_secs: i64) -> Self {
        Self { seen: DashMap::new(), ttl_secs }
    }

    fn check_and_insert(&self, key: &str) -> bool {
        let now = Utc::now();
        if let Some(prev) = self.seen.get(key) {
            if (now - *prev).num_seconds() < self.ttl_secs {
                return false;
            }
        }
        self.seen.insert(key.to_string(), now);
        true
    }

    fn prune(&self) {
        let cutoff = Utc::now() - Duration::seconds(self.ttl_secs);
        self.seen.retain(|_, ts| *ts > cutoff);
    }
}

// ---- アプリケーション状態 ----

struct AppState {
    // (room_id, card_id) → winner player_id
    winners: DashMap<(String, u32), String>,

    // ルームごとのスコア: room_id → (player_id → score)
    scores: DashMap<String, DashMap<String, u32>>,

    // 取り札イベントログ: room_id → Vec<(card_id, player_id, response_ms)>
    history: DashMap<String, Vec<(u32, String, i64)>>,

    // 先着争い時のタイムスタンプ記録: (room_id, card_id) → 読み上げ開始時刻
    read_at: DashMap<(String, u32), DateTime<Utc>>,

    // サーバー起動時刻
    started_at: DateTime<Utc>,
}

impl AppState {
    fn new() -> Self {
        AppState {
            winners:    DashMap::new(),
            scores:     DashMap::new(),
            history:    DashMap::new(),
            read_at:    DashMap::new(),
            started_at: Utc::now(),
        }
    }
}

// ---- バリデーション ----

fn validate_judge_request(req: &JudgeRequest) -> Result<(), &'static str> {
    if req.room_id.trim().is_empty() {
        return Err("room_id must not be empty");
    }
    if req.room_id.len() > 64 {
        return Err("room_id too long");
    }
    if req.player_id.trim().is_empty() {
        return Err("player_id must not be empty");
    }
    if req.player_id.len() > 32 {
        return Err("player_id too long");
    }
    let age = Utc::now() - req.timestamp;
    if age > Duration::minutes(5) {
        return Err("timestamp too old");
    }
    if age < Duration::seconds(-30) {
        return Err("timestamp is in the future");
    }
    Ok(())
}

// ---- ハンドラ: 先着判定 ----

async fn judge(
    state: web::Data<Arc<AppState>>,
    body: web::Json<JudgeRequest>,
) -> HttpResponse {
    if let Err(e) = validate_judge_request(&body) {
        return HttpResponse::BadRequest().json(serde_json::json!({ "error": e }));
    }

    let key    = (body.room_id.clone(), body.card_id);
    let entry  = state.winners.entry(key.clone()).or_insert_with(|| body.player_id.clone());
    let winner = entry.value().clone();
    drop(entry);

    let is_winner = winner == body.player_id;

    // 応答時間を記録
    let response_ms = if let Some(read_ts) = state.read_at.get(&key) {
        (body.timestamp - *read_ts).num_milliseconds().max(0)
    } else {
        0
    };

    // スコアとヒストリを更新
    if is_winner {
        let room_scores = state.scores.entry(body.room_id.clone()).or_default();
        let mut player_score = room_scores.entry(body.player_id.clone()).or_insert(0);
        *player_score += 1;

        let mut room_history = state.history.entry(body.room_id.clone()).or_default();
        room_history.push((body.card_id, body.player_id.clone(), response_ms));
    }

    let response = JudgeResponse {
        result:    if is_winner { "won".to_string() } else { "lost".to_string() },
        room_id:   body.room_id.clone(),
        card_id:   body.card_id,
        player_id: body.player_id.clone(),
        timestamp: body.timestamp,
    };

    if is_winner {
        HttpResponse::Ok().json(response)
    } else {
        HttpResponse::Conflict().json(response)
    }
}

// ---- ハンドラ: バッチ判定 ----

async fn batch_judge(
    state: web::Data<Arc<AppState>>,
    body: web::Json<BatchJudgeRequest>,
) -> HttpResponse {
    if body.items.len() > 100 {
        return HttpResponse::BadRequest().json(
            serde_json::json!({ "error": "batch size must be <= 100" })
        );
    }

    let mut results = Vec::with_capacity(body.items.len());
    for item in &body.items {
        if let Err(e) = validate_judge_request(item) {
            return HttpResponse::BadRequest().json(serde_json::json!({ "error": format!("{}: {}", item.card_id, e) }));
        }

        let key   = (item.room_id.clone(), item.card_id);
        let entry = state.winners.entry(key).or_insert_with(|| item.player_id.clone());
        let is_winner = *entry == item.player_id;
        drop(entry);

        results.push(JudgeResponse {
            result:    if is_winner { "won".to_string() } else { "lost".to_string() },
            room_id:   item.room_id.clone(),
            card_id:   item.card_id,
            player_id: item.player_id.clone(),
            timestamp: item.timestamp,
        });
    }

    HttpResponse::Ok().json(BatchJudgeResponse { results })
}

// ---- ハンドラ: 読み上げ開始時刻の登録 ----

#[derive(Deserialize)]
struct MarkReadRequest {
    room_id: String,
    card_id: u32,
}

async fn mark_card_read(
    state: web::Data<Arc<AppState>>,
    body: web::Json<MarkReadRequest>,
) -> HttpResponse {
    let key = (body.room_id.clone(), body.card_id);
    state.read_at.insert(key, Utc::now());
    HttpResponse::Ok().json(serde_json::json!({ "status": "ok" }))
}

// ---- ハンドラ: ルームリセット ----

async fn reset_room(
    state: web::Data<Arc<AppState>>,
    path: web::Path<String>,
) -> HttpResponse {
    let room_id = path.into_inner();
    if room_id.trim().is_empty() {
        return HttpResponse::BadRequest().json(serde_json::json!({ "error": "room_id required" }));
    }

    state.winners.retain(|(rid, _), _| rid != &room_id);
    state.scores.remove(&room_id);
    state.history.remove(&room_id);
    state.read_at.retain(|(rid, _), _| rid != &room_id);

    HttpResponse::Ok().json(serde_json::json!({ "message": "reset ok", "room_id": room_id }))
}

// ---- ハンドラ: ルーム統計 ----

async fn get_room_stats(
    state: web::Data<Arc<AppState>>,
    path: web::Path<String>,
) -> HttpResponse {
    let room_id = path.into_inner();

    let cards_judged = state.history.get(&room_id).map(|h| h.len()).unwrap_or(0);

    let player_scores: std::collections::HashMap<String, u32> = state
        .scores
        .get(&room_id)
        .map(|m| m.iter().map(|e| (e.key().clone(), *e.value())).collect())
        .unwrap_or_default();

    let (avg_response_ms, fastest_player, fastest_ms) = state
        .history
        .get(&room_id)
        .map(|h| {
            if h.is_empty() {
                (0.0, None, None)
            } else {
                let total: i64 = h.iter().map(|(_, _, ms)| ms).sum();
                let avg = total as f64 / h.len() as f64;
                let fastest = h.iter().min_by_key(|(_, _, ms)| ms).unwrap();
                (avg, Some(fastest.1.clone()), Some(fastest.2))
            }
        })
        .unwrap_or((0.0, None, None));

    let stats = RoomStats {
        room_id,
        cards_judged,
        player_scores,
        avg_response_ms,
        fastest_player,
        fastest_ms,
    };

    HttpResponse::Ok().json(stats)
}

// ---- ハンドラ: ヘルス ----

async fn health(state: web::Data<Arc<AppState>>) -> HttpResponse {
    let uptime = Utc::now() - state.started_at;
    HttpResponse::Ok().json(HealthResponse {
        status:       "ok".to_string(),
        rooms_active: state.scores.len(),
        uptime_secs:  uptime.num_seconds().max(0) as u64,
    })
}

// ---- メトリクス ----

use std::sync::atomic::{AtomicU64, Ordering};

#[derive(Debug, Default)]
struct Metrics {
    judges_total:       AtomicU64,
    judges_won:         AtomicU64,
    judges_lost:        AtomicU64,
    judges_rejected:    AtomicU64,
    response_ms_sum:    AtomicU64,
    response_ms_count:  AtomicU64,
    cache_hits:         AtomicU64,
    cache_misses:       AtomicU64,
}

impl Metrics {
    fn record_judge(&self, won: bool, response_ms: i64) {
        self.judges_total.fetch_add(1, Ordering::Relaxed);
        if won {
            self.judges_won.fetch_add(1, Ordering::Relaxed);
        } else {
            self.judges_lost.fetch_add(1, Ordering::Relaxed);
        }
        if response_ms >= 0 {
            self.response_ms_sum.fetch_add(response_ms as u64, Ordering::Relaxed);
            self.response_ms_count.fetch_add(1, Ordering::Relaxed);
        }
    }

    fn record_rejected(&self) {
        self.judges_rejected.fetch_add(1, Ordering::Relaxed);
    }

    fn record_cache(&self, hit: bool) {
        if hit { self.cache_hits.fetch_add(1, Ordering::Relaxed); }
        else   { self.cache_misses.fetch_add(1, Ordering::Relaxed); }
    }

    fn avg_response_ms(&self) -> f64 {
        let n = self.response_ms_count.load(Ordering::Relaxed);
        if n == 0 { return 0.0; }
        self.response_ms_sum.load(Ordering::Relaxed) as f64 / n as f64
    }

    fn cache_hit_ratio(&self) -> f64 {
        let h = self.cache_hits.load(Ordering::Relaxed);
        let m = self.cache_misses.load(Ordering::Relaxed);
        let total = h + m;
        if total == 0 { return 0.0; }
        h as f64 / total as f64
    }

    fn render_prometheus(&self) -> String {
        let mut s = String::new();
        s.push_str("# HELP judge_judges_total Total judge calls\n");
        s.push_str("# TYPE judge_judges_total counter\n");
        s.push_str(&format!("judge_judges_total {}\n", self.judges_total.load(Ordering::Relaxed)));
        s.push_str("# HELP judge_judges_won_total Calls that resulted in a win\n");
        s.push_str("# TYPE judge_judges_won_total counter\n");
        s.push_str(&format!("judge_judges_won_total {}\n", self.judges_won.load(Ordering::Relaxed)));
        s.push_str("# HELP judge_judges_lost_total Calls that resulted in a loss\n");
        s.push_str("# TYPE judge_judges_lost_total counter\n");
        s.push_str(&format!("judge_judges_lost_total {}\n", self.judges_lost.load(Ordering::Relaxed)));
        s.push_str("# HELP judge_judges_rejected_total Calls rejected by validation/rate limit\n");
        s.push_str("# TYPE judge_judges_rejected_total counter\n");
        s.push_str(&format!("judge_judges_rejected_total {}\n", self.judges_rejected.load(Ordering::Relaxed)));
        s.push_str("# HELP judge_response_avg_ms Average response time in ms\n");
        s.push_str("# TYPE judge_response_avg_ms gauge\n");
        s.push_str(&format!("judge_response_avg_ms {:.3}\n", self.avg_response_ms()));
        s.push_str("# HELP judge_cache_hit_ratio Idempotency cache hit ratio (0..1)\n");
        s.push_str("# TYPE judge_cache_hit_ratio gauge\n");
        s.push_str(&format!("judge_cache_hit_ratio {:.3}\n", self.cache_hit_ratio()));
        s
    }
}

async fn metrics_handler(metrics: web::Data<Arc<Metrics>>) -> HttpResponse {
    HttpResponse::Ok()
        .content_type("text/plain; version=0.0.4; charset=utf-8")
        .body(metrics.render_prometheus())
}

// ---- ハンドラ: ルームのリーダーボード ----
// 単一ルーム内のプレイヤー別獲得枚数を多い順に並べ、勝率や平均応答時間も付与する。

#[derive(Serialize, Debug)]
struct LeaderboardRow {
    rank:               u32,
    player_id:          String,
    score:              u32,
    avg_response_ms:    Option<f64>,
    fastest_ms:         Option<i64>,
    win_rate:           f64,
}

async fn get_leaderboard(
    state: web::Data<Arc<AppState>>,
    path: web::Path<String>,
) -> HttpResponse {
    let room_id = path.into_inner();

    let scores: Vec<(String, u32)> = state
        .scores
        .get(&room_id)
        .map(|m| m.iter().map(|e| (e.key().clone(), *e.value())).collect())
        .unwrap_or_default();

    let total_cards: u32 = scores.iter().map(|(_, v)| v).sum();

    let history = state.history.get(&room_id);

    let mut rows: Vec<LeaderboardRow> = scores
        .into_iter()
        .map(|(player_id, score)| {
            let (avg, fastest) = if let Some(h) = history.as_ref() {
                let mine: Vec<i64> = h
                    .iter()
                    .filter_map(|(_, p, ms)| if *p == player_id { Some(*ms) } else { None })
                    .collect();
                if mine.is_empty() {
                    (None, None)
                } else {
                    let sum: i64 = mine.iter().sum();
                    let avg = sum as f64 / mine.len() as f64;
                    let fastest = *mine.iter().min().unwrap();
                    (Some(avg), Some(fastest))
                }
            } else {
                (None, None)
            };
            let win_rate = if total_cards == 0 {
                0.0
            } else {
                score as f64 / total_cards as f64
            };
            LeaderboardRow {
                rank: 0, // 後で sort して採番
                player_id,
                score,
                avg_response_ms: avg,
                fastest_ms: fastest,
                win_rate,
            }
        })
        .collect();

    rows.sort_by(|a, b| b.score.cmp(&a.score)
        .then_with(|| a.avg_response_ms.unwrap_or(f64::INFINITY)
            .partial_cmp(&b.avg_response_ms.unwrap_or(f64::INFINITY))
            .unwrap_or(std::cmp::Ordering::Equal)));

    for (i, row) in rows.iter_mut().enumerate() {
        row.rank = (i as u32) + 1;
    }

    HttpResponse::Ok().json(serde_json::json!({
        "room_id": room_id,
        "total_cards": total_cards,
        "rows": rows,
    }))
}

// ---- ハンドラ: 直近の取り札イベント ----

#[derive(Serialize, Debug)]
struct RecentEvent {
    card_id:     u32,
    player_id:   String,
    response_ms: i64,
}

async fn recent_takes(
    state: web::Data<Arc<AppState>>,
    path: web::Path<String>,
    query: web::Query<std::collections::HashMap<String, String>>,
) -> HttpResponse {
    let room_id = path.into_inner();
    let limit: usize = query
        .get("limit")
        .and_then(|v| v.parse().ok())
        .unwrap_or(20)
        .min(200);

    let events: Vec<RecentEvent> = state
        .history
        .get(&room_id)
        .map(|h| {
            h.iter()
                .rev()
                .take(limit)
                .map(|(card_id, player_id, ms)| RecentEvent {
                    card_id:     *card_id,
                    player_id:   player_id.clone(),
                    response_ms: *ms,
                })
                .collect()
        })
        .unwrap_or_default();

    HttpResponse::Ok().json(events)
}

// ---- テスト ----

#[cfg(test)]
mod tests {
    use super::*;
    use actix_web::{http::StatusCode, test, App};

    fn make_state() -> Arc<AppState> {
        Arc::new(AppState::new())
    }

    fn judge_body(room_id: &str, card_id: u32, player_id: &str) -> serde_json::Value {
        serde_json::json!({
            "room_id":   room_id,
            "card_id":   card_id,
            "player_id": player_id,
            "timestamp": Utc::now().to_rfc3339()
        })
    }

    #[actix_web::test]
    async fn test_first_wins_second_loses() {
        let state = make_state();
        let app = test::init_service(
            App::new()
                .app_data(web::Data::new(Arc::clone(&state)))
                .route("/judge", web::post().to(judge)),
        ).await;

        let req = test::TestRequest::post().uri("/judge")
            .set_json(judge_body("room1", 1, "player_a")).to_request();
        let resp = test::call_service(&app, req).await;
        assert_eq!(resp.status(), StatusCode::OK);
        let b: JudgeResponse = test::read_body_json(resp).await;
        assert_eq!(b.result, "won");

        let req = test::TestRequest::post().uri("/judge")
            .set_json(judge_body("room1", 1, "player_b")).to_request();
        let resp = test::call_service(&app, req).await;
        assert_eq!(resp.status(), StatusCode::CONFLICT);
        let b: JudgeResponse = test::read_body_json(resp).await;
        assert_eq!(b.result, "lost");
    }

    #[actix_web::test]
    async fn test_different_rooms_are_independent() {
        let state = make_state();
        let app = test::init_service(
            App::new()
                .app_data(web::Data::new(Arc::clone(&state)))
                .route("/judge", web::post().to(judge)),
        ).await;

        let req = test::TestRequest::post().uri("/judge")
            .set_json(judge_body("room1", 1, "player_a")).to_request();
        let resp = test::call_service(&app, req).await;
        assert_eq!(resp.status(), StatusCode::OK);

        let req = test::TestRequest::post().uri("/judge")
            .set_json(judge_body("room2", 1, "player_b")).to_request();
        let resp = test::call_service(&app, req).await;
        assert_eq!(resp.status(), StatusCode::OK);
        let b: JudgeResponse = test::read_body_json(resp).await;
        assert_eq!(b.result, "won");
    }

    #[actix_web::test]
    async fn test_reset_clears_winners() {
        let state = make_state();
        let app = test::init_service(
            App::new()
                .app_data(web::Data::new(Arc::clone(&state)))
                .route("/judge", web::post().to(judge))
                .route("/reset/{room_id}", web::post().to(reset_room)),
        ).await;

        let req = test::TestRequest::post().uri("/judge")
            .set_json(judge_body("room1", 5, "player_a")).to_request();
        test::call_service(&app, req).await;

        let req = test::TestRequest::post().uri("/reset/room1").to_request();
        let resp = test::call_service(&app, req).await;
        assert_eq!(resp.status(), StatusCode::OK);

        let req = test::TestRequest::post().uri("/judge")
            .set_json(judge_body("room1", 5, "player_b")).to_request();
        let resp = test::call_service(&app, req).await;
        assert_eq!(resp.status(), StatusCode::OK);
        let b: JudgeResponse = test::read_body_json(resp).await;
        assert_eq!(b.result, "won");
    }

    #[actix_web::test]
    async fn test_same_player_idempotent() {
        let state = make_state();
        let app = test::init_service(
            App::new()
                .app_data(web::Data::new(Arc::clone(&state)))
                .route("/judge", web::post().to(judge)),
        ).await;

        for _ in 0..3 {
            let req = test::TestRequest::post().uri("/judge")
                .set_json(judge_body("room1", 7, "player_a")).to_request();
            let resp = test::call_service(&app, req).await;
            assert_eq!(resp.status(), StatusCode::OK, "same player should always win their card");
        }
    }

    #[actix_web::test]
    async fn test_validation_rejects_empty_room_id() {
        let state = make_state();
        let app = test::init_service(
            App::new()
                .app_data(web::Data::new(Arc::clone(&state)))
                .route("/judge", web::post().to(judge)),
        ).await;

        let req = test::TestRequest::post().uri("/judge")
            .set_json(judge_body("", 1, "player_a")).to_request();
        let resp = test::call_service(&app, req).await;
        assert_eq!(resp.status(), StatusCode::BAD_REQUEST);
    }

    #[actix_web::test]
    async fn test_rate_limiter_blocks_rapid_requests() {
        let rl = PlayerRateLimiter::new(100, 100);
        assert!(rl.check("p1").is_ok());
        let err = rl.check("p1");
        assert!(err.is_err(), "second immediate request should be rate limited");
    }

    #[actix_web::test]
    async fn test_idempotency_cache_detects_duplicates() {
        let cache = IdempotencyCache::new(60);
        assert!(cache.check_and_insert("req-1"));
        assert!(!cache.check_and_insert("req-1"), "duplicate key should be rejected");
        assert!(cache.check_and_insert("req-2"));
    }

    #[actix_web::test]
    async fn test_metrics_render_includes_expected_lines() {
        let m = Metrics::default();
        m.record_judge(true, 12);
        m.record_judge(false, 34);
        m.record_rejected();
        m.record_cache(true);
        m.record_cache(false);
        let out = m.render_prometheus();
        for needle in [
            "judge_judges_total 2",
            "judge_judges_won_total 1",
            "judge_judges_lost_total 1",
            "judge_judges_rejected_total 1",
            "judge_response_avg_ms",
            "judge_cache_hit_ratio",
        ] {
            assert!(out.contains(needle), "missing {needle} in metrics output:\n{out}");
        }
    }

    #[actix_web::test]
    async fn test_rate_limiter_allows_after_interval() {
        let rl = PlayerRateLimiter::new(10, 100);
        assert!(rl.check("p2").is_ok());
        std::thread::sleep(std::time::Duration::from_millis(15));
        assert!(rl.check("p2").is_ok(), "should allow after interval");
    }

    #[actix_web::test]
    async fn test_rate_limiter_minute_cap() {
        let rl = PlayerRateLimiter::new(0, 3);
        assert!(rl.check("burst").is_ok());
        assert!(rl.check("burst").is_ok());
        assert!(rl.check("burst").is_ok());
        assert!(rl.check("burst").is_err(), "4th call should hit per-minute cap");
        rl.reset_minute_counters();
        assert!(rl.check("burst").is_ok(), "reset should clear cap");
    }

    #[actix_web::test]
    async fn test_validation_rejects_oversized_ids() {
        let state = make_state();
        let app = test::init_service(
            App::new()
                .app_data(web::Data::new(Arc::clone(&state)))
                .route("/judge", web::post().to(judge)),
        ).await;

        let long_room = "x".repeat(65);
        let req = test::TestRequest::post().uri("/judge")
            .set_json(judge_body(&long_room, 1, "p")).to_request();
        let resp = test::call_service(&app, req).await;
        assert_eq!(resp.status(), StatusCode::BAD_REQUEST);

        let long_player = "y".repeat(33);
        let req = test::TestRequest::post().uri("/judge")
            .set_json(judge_body("room1", 1, &long_player)).to_request();
        let resp = test::call_service(&app, req).await;
        assert_eq!(resp.status(), StatusCode::BAD_REQUEST);
    }

    #[actix_web::test]
    async fn test_recent_takes_returns_latest_first() {
        let state = make_state();
        let app = test::init_service(
            App::new()
                .app_data(web::Data::new(Arc::clone(&state)))
                .route("/judge", web::post().to(judge))
                .route("/recent/{room_id}", web::get().to(recent_takes)),
        ).await;

        for cid in 1u32..=5 {
            let req = test::TestRequest::post().uri("/judge")
                .set_json(judge_body("room-recent", cid, &format!("p{}", cid))).to_request();
            test::call_service(&app, req).await;
        }
        let req = test::TestRequest::get().uri("/recent/room-recent?limit=3").to_request();
        let resp = test::call_service(&app, req).await;
        assert_eq!(resp.status(), StatusCode::OK);
        let events: Vec<RecentEvent> = test::read_body_json(resp).await;
        assert_eq!(events.len(), 3);
        assert_eq!(events[0].card_id, 5);
        assert_eq!(events[2].card_id, 3);
    }

    #[actix_web::test]
    async fn test_idempotency_cache_independent_keys() {
        let cache = IdempotencyCache::new(60);
        for i in 0..50 {
            assert!(cache.check_and_insert(&format!("k{}", i)));
        }
        for i in 0..50 {
            assert!(!cache.check_and_insert(&format!("k{}", i)));
        }
    }

    #[actix_web::test]
    async fn test_validation_rejects_empty_player_id() {
        let state = make_state();
        let app = test::init_service(
            App::new()
                .app_data(web::Data::new(Arc::clone(&state)))
                .route("/judge", web::post().to(judge)),
        ).await;

        let req = test::TestRequest::post().uri("/judge")
            .set_json(judge_body("room1", 1, "")).to_request();
        let resp = test::call_service(&app, req).await;
        assert_eq!(resp.status(), StatusCode::BAD_REQUEST);
    }
}

// ---- エントリポイント ----

#[actix_web::main]
async fn main() -> std::io::Result<()> {
    env_logger::init_from_env(env_logger::Env::default().default_filter_or("info"));

    let state = Arc::new(AppState::new());
    let metrics = Arc::new(Metrics::default());

    println!("judge service listening on :5002");

    HttpServer::new(move || {
        App::new()
            .wrap(middleware::Logger::default())
            .app_data(
                web::JsonConfig::default()
                    .error_handler(|err, _req| {
                        actix_web::error::InternalError::from_response(
                            err,
                            HttpResponse::BadRequest().json(
                                serde_json::json!({ "error": "invalid JSON body" })
                            ),
                        ).into()
                    })
            )
            .app_data(web::Data::new(Arc::clone(&state)))
            .app_data(web::Data::new(Arc::clone(&metrics)))
            .route("/judge",            web::post().to(judge))
            .route("/judge/batch",      web::post().to(batch_judge))
            .route("/judge/read",       web::post().to(mark_card_read))
            .route("/reset/{room_id}",  web::post().to(reset_room))
            .route("/stats/{room_id}",  web::get().to(get_room_stats))
            .route("/recent/{room_id}",       web::get().to(recent_takes))
            .route("/leaderboard/{room_id}",  web::get().to(get_leaderboard))
            .route("/metrics",                web::get().to(metrics_handler))
            .route("/health",           web::get().to(health))
    })
    .bind("0.0.0.0:5002")?
    .run()
    .await
}
