# frozen_string_literal: true
require "net/http"
require "json"
require "uri"

class HealthChecker
  TIMEOUT_SEC  = 5
  MAX_RETRIES  = 3
  RETRY_DELAY  = 2

  Result = Struct.new(:name, :url, :ok, :status_code, :body, :latency_ms, :error, keyword_init: true) do
    def to_s
      if ok
        "#{name}: UP  (HTTP #{status_code}, #{latency_ms}ms)"
      else
        "#{name}: DOWN  (#{error || "HTTP #{status_code}"})"
      end
    end

    def to_h
      { name: name, url: url, ok: ok, status_code: status_code,
        latency_ms: latency_ms, error: error }
    end
  end

  def initialize(services, timeout: TIMEOUT_SEC)
    @services = services
    @timeout  = timeout
  end

  # 全サービスのヘルスチェックを並列実行
  def check_all
    threads = @services.map do |name, cfg|
      Thread.new { check_one(name, cfg[:url]) }
    end
    threads.map(&:value)
  end

  # 単一サービスのヘルスチェック
  def check_one(name, url)
    uri     = URI.parse(url)
    t_start = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    resp = Net::HTTP.start(uri.host, uri.port, open_timeout: @timeout, read_timeout: @timeout) do |http|
      http.get(uri.path.empty? ? "/" : uri.path)
    end

    latency = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - t_start) * 1000).round
    body    = JSON.parse(resp.body) rescue resp.body

    Result.new(
      name:        name,
      url:         url,
      ok:          resp.code.to_i < 400,
      status_code: resp.code.to_i,
      body:        body,
      latency_ms:  latency,
      error:       nil,
    )
  rescue => e
    Result.new(name: name, url: url, ok: false, status_code: 0,
               body: nil, latency_ms: nil, error: e.message)
  end

  # リトライ付きヘルスチェック
  def check_with_retry(name, url, retries: MAX_RETRIES, delay: RETRY_DELAY)
    retries.times do |attempt|
      result = check_one(name, url)
      return result if result.ok
      sleep delay if attempt < retries - 1
    end
    check_one(name, url)
  end

  # 全サービスがヘルシーかチェック
  def all_healthy?
    check_all.all?(&:ok)
  end

  # 特定サービスがヘルシーかチェック
  def healthy?(name)
    cfg = @services[name]
    return false unless cfg
    check_one(name, cfg[:url]).ok
  end

  # レポートをテキスト形式でフォーマット
  def format_report(results)
    max_len  = results.map { |r| r.name.to_s.length }.max || 10
    lines    = [""]
    healthy  = results.count(&:ok)
    unhealthy = results.count { |r| !r.ok }

    results.each do |r|
      padded = r.name.to_s.ljust(max_len)
      status = r.ok ? "\e[32m● UP  \e[0m" : "\e[31m● DOWN\e[0m"
      detail = if r.ok
        "\e[90m#{r.status_code} | #{r.latency_ms}ms\e[0m"
      else
        "\e[31m#{r.error || "HTTP #{r.status_code}"}\e[0m"
      end
      lines << "  #{padded}  #{status}  #{detail}"
    end

    lines << ""
    summary = if unhealthy == 0
      "\e[32m  All #{healthy} services are healthy\e[0m"
    else
      "\e[31m  #{unhealthy} service(s) are down, #{healthy} healthy\e[0m"
    end
    lines << summary
    lines << ""
    lines.join("\n")
  end

  # 結果をJSONに変換
  def to_json(results)
    JSON.pretty_generate(
      timestamp: Time.now.iso8601,
      healthy:   results.count(&:ok),
      unhealthy: results.count { |r| !r.ok },
      services:  results.map(&:to_h),
    )
  end

  # 継続監視（watchdogモード）
  def watch(interval: 5, max_failures: 3, &on_alert)
    failure_counts = Hash.new(0)
    loop do
      results = check_all
      results.each do |r|
        if r.ok
          if failure_counts[r.name] > 0
            puts "[#{Time.now.strftime('%H:%M:%S')}] #{r.name} recovered"
            failure_counts[r.name] = 0
          end
        else
          failure_counts[r.name] += 1
          msg = "[#{Time.now.strftime('%H:%M:%S')}] #{r.name} DOWN (#{failure_counts[r.name]} failures)"
          puts msg
          on_alert&.call(r, failure_counts[r.name]) if failure_counts[r.name] >= max_failures
        end
      end
      sleep interval
    end
  rescue Interrupt
    puts "\nHealth watch stopped."
  end

  # SLAレポート（過去の結果から稼働率を計算）
  def self.compute_sla(check_history)
    return {} if check_history.empty?
    by_service = check_history.group_by { |r| r.name }
    by_service.transform_values do |results|
      total   = results.size
      healthy = results.count(&:ok)
      avg_lat = results.filter_map(&:latency_ms).then { |ls| ls.empty? ? nil : ls.sum.to_f / ls.size }
      {
        uptime_pct:    (healthy.to_f / total * 100).round(2),
        checks_total:  total,
        checks_passed: healthy,
        avg_latency_ms: avg_lat&.round(1),
      }
    end
  end
end
