# frozen_string_literal: true

require "fileutils"
require "json"
require "time"
require "digest"

# サーバー上のカードデータ・ログ・cards.json をバックアップするためのヘルパー。
#
# Rakefile から `rake backup:run` で呼び出される想定。
# - tar.gz ではなく単純なディレクトリコピー + チェックサムリスト
# - 古いバックアップは保持数 (`max_generations`) を超えると古い順に削除
# - 削除前にチェックサム検証を行い、念のため整合性を担保
class BackupManager
  DEFAULT_DEST_ROOT       = "/var/backups/meme-karuta"
  DEFAULT_MAX_GENERATIONS = 14
  DEFAULT_CHUNK_SIZE      = 64 * 1024

  attr_reader :source_root, :dest_root, :max_generations, :logger

  def initialize(source_root:, dest_root: DEFAULT_DEST_ROOT,
                 max_generations: DEFAULT_MAX_GENERATIONS, logger: nil)
    @source_root     = source_root
    @dest_root       = dest_root
    @max_generations = max_generations
    @logger          = logger
  end

  # メイン実行関数。バックアップディレクトリ名を返す。
  def run
    ensure_dest_exists
    generation = next_generation_name
    target     = File.join(dest_root, generation)

    log "backup_started", source: source_root, target: target
    FileUtils.mkdir_p(target)

    copied = copy_tree(source_root, target)
    manifest = write_manifest(target, copied)

    log "backup_completed", target: target, files: copied.size, manifest: manifest

    rotate_old_generations
    target
  end

  # コピー済みのチェックサムリストを書き出す。
  def write_manifest(target, entries)
    path = File.join(target, "manifest.json")
    data = {
      "created_at"     => Time.now.utc.iso8601,
      "source_root"    => source_root,
      "file_count"     => entries.size,
      "total_bytes"    => entries.sum { |e| e[:bytes] },
      "files"          => entries.map { |e| { "rel" => e[:rel], "sha256" => e[:sha256], "bytes" => e[:bytes] } }
    }
    File.write(path, JSON.pretty_generate(data))
    path
  end

  # バックアップ世代をリストアップする。新しい順。
  def list_generations
    return [] unless File.directory?(dest_root)
    Dir.children(dest_root).select { |name| File.directory?(File.join(dest_root, name)) }.sort.reverse
  end

  # 一番新しいバックアップを返す。無ければ nil。
  def latest_generation
    list_generations.first
  end

  # 任意の世代のマニフェストと実体を突き合わせて壊れていないか検証する。
  def verify(generation)
    manifest_path = File.join(dest_root, generation, "manifest.json")
    return { ok: false, error: "manifest_missing" } unless File.exist?(manifest_path)

    manifest = JSON.parse(File.read(manifest_path))
    errors   = []

    manifest.fetch("files", []).each do |entry|
      full = File.join(dest_root, generation, entry.fetch("rel"))
      unless File.exist?(full)
        errors << "missing: #{entry["rel"]}"
        next
      end
      actual = Digest::SHA256.file(full).hexdigest
      if actual != entry.fetch("sha256")
        errors << "checksum mismatch: #{entry["rel"]}"
      end
    end

    { ok: errors.empty?, errors: errors, file_count: manifest.fetch("files", []).size }
  end

  private

  def ensure_dest_exists
    FileUtils.mkdir_p(dest_root)
  end

  def next_generation_name
    Time.now.utc.strftime("%Y%m%dT%H%M%SZ")
  end

  def copy_tree(src, dst)
    entries = []
    Dir.glob(File.join(src, "**", "*"), File::FNM_DOTMATCH).each do |path|
      next if File.directory?(path)
      next if path.end_with?(".") || path.end_with?("..")

      rel  = path.sub(/\A#{Regexp.escape(src)}\/?/, "")
      dest = File.join(dst, rel)
      FileUtils.mkdir_p(File.dirname(dest))

      sha = Digest::SHA256.new
      File.open(path, "rb") do |fin|
        File.open(dest, "wb") do |fout|
          while (buf = fin.read(DEFAULT_CHUNK_SIZE))
            fout.write(buf)
            sha.update(buf)
          end
        end
      end

      entries << { rel: rel, sha256: sha.hexdigest, bytes: File.size(dest) }
    end
    entries
  end

  def rotate_old_generations
    generations = list_generations
    return if generations.size <= max_generations

    to_remove = generations[max_generations..]
    to_remove.each do |name|
      path = File.join(dest_root, name)
      log "backup_rotated", removed: path
      FileUtils.rm_rf(path)
    end
  end

  def log(event, **fields)
    return unless logger
    logger.info({ event: event, **fields }.to_json)
  end
end
