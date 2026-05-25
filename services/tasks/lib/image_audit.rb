# frozen_string_literal: true

require "digest"
require "json"

# `services/frontend/public/images/` に置かれたミーム画像の監査ツール。
#
# CLAUDE.md の方針で、画像は git 管理外（著作権の関係で .gitignore）。
# でもデプロイ時に「期待される画像が全部揃っているか」「壊れていないか」を
# 確認する必要があるので、cards.json を参照しながら検証する。
#
# 提供するチェック:
#  * cards.json に書かれた image が物理的に存在するか
#  * 物理的にあるけど cards.json から参照されていない (orphan) ファイル
#  * ファイルサイズの異常（極端に小さい・大きい）
class ImageAudit
  MIN_BYTES = 1_024            # 1KB 未満は破損疑い
  MAX_BYTES = 5 * 1_024 * 1_024 # 5MB 超は要レビュー
  ALLOWED_EXTENSIONS = %w[.jpg .jpeg .png .gif .webp].freeze

  attr_reader :images_dir, :cards_json_path

  def initialize(images_dir:, cards_json_path:)
    @images_dir      = images_dir
    @cards_json_path = cards_json_path
  end

  # 監査を実行してレポートハッシュを返す。
  def audit
    cards    = load_cards
    expected = cards.map { |c| c.fetch("image").to_s.sub(%r{\A/images/}, "") }.compact.uniq
    actual   = list_actual_images

    missing   = expected - actual
    orphan    = actual - expected
    size_warn = scan_sizes(actual)

    {
      checked_at:        Time.now.utc.iso8601,
      cards_total:       cards.size,
      expected_images:   expected.size,
      actual_images:     actual.size,
      missing:           missing.sort,
      orphan:            orphan.sort,
      size_warnings:     size_warn,
      ok:                missing.empty? && size_warn.empty?,
    }
  end

  # cards.json の画像参照に対応するファイルだけ抽出した一覧。
  def referenced_files
    cards = load_cards
    cards.map { |c| File.join(images_dir, c.fetch("image").to_s.sub(%r{\A/images/}, "")) }
  end

  # ファイル単位で sha256 を計算する。重複検出に使える。
  def digest_map
    map = {}
    list_actual_images.each do |name|
      path = File.join(images_dir, name)
      next unless File.file?(path)
      map[name] = Digest::SHA256.file(path).hexdigest
    end
    map
  end

  # 同一ハッシュのファイルをグループ化（重複アップロード検出）。
  def find_duplicates
    by_hash = Hash.new { |h, k| h[k] = [] }
    digest_map.each { |name, hash| by_hash[hash] << name }
    by_hash.select { |_, names| names.size > 1 }
  end

  private

  def load_cards
    raise "cards.json not found: #{cards_json_path}" unless File.exist?(cards_json_path)
    JSON.parse(File.read(cards_json_path))
  end

  def list_actual_images
    return [] unless File.directory?(images_dir)
    Dir.children(images_dir).select do |name|
      ext = File.extname(name).downcase
      ALLOWED_EXTENSIONS.include?(ext)
    end
  end

  def scan_sizes(names)
    warnings = []
    names.each do |name|
      path  = File.join(images_dir, name)
      bytes = File.size(path)
      if bytes < MIN_BYTES
        warnings << { file: name, bytes: bytes, reason: "too_small" }
      elsif bytes > MAX_BYTES
        warnings << { file: name, bytes: bytes, reason: "too_large" }
      end
    end
    warnings
  end
end
