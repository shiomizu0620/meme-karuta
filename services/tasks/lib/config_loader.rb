# frozen_string_literal: true

require "yaml"
require "json"

# デプロイタスクで使う設定を YAML / 環境変数の両方から読むローダ。
#
# サーバーごとの違い (例: 本番 / ステージング) を YAML で持ち、
# 上書きしたい時は環境変数を優先する。Rakefile 内で
# `config = ConfigLoader.load("config/deploy.yml")` のように使う。
class ConfigLoader
  ENV_OVERRIDE_PREFIX = "MEMEKARUTA_"

  attr_reader :data

  def self.load(path)
    new(path).tap(&:reload)
  end

  def initialize(path)
    @path = path
    @data = {}
  end

  def reload
    @data = read_yaml.merge(env_overrides) { |_, _, env_val| env_val }
    self
  end

  def fetch(key, default = nil)
    @data.fetch(key.to_s, default)
  end

  def require!(key)
    value = fetch(key)
    raise ArgumentError, "missing required config: #{key}" if value.nil? || value.to_s.empty?
    value
  end

  def to_h
    @data.dup
  end

  def to_json(*args)
    @data.to_json(*args)
  end

  private

  def read_yaml
    return {} unless File.exist?(@path)
    raw = YAML.safe_load(File.read(@path), permitted_classes: [Symbol]) || {}
    raw.transform_keys(&:to_s)
  end

  def env_overrides
    ENV.each_with_object({}) do |(key, val), acc|
      next unless key.start_with?(ENV_OVERRIDE_PREFIX)
      normalized = key.sub(ENV_OVERRIDE_PREFIX, "").downcase
      acc[normalized] = val
    end
  end
end
