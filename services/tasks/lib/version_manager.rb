# frozen_string_literal: true
require "json"
require "fileutils"
require "time"

# VersionManager は直近 N 個のデプロイ済みバージョン（Docker イメージタグや git SHA）を
# JSON ファイルに記録し、ロールバック対象を即座に取り出せるようにする。
#
# 想定の使い方:
#   vm = VersionManager.new
#   vm.record("v2025.05.24-abc1234", services: %w[gateway judge])  # デプロイ成功時
#   vm.previous       # 直前のバージョン（ロールバック先）
#   vm.history(limit: 5)
class VersionManager
  DEFAULT_HISTORY_LIMIT = 5

  Entry = Struct.new(:version, :timestamp, :services, :status, keyword_init: true) do
    def to_h
      { version: version, timestamp: timestamp, services: services, status: status }
    end
  end

  def initialize(store_path: default_store_path, history_limit: DEFAULT_HISTORY_LIMIT)
    @store_path    = store_path
    @history_limit = history_limit
  end

  # 新規バージョンを履歴に追加。古いものは history_limit を超えた分から削除。
  def record(version, services: [], status: "deployed")
    raise ArgumentError, "version is required" if version.nil? || version.empty?
    entries = load_entries
    entry = Entry.new(
      version:   version,
      timestamp: Time.now.utc.iso8601,
      services:  Array(services),
      status:    status,
    )
    entries.unshift(entry)
    entries = entries.first(@history_limit)
    write_entries(entries)
    entry
  end

  # 現在動いていると見なされる最新バージョン
  def current
    load_entries.first
  end

  # ロールバック対象となる「直前」バージョン
  def previous
    entries = load_entries
    return nil if entries.size < 2
    entries[1]
  end

  # 履歴を新しい順に返す
  def history(limit: @history_limit)
    load_entries.first(limit)
  end

  # 指定バージョンをロールバック対象としてマーク（statusを更新）
  def mark_rolled_back(version)
    entries = load_entries.map do |e|
      e.version == version ? Entry.new(**e.to_h.merge(status: "rolled_back")) : e
    end
    write_entries(entries)
  end

  # 履歴ファイルをクリア（テスト・初期化用）
  def reset!
    File.delete(@store_path) if File.exist?(@store_path)
  end

  private

  def default_store_path
    File.expand_path("../../../backups/versions.json", __dir__)
  end

  def load_entries
    return [] unless File.exist?(@store_path)
    raw = JSON.parse(File.read(@store_path))
    Array(raw).map { |h| Entry.new(**h.transform_keys(&:to_sym)) }
  rescue JSON::ParserError
    []
  end

  def write_entries(entries)
    FileUtils.mkdir_p(File.dirname(@store_path))
    payload = entries.map(&:to_h)
    tmp = "#{@store_path}.tmp"
    File.write(tmp, JSON.pretty_generate(payload))
    File.rename(tmp, @store_path)
  end
end
