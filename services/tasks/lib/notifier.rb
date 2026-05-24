# frozen_string_literal: true
require "net/http"
require "json"
require "uri"
require "time"
require "fileutils"

# Notifier はデプロイ・ヘルスチェック失敗・ロールバック等のイベントを外部に通知する。
# Slack 互換 Incoming Webhook を主想定。設定が無ければローカルログにのみ追記する。
#
# 環境変数:
#   NOTIFY_WEBHOOK_URL  - Slack 互換の Incoming Webhook URL
#   NOTIFY_CHANNEL      - 任意。Webhook 側で許される場合に上書き
#   NOTIFY_LOG          - ローカル追記先（既定: ../../logs/notifications.log）
class Notifier
  LEVELS = %i[info warn error critical].freeze

  EMOJI = {
    info:     ":information_source:",
    warn:     ":warning:",
    error:    ":x:",
    critical: ":rotating_light:",
  }.freeze

  COLOR = {
    info:     "#36a64f",
    warn:     "#f2c744",
    error:    "#e01e5a",
    critical: "#9b1d1d",
  }.freeze

  def initialize(webhook_url: ENV["NOTIFY_WEBHOOK_URL"],
                 channel:     ENV["NOTIFY_CHANNEL"],
                 log_path:    ENV["NOTIFY_LOG"] || default_log_path,
                 timeout:     5)
    @webhook_url = webhook_url
    @channel     = channel
    @log_path    = log_path
    @timeout     = timeout
  end

  # メッセージを発火。失敗してもデプロイ全体を止めないように例外は呑む。
  def notify(level, message, fields: {})
    raise ArgumentError, "invalid level: #{level}" unless LEVELS.include?(level)
    record = build_record(level, message, fields)
    append_log(record)
    deliver(record) if @webhook_url
    record
  rescue => e
    warn "[notifier] notify failed: #{e.class}: #{e.message}"
    nil
  end

  # 失敗時の便利エイリアス
  def info(msg, **f);     notify(:info, msg, fields: f); end
  def warn(msg, **f);     notify(:warn, msg, fields: f); end
  def error(msg, **f);    notify(:error, msg, fields: f); end
  def critical(msg, **f); notify(:critical, msg, fields: f); end

  # デプロイ完了イベント
  def deploy_complete(services:, duration_sec:)
    info("Deploy complete", services: services.join(","), duration_sec: duration_sec)
  end

  # ヘルスチェック失敗イベント
  def health_failure(failed_services:)
    error("Health check failed", services: failed_services.join(","), count: failed_services.size)
  end

  # ロールバックイベント
  def rollback(from:, to:, reason:)
    critical("Rolled back", from: from, to: to, reason: reason)
  end

  private

  def default_log_path
    File.expand_path("../../../logs/notifications.log", __dir__)
  end

  def build_record(level, message, fields)
    {
      ts:       Time.now.utc.iso8601,
      level:    level,
      message:  message,
      fields:   fields,
      emoji:    EMOJI[level],
      channel:  @channel,
    }
  end

  def append_log(record)
    FileUtils.mkdir_p(File.dirname(@log_path))
    File.open(@log_path, "a") do |f|
      f.puts(JSON.generate(record))
    end
  end

  def deliver(record)
    payload = {
      text:        "#{record[:emoji]} #{record[:message]}",
      attachments: [
        {
          color:  COLOR[record[:level]],
          fields: record[:fields].map { |k, v| { title: k.to_s, value: v.to_s, short: true } },
          ts:     Time.now.to_i,
        },
      ],
    }
    payload[:channel] = record[:channel] if record[:channel]

    uri = URI.parse(@webhook_url)
    req = Net::HTTP::Post.new(uri, "Content-Type" => "application/json")
    req.body = JSON.generate(payload)
    Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https",
                    open_timeout: @timeout, read_timeout: @timeout) do |http|
      http.request(req)
    end
  end
end
