# frozen_string_literal: true
require "open3"
require "json"
require "net/http"
require "uri"
require "time"

class DeployHelper
  DEPLOY_TIMEOUT   = 300
  HEALTH_WAIT      = 60
  ROLLBACK_TIMEOUT = 120

  ServiceInfo = Struct.new(:name, :port, :health_path, :container, keyword_init: true) do
    def health_url
      "http://localhost:#{port}#{health_path}"
    end
  end

  SERVICES = {
    gateway:    ServiceInfo.new(name: "gateway",    port: 8080, health_path: "/health", container: "meme-karuta-gateway-1"),
    realtime:   ServiceInfo.new(name: "realtime",   port: 4000, health_path: "/health", container: "meme-karuta-realtime-1"),
    judge:      ServiceInfo.new(name: "judge",      port: 5002, health_path: "/health", container: "meme-karuta-judge-1"),
    shuffle:    ServiceInfo.new(name: "shuffle",    port: 5001, health_path: "/health", container: "meme-karuta-shuffle-1"),
    "card-gen": ServiceInfo.new(name: "card-gen",   port: 5000, health_path: "/health", container: "meme-karuta-card-gen-1"),
    queue:      ServiceInfo.new(name: "queue",      port: 5003, health_path: "/health", container: "meme-karuta-queue-1"),
    serializer: ServiceInfo.new(name: "serializer", port: 5004, health_path: "/health", container: "meme-karuta-serializer-1"),
    frontend:   ServiceInfo.new(name: "frontend",   port: 5173, health_path: "/",        container: "meme-karuta-frontend-1"),
  }.freeze

  def initialize(root_dir: Dir.pwd, env: :production, dry_run: false)
    @root_dir = root_dir
    @env      = env
    @dry_run  = dry_run
    @log      = []
  end

  # フル・デプロイシーケンス
  def full_deploy(services: SERVICES.keys, pull: true, build: true)
    banner "Starting deploy [env=#{@env}, dry_run=#{@dry_run}]"

    record_deploy_start

    if pull
      log_step "Pulling latest images..."
      docker_compose("pull #{services.join(' ')}")
    end

    if build
      log_step "Building images..."
      docker_compose("build --parallel #{services.join(' ')}")
    end

    log_step "Stopping old containers..."
    docker_compose("stop #{services.join(' ')}")

    log_step "Starting new containers..."
    docker_compose("up -d --remove-orphans #{services.join(' ')}")

    log_step "Waiting for services to become healthy..."
    results = wait_for_healthy(services, timeout: HEALTH_WAIT)

    failed = results.reject { |_, ok| ok }.keys
    if failed.any?
      log_step "Health check failed for: #{failed.join(', ')} — rolling back"
      rollback(services)
      record_deploy_failure(failed)
      return false
    end

    record_deploy_success
    banner "Deploy complete — all #{services.size} services healthy"
    true
  rescue => e
    log_step "Deploy error: #{e.message}"
    record_deploy_failure([e.message])
    false
  end

  # ローリング・アップデート（ゼロダウンタイム）
  def rolling_update(services: SERVICES.keys)
    banner "Rolling update started"
    services.each do |svc|
      log_step "Updating #{svc}..."
      docker_compose("pull #{svc}")
      docker_compose("up -d --no-deps #{svc}")
      ok = wait_for_healthy([svc], timeout: 30).values.all?
      unless ok
        log_step "#{svc} failed health check, stopping rolling update"
        return false
      end
      log_step "#{svc} updated successfully"
    end
    banner "Rolling update complete"
    true
  end

  # ロールバック
  def rollback(services)
    banner "Rolling back #{services.join(', ')}"
    docker_compose("stop #{services.join(' ')}")
    docker_compose("up -d --no-deps #{services.join(' ')}", env: { "COMPOSE_FILE" => "docker-compose.prev.yml" })
    wait_for_healthy(services, timeout: ROLLBACK_TIMEOUT)
  end

  # 全サービスがヘルシーになるまで待機
  def wait_for_healthy(services, timeout: HEALTH_WAIT)
    results   = services.map { |s| [s, false] }.to_h
    deadline  = Time.now + timeout

    until results.values.all? || Time.now > deadline
      services.each do |svc_key|
        next if results[svc_key]
        svc = SERVICES[svc_key]
        next unless svc
        results[svc_key] = http_health_ok?(svc.health_url)
      end
      sleep 2 unless results.values.all?
    end

    results
  end

  # イメージタグを更新してコンポーズファイルを書き換え
  def update_image_tags(tags)
    compose_path = File.join(@root_dir, "docker-compose.yml")
    content      = File.read(compose_path)
    backup_path  = compose_path.sub(".yml", ".prev.yml")

    FileUtils.cp(compose_path, backup_path) unless @dry_run

    tags.each do |service, tag|
      content = content.gsub(/(image:\s*\S+\/#{service}:)\S+/, "\\1#{tag}")
    end

    File.write(compose_path, content) unless @dry_run
    log_step "Updated image tags: #{tags.inspect}"
  end

  # サービス状態サマリーを出力
  def status_report
    rows = SERVICES.map do |key, svc|
      ok      = http_health_ok?(svc.health_url)
      uptime  = container_uptime(svc.container)
      status  = ok ? "\e[32mUP  \e[0m" : "\e[31mDOWN\e[0m"
      "  #{svc.name.ljust(12)} #{status}  port #{svc.port}  uptime #{uptime || 'n/a'}"
    end

    puts "\n#{rows.join("\n")}\n"
  end

  # デプロイ履歴を読む
  def deploy_history(last: 10)
    log_path = deploy_log_path
    return [] unless File.exist?(log_path)
    entries  = JSON.parse(File.read(log_path))
    entries.last(last)
  rescue JSON::ParserError
    []
  end

  private

  def docker_compose(cmd, env: {})
    full = "docker compose -f #{@root_dir}/docker-compose.yml #{cmd}"
    log_step "$ #{full}"
    return if @dry_run
    out, err, status = Open3.capture3(env, full)
    raise "docker compose failed: #{err.strip}" unless status.success?
    out
  end

  def http_health_ok?(url)
    uri  = URI.parse(url)
    resp = Net::HTTP.start(uri.host, uri.port, open_timeout: 3, read_timeout: 3) do |http|
      http.get(uri.path.empty? ? "/" : uri.path)
    end
    resp.code.to_i < 400
  rescue
    false
  end

  def container_uptime(container)
    out, _, status = Open3.capture3("docker inspect --format '{{.State.StartedAt}}' #{container}")
    return nil unless status.success?
    started = Time.parse(out.strip)
    secs    = (Time.now - started).to_i
    secs < 60 ? "#{secs}s" : secs < 3600 ? "#{secs / 60}m" : "#{secs / 3600}h"
  rescue
    nil
  end

  def record_deploy_start
    append_log(event: "start", env: @env.to_s, time: Time.now.iso8601, services: SERVICES.keys.map(&:to_s))
  end

  def record_deploy_success
    append_log(event: "success", env: @env.to_s, time: Time.now.iso8601)
  end

  def record_deploy_failure(reasons)
    append_log(event: "failure", env: @env.to_s, time: Time.now.iso8601, reasons: reasons.map(&:to_s))
  end

  def append_log(entry)
    path    = deploy_log_path
    entries = File.exist?(path) ? JSON.parse(File.read(path)) : []
    entries << entry
    File.write(path, JSON.pretty_generate(entries)) unless @dry_run
  end

  def deploy_log_path
    File.join(@root_dir, "tmp", "deploy_history.json")
  end

  def log_step(msg)
    @log << { time: Time.now.iso8601, msg: msg }
    puts "[#{Time.now.strftime('%H:%M:%S')}] #{msg}"
  end

  def banner(msg)
    puts "\n#{'=' * 50}\n  #{msg}\n#{'=' * 50}\n"
  end
end
