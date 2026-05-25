// 入力リクエストのバリデーション。
//
// gateway 側でもざっくり弾いているが、judge は単独で動かすケース（モバイル
// クライアントから直叩きなど）も想定しているので、ここでも厳しめにチェックする。
// 不正リクエストは早めに 400 で返し、内部の DashMap や履歴を汚さないようにする。

use chrono::{DateTime, Utc};
use std::collections::HashSet;

/// バリデーション結果。エラーメッセージのリストを保持する。
#[derive(Debug, Default)]
pub struct ValidationReport {
    errors: Vec<String>,
}

impl ValidationReport {
    pub fn new() -> Self {
        Self { errors: Vec::new() }
    }

    pub fn push(&mut self, msg: impl Into<String>) {
        self.errors.push(msg.into());
    }

    pub fn is_ok(&self) -> bool {
        self.errors.is_empty()
    }

    pub fn errors(&self) -> &[String] {
        &self.errors
    }

    pub fn into_errors(self) -> Vec<String> {
        self.errors
    }

    pub fn merge(&mut self, other: ValidationReport) {
        self.errors.extend(other.errors);
    }
}

/// ルーム ID のフォーマット制約。
/// - 英数字 + ハイフン
/// - 4 〜 32 文字
pub fn validate_room_id(room_id: &str) -> ValidationReport {
    let mut report = ValidationReport::new();
    if room_id.is_empty() {
        report.push("room_id must not be empty");
        return report;
    }
    if room_id.len() < 4 {
        report.push(format!("room_id too short: {} (min 4)", room_id.len()));
    }
    if room_id.len() > 32 {
        report.push(format!("room_id too long: {} (max 32)", room_id.len()));
    }
    if !room_id.chars().all(|c| c.is_ascii_alphanumeric() || c == '-') {
        report.push("room_id contains invalid characters (use a-z, A-Z, 0-9, -)");
    }
    report
}

/// プレイヤー ID のフォーマット制約。
pub fn validate_player_id(player_id: &str) -> ValidationReport {
    let mut report = ValidationReport::new();
    if player_id.trim().is_empty() {
        report.push("player_id must not be empty");
        return report;
    }
    if player_id.len() > 64 {
        report.push(format!("player_id too long: {} (max 64)", player_id.len()));
    }
    if player_id.chars().any(|c| c.is_control()) {
        report.push("player_id must not contain control characters");
    }
    report
}

/// カード ID は 1 〜 9999 の正の整数。
pub fn validate_card_id(card_id: u32) -> ValidationReport {
    let mut report = ValidationReport::new();
    if card_id == 0 {
        report.push("card_id must be positive");
    }
    if card_id > 9999 {
        report.push(format!("card_id too large: {} (max 9999)", card_id));
    }
    report
}

/// タイムスタンプは「今」から ±30 秒以内。
/// 端末の時刻ズレを許容しつつ、明らかにおかしな値を弾く。
pub fn validate_timestamp(ts: DateTime<Utc>, now: DateTime<Utc>) -> ValidationReport {
    let mut report = ValidationReport::new();
    let diff = (now - ts).num_seconds().abs();
    if diff > 30 {
        report.push(format!("timestamp differs from server by {}s (max 30s)", diff));
    }
    report
}

/// バッチリクエストの整合性をチェックする。
/// - items は 1 〜 100 件
/// - 同一 room_id × card_id × player_id は重複禁止（同一プレイヤーの連打を弾く）
pub fn validate_batch_items<I, T>(items: I) -> ValidationReport
where
    I: IntoIterator<Item = T>,
    T: AsBatchItem,
{
    let mut report = ValidationReport::new();
    let mut seen: HashSet<(String, u32, String)> = HashSet::new();
    let mut count = 0usize;

    for item in items {
        count += 1;
        let key = (
            item.room_id().to_string(),
            item.card_id(),
            item.player_id().to_string(),
        );
        if !seen.insert(key) {
            report.push(format!(
                "duplicate batch entry: room={} card={} player={}",
                item.room_id(),
                item.card_id(),
                item.player_id()
            ));
        }
    }

    if count == 0 {
        report.push("batch is empty");
    }
    if count > 100 {
        report.push(format!("batch too large: {} (max 100)", count));
    }
    report
}

/// バッチ要素として読み取る用の小さい trait。
/// 実体（JudgeRequest）に依存させず、テストでもダミー型を渡せるようにする。
pub trait AsBatchItem {
    fn room_id(&self) -> &str;
    fn card_id(&self) -> u32;
    fn player_id(&self) -> &str;
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::TimeZone;

    struct DummyItem {
        room: String,
        card: u32,
        player: String,
    }

    impl AsBatchItem for DummyItem {
        fn room_id(&self) -> &str { &self.room }
        fn card_id(&self) -> u32 { self.card }
        fn player_id(&self) -> &str { &self.player }
    }

    #[test]
    fn valid_room_id_passes() {
        assert!(validate_room_id("room-1234").is_ok());
    }

    #[test]
    fn short_room_id_rejected() {
        assert!(!validate_room_id("ab").is_ok());
    }

    #[test]
    fn long_room_id_rejected() {
        let long = "a".repeat(40);
        assert!(!validate_room_id(&long).is_ok());
    }

    #[test]
    fn invalid_char_room_id_rejected() {
        assert!(!validate_room_id("room!_id").is_ok());
    }

    #[test]
    fn empty_player_id_rejected() {
        assert!(!validate_player_id("   ").is_ok());
    }

    #[test]
    fn zero_card_id_rejected() {
        assert!(!validate_card_id(0).is_ok());
    }

    #[test]
    fn timestamp_too_far_rejected() {
        let now = Utc.with_ymd_and_hms(2026, 1, 1, 0, 0, 0).unwrap();
        let ts = Utc.with_ymd_and_hms(2026, 1, 1, 0, 1, 0).unwrap();
        assert!(!validate_timestamp(ts, now).is_ok());
    }

    #[test]
    fn batch_duplicate_detected() {
        let items = vec![
            DummyItem { room: "r".into(), card: 1, player: "p".into() },
            DummyItem { room: "r".into(), card: 1, player: "p".into() },
        ];
        assert!(!validate_batch_items(items).is_ok());
    }

    #[test]
    fn empty_batch_rejected() {
        let items: Vec<DummyItem> = vec![];
        assert!(!validate_batch_items(items).is_ok());
    }
}
