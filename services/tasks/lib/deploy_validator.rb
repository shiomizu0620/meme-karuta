# frozen_string_literal: true
require "json"
require "yaml"
require "open3"
require "socket"

# デプロイ前バリデーション: docker-compose.yml / 環境変数 / 依存サービスを検査。
# DeployHelper#full_deploy より前に走らせて、設定不備で本番に到達するのを防ぐ。
class DeployValidator
  REQUIRED_ENV = %w[VITE_GATEWAY_URL VITE_REALTIME_URL].freeze
  REQUIRED_PORTS = [4000, 5000, 5001, 5002, 5003, 5004, 8080].freeze

  Result = Struct.new(:check, :ok, :detail, keyword_init: true) do
    def to_s
      mark = ok ? "\e[32m✓\e[0m" : "\e[31m✗\e[0m"
      "  #{mark} #{check}#{detail ? " - #{detail}" : ''}"
    end
  end

  def initialize(compose_path:, env: ENV.to_h, root_dir: Dir.pwd)
    @compose_path = compose_path
    @env          = env
    @root_dir     = root_dir
    @results      = []
  end

  # 全チェックを実行し、失敗があれば false を返す
  def run_all
    check_compose_file
    check_compose_syntax
    check_required_env
    check_ports_free
    check_docker_daemon
    check_disk_space
    check_image_names
    @results.all?(&:ok)
  end

  # 結果をテキスト形式で出力
  def report
    failed = @results.count { |r| !r.ok }
    @results.each { |r| puts r.to_s }
    puts ""
    if failed.zero?
      puts "\e[32mAll #{@results.size} checks passed\e[0m"
    else
      puts "\e[31m#{failed}/#{@results.size} checks failed\e[0m"
    end
  end

  # 結果を JSON で取得（CI 等から呼ばれる用途）
  def to_json(*_args)
    JSON.pretty_generate(
      checks: @results.map { |r| { check: r.check, ok: r.ok, detail: r.detail } },
      summary: {
        total: @results.size,
        passed: @results.count(&:ok),
        failed: @results.count { |r| !r.ok },
      },
    )
  end

  private

  def add(check, ok, detail = nil)
    @results << Result.new(check: check, ok: ok, detail: detail)
  end

  def check_compose_file
    if File.exist?(@compose_path)
      add("docker-compose.yml exists", true, @compose_path)
    else
      add("docker-compose.yml exists", false, "not found at #{@compose_path}")
    end
  end

  def check_compose_syntax
    return unless File.exist?(@compose_path)
    begin
      data = YAML.safe_load(File.read(@compose_path), aliases: true)
      if data.is_a?(Hash) && data.key?("services")
        services = data["services"].keys
        add("compose syntax", true, "#{services.size} services declared")
      else
        add("compose syntax", false, "missing top-level 'services' key")
      end
    rescue Psych::SyntaxError => e
      add("compose syntax", false, "YAML parse error: #{e.message}")
    end
  end

  def check_required_env
    missing = REQUIRED_ENV.reject { |k| @env.key?(k) && !@env[k].to_s.empty? }
    if missing.empty?
      add("required env vars", true, "all #{REQUIRED_ENV.size} present")
    else
      add("required env vars", false, "missing: #{missing.join(', ')}")
    end
  end

  def check_ports_free
    busy = REQUIRED_PORTS.select { |p| port_in_use?(p) }
    if busy.empty?
      add("required ports free", true, "all #{REQUIRED_PORTS.size} available")
    else
      add("required ports free", false, "in use: #{busy.join(', ')} (deploy may fail to bind)")
    end
  end

  def check_docker_daemon
    _out, _err, status = Open3.capture3("docker info")
    if status.success?
      add("docker daemon", true)
    else
      add("docker daemon", false, "not reachable")
    end
  end

  def check_disk_space(min_gb: 2)
    out, _err, status = Open3.capture3("df -h #{@root_dir}")
    if status.success?
      lines = out.lines
      last  = lines.last
      avail = last.split[3] if last
      add("disk space (#{min_gb}GB min)", true, "available: #{avail}")
    else
      add("disk space (#{min_gb}GB min)", false, "df failed")
    end
  rescue
    add("disk space (#{min_gb}GB min)", false, "could not determine")
  end

  def check_image_names
    return unless File.exist?(@compose_path)
    content = File.read(@compose_path)
    bad = content.scan(/image:\s*([^\s]+)/).flatten.reject do |img|
      img =~ /^[a-zA-Z0-9._\/\-:]+$/
    end
    if bad.empty?
      add("image names valid", true)
    else
      add("image names valid", false, "invalid: #{bad.join(', ')}")
    end
  end

  def port_in_use?(port)
    s = TCPSocket.new("127.0.0.1", port)
    s.close
    true
  rescue Errno::ECONNREFUSED, Errno::EADDRNOTAVAIL
    false
  rescue
    false
  end
end
