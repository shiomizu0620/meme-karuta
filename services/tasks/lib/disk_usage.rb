# frozen_string_literal: true

# サーバー上のディスク使用量を集計するヘルパー。
# `df` / `du` のラッパとして使う。本番サーバーで容量逼迫を検知して
# Slack に通知する用途。
class DiskUsage
  def initialize(executor: Kernel)
    @executor = executor
  end

  # 指定パスの使用率 (%) を返す。/proc が無いプラットフォームでも動くように
  # `df` の標準出力をパースする実装にする。
  def usage_percent(path)
    output = `df -P #{shell_escape(path)} 2>/dev/null`
    return 0 if output.nil? || output.empty?

    lines = output.split("\n")
    return 0 if lines.size < 2

    fields = lines.last.split
    pct    = fields[4].to_s.sub("%", "")
    pct.to_i
  end

  # 指定ディレクトリのサイズをバイト単位で返す。`du` を使う。
  def directory_bytes(path)
    output = `du -sb #{shell_escape(path)} 2>/dev/null`
    return 0 if output.nil? || output.empty?
    output.split.first.to_i
  end

  # `over_threshold?` は閾値超過の boolean。
  def over_threshold?(path, threshold_percent: 85)
    usage_percent(path) >= threshold_percent
  end

  private

  def shell_escape(str)
    "'" + str.to_s.gsub("'", "'\\''") + "'"
  end
end
