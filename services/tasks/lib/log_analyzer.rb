# frozen_string_literal: true

require "json"
require "time"

# 各サービスから集まる構造化ログを解析するヘルパー。
#
# audit.log や gateway のアクセスログを 1 行 = 1 JSON で受け取り、
# 一定時間のスライスごとに集計する。Rakefile から
# `rake logs:summarize` のようにして呼び出される想定。
#
# 設計上のポイント:
#  - ストリーミング処理（巨大ログでもメモリ消費を抑える）
#  - 不正な JSON 行はカウントして読み進める（fail-soft）
#  - 集計はバケット単位 (デフォルト 1 分)
class LogAnalyzer
  DEFAULT_BUCKET_SECONDS = 60

  attr_reader :bucket_seconds, :counters, :bad_lines, :first_time, :last_time

  def initialize(bucket_seconds: DEFAULT_BUCKET_SECONDS)
    @bucket_seconds = bucket_seconds
    @counters       = Hash.new { |h, k| h[k] = Hash.new(0) }
    @bad_lines      = 0
    @first_time     = nil
    @last_time      = nil
  end

  # 1 行ずつ食わせる。ストリーミング処理用。
  def feed(line)
    line = line.to_s.strip
    return if line.empty?

    record = parse_line(line)
    return @bad_lines += 1 unless record

    ts = extract_time(record)
    return @bad_lines += 1 unless ts

    @first_time ||= ts
    @last_time = ts

    bucket = ts.to_i - (ts.to_i % bucket_seconds)
    event  = record["event"] || record["type"] || "unknown"

    @counters[bucket][event] += 1
  end

  # ファイル全体を食わせるシュガー。
  def feed_file(path)
    File.foreach(path) { |line| feed(line) }
    self
  end

  # 集計済みのスナップショットを返す。
  def snapshot
    {
      bucket_seconds: bucket_seconds,
      bad_lines:      bad_lines,
      first_time:     first_time&.iso8601,
      last_time:      last_time&.iso8601,
      buckets:        sorted_buckets,
      totals:         compute_totals,
    }
  end

  # 上位 N 個のイベントタイプを返す。
  def top_events(limit: 10)
    compute_totals.sort_by { |_, v| -v }.first(limit).to_h
  end

  # ログのレートが急増 (前のバケット比) しているかを検出する。
  def detect_spikes(factor: 3.0)
    spikes = []
    bs = sorted_buckets
    bs.each_cons(2) do |(_, prev_counts), (b, curr_counts)|
      prev_counts.each do |event, prev|
        curr = curr_counts[event] || 0
        next if prev < 5  # 低頻度イベントはノイズになりやすいので除外
        if curr.to_f / prev >= factor
          spikes << { bucket: Time.at(b).utc.iso8601, event: event, prev: prev, curr: curr }
        end
      end
    end
    spikes
  end

  private

  def parse_line(line)
    JSON.parse(line)
  rescue JSON::ParserError
    nil
  end

  def extract_time(record)
    raw = record["time"] || record["timestamp"] || record["ts"]
    return nil unless raw
    case raw
    when Integer then Time.at(raw)
    when String  then Time.parse(raw)
    else nil
    end
  rescue ArgumentError
    nil
  end

  def sorted_buckets
    @counters.sort.to_h
  end

  def compute_totals
    totals = Hash.new(0)
    @counters.each_value do |events|
      events.each { |k, v| totals[k] += v }
    end
    totals
  end
end
