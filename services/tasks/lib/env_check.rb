# frozen_string_literal: true

# デプロイ前に最低限の前提条件を検査するヘルパー。
# 必須のコマンド、必須の環境変数、ディスク残量などをまとめてチェックする。
class EnvCheck
  REQUIRED_BINS = %w[docker git curl].freeze
  REQUIRED_ENVS = %w[MEMEKARUTA_HOST].freeze

  attr_reader :errors

  def initialize(required_bins: REQUIRED_BINS, required_envs: REQUIRED_ENVS)
    @required_bins = required_bins
    @required_envs = required_envs
    @errors        = []
  end

  def run
    @errors.clear
    check_bins
    check_envs
    @errors.empty?
  end

  def report
    return "all checks passed" if @errors.empty?
    @errors.map { |e| "- #{e}" }.join("\n")
  end

  private

  def check_bins
    @required_bins.each do |bin|
      found = `which #{bin} 2>/dev/null`.to_s.strip
      @errors << "missing command: #{bin}" if found.empty?
    end
  end

  def check_envs
    @required_envs.each do |var|
      @errors << "missing env var: #{var}" if ENV[var].to_s.empty?
    end
  end
end
