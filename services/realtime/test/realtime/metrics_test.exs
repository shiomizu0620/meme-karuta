defmodule Realtime.MetricsTest do
  @moduledoc """
  Realtime.Metrics の単体テスト。

  GenServer をテストごとに起動して、独立した状態でメトリクスの集計が
  期待通り動くことを検証する。Application で起動されている同名 GenServer と
  衝突しないように、明示的に start_supervised で起こす。
  """

  use ExUnit.Case, async: false

  alias Realtime.Metrics

  setup do
    if pid = Process.whereis(Realtime.Metrics) do
      GenServer.stop(pid)
    end

    {:ok, _pid} = start_supervised(Realtime.Metrics)
    :ok
  end

  test "初期スナップショットはすべて 0" do
    snap = Metrics.snapshot()
    assert snap.rooms_active == 0
    assert snap.players_online == 0
    assert snap.takes_total == 0
    assert snap.judge_latency_ms_avg == 0
    assert snap.judge_latency_ms_p95 == 0
  end

  test "ルーム作成・終了でアクティブ数が変化する" do
    Metrics.record_room_created("room-a")
    Metrics.record_room_created("room-b")
    assert Metrics.snapshot().rooms_active == 2

    Metrics.record_room_closed("room-a")
    assert Metrics.snapshot().rooms_active == 1
  end

  test "プレイヤー入退室で online 数が変化する" do
    Metrics.record_room_created("room-a")
    Metrics.record_player_joined("room-a", "alice")
    Metrics.record_player_joined("room-a", "bob")
    assert Metrics.snapshot().players_online == 2

    Metrics.record_player_left("room-a", "bob")
    assert Metrics.snapshot().players_online == 1
  end

  test "同じプレイヤー名は重複カウントされない" do
    Metrics.record_room_created("room-a")
    Metrics.record_player_joined("room-a", "alice")
    Metrics.record_player_joined("room-a", "alice")
    assert Metrics.snapshot().players_online == 1
  end

  test "ルームが閉じるとそのルームのプレイヤーは消える" do
    Metrics.record_room_created("room-a")
    Metrics.record_player_joined("room-a", "alice")
    Metrics.record_room_closed("room-a")
    assert Metrics.snapshot().players_online == 0
  end

  test "take イベントで totals とレイテンシが集計される" do
    Metrics.record_take("room-a", 10)
    Metrics.record_take("room-a", 20)
    Metrics.record_take("room-a", 30)

    snap = Metrics.snapshot()
    assert snap.takes_total == 3
    assert snap.judge_latency_ms_avg == 20
    assert snap.judge_latency_ms_p95 >= 20
  end

  test "Prometheus 形式は HELP / TYPE 行を含む" do
    Metrics.record_room_created("room-a")
    text = Metrics.render_prometheus()
    assert text =~ "# HELP karuta_rooms_active"
    assert text =~ "# TYPE karuta_rooms_active gauge"
    assert text =~ "karuta_rooms_active 1"
  end
end
