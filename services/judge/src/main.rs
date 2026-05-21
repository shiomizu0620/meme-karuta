use actix_web::{middleware, web, App, HttpResponse, HttpServer};
use chrono::{DateTime, Duration, Utc};
use dashmap::DashMap;
use serde::{Deserialize, Serialize};
use std::sync::Arc;
use std::time::SystemTime;

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
            .route("/judge",          web::post().to(judge))
            .route("/judge/batch",    web::post().to(batch_judge))
            .route("/judge/read",     web::post().to(mark_card_read))
            .route("/reset/{room_id}", web::post().to(reset_room))
            .route("/stats/{room_id}", web::get().to(get_room_stats))
            .route("/health",          web::get().to(health))
    })
    .bind("0.0.0.0:5002")?
    .run()
    .await
}
