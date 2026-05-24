# frozen_string_literal: true
require "minitest/autorun"
require "webrick"
require_relative "../lib/health_checker"
require_relative "../lib/notifier"
require_relative "../lib/version_manager"
require "tmpdir"

class HealthCheckerTest < Minitest::Test
  def setup
    @port = pick_free_port
    @server = WEBrick::HTTPServer.new(Port: @port, Logger: WEBrick::Log.new(File::NULL),
                                       AccessLog: [])
    @server.mount_proc "/health" do |_req, res|
      res.status = 200
      res.body   = '{"status":"ok"}'
    end
    @server.mount_proc "/broken" do |_req, res|
      res.status = 500
      res.body   = '{"status":"broken"}'
    end
    @thread = Thread.new { @server.start }
    sleep 0.1
  end

  def teardown
    @server.shutdown
    @thread.join
  end

  def test_check_one_returns_ok
    services = { sample: { url: "http://localhost:#{@port}/health" } }
    checker = HealthChecker.new(services)
    result = checker.check_one(:sample, services[:sample][:url])
    assert result.ok, "expected ok=true got #{result.inspect}"
    assert_equal 200, result.status_code
    refute_nil result.latency_ms
  end

  def test_check_one_reports_500_as_not_ok
    services = { broken: { url: "http://localhost:#{@port}/broken" } }
    checker = HealthChecker.new(services)
    result = checker.check_one(:broken, services[:broken][:url])
    refute result.ok
    assert_equal 500, result.status_code
  end

  def test_check_all_runs_in_parallel
    services = {
      a: { url: "http://localhost:#{@port}/health" },
      b: { url: "http://localhost:#{@port}/health" },
      c: { url: "http://localhost:#{@port}/health" },
    }
    checker = HealthChecker.new(services)
    results = checker.check_all
    assert_equal 3, results.size
    assert results.all?(&:ok)
  end

  def test_compute_sla_handles_mixed
    h1 = HealthChecker::Result.new(name: :gw, url: "x", ok: true,  status_code: 200, body: nil, latency_ms: 10, error: nil)
    h2 = HealthChecker::Result.new(name: :gw, url: "x", ok: false, status_code: 0,   body: nil, latency_ms: nil, error: "boom")
    sla = HealthChecker.compute_sla([h1, h1, h2])
    assert_in_delta 66.67, sla[:gw][:uptime_pct], 0.01
    assert_equal 3, sla[:gw][:checks_total]
  end

  def pick_free_port
    server = TCPServer.new("127.0.0.1", 0)
    port = server.addr[1]
    server.close
    port
  end
end

class NotifierTest < Minitest::Test
  def test_writes_log_when_webhook_absent
    Dir.mktmpdir do |dir|
      log_path = File.join(dir, "notify.log")
      n = Notifier.new(webhook_url: nil, log_path: log_path)
      n.info("hello", environment: "test")
      n.error("boom", code: 42)
      assert File.exist?(log_path)
      lines = File.readlines(log_path)
      assert_equal 2, lines.size
      first = JSON.parse(lines.first)
      assert_equal "info",  first["level"]
      assert_equal "hello", first["message"]
    end
  end

  def test_rejects_invalid_level
    n = Notifier.new(webhook_url: nil, log_path: File.join(Dir.tmpdir, "n.log"))
    assert_raises(ArgumentError) { n.notify(:bogus, "x") }
  end
end

class VersionManagerTest < Minitest::Test
  def test_record_and_previous
    Dir.mktmpdir do |dir|
      vm = VersionManager.new(store_path: File.join(dir, "v.json"), history_limit: 3)
      vm.record("v1", services: %w[gateway])
      vm.record("v2", services: %w[gateway judge])
      vm.record("v3", services: %w[gateway])
      assert_equal "v3", vm.current.version
      assert_equal "v2", vm.previous.version
      assert_equal 3, vm.history.size
    end
  end

  def test_history_limit_evicts_oldest
    Dir.mktmpdir do |dir|
      vm = VersionManager.new(store_path: File.join(dir, "v.json"), history_limit: 2)
      vm.record("v1")
      vm.record("v2")
      vm.record("v3")
      versions = vm.history.map(&:version)
      assert_equal %w[v3 v2], versions
    end
  end

  def test_mark_rolled_back
    Dir.mktmpdir do |dir|
      vm = VersionManager.new(store_path: File.join(dir, "v.json"))
      vm.record("v1")
      vm.record("v2")
      vm.mark_rolled_back("v2")
      assert_equal "rolled_back", vm.current.status
    end
  end
end
