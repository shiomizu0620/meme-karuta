defmodule Realtime.Metrics do
  @moduledoc """
  リアルタイムサーバーのメトリクス収集 GenServer。

  各ルームの接続数・取り札イベント・先着判定リクエストの遅延などを集計し、
  運用監視用の `/metrics` エンドポイントから参照される。
  Prometheus 形式に近い軽量フォーマットで吐く。
  """

  use GenServer

  @flush_interval_ms 10_000
  @history_size 600

  defmodule Snapshot do
    @moduledoc false
    defstruct [
      :timestamp_ms,
      :rooms_active,
      :players_online,
      :takes_total,
      :judge_latency_ms_avg,
      :judge_latency_ms_p95
    ]
  end

  ## ---- public API ----

  def start_link(_opts \\ []) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  @doc "ルーム作成イベントを記録"
  def record_room_created(room_id) do
    GenServer.cast(__MODULE__, {:room_created, room_id})
  end

  @doc "ルーム終了イベントを記録"
  def record_room_closed(room_id) do
    GenServer.cast(__MODULE__, {:room_closed, room_id})
  end

  @doc "プレイヤー接続イベントを記録"
  def record_player_joined(room_id, player_name) do
    GenServer.cast(__MODULE__, {:player_joined, room_id, player_name})
  end

  @doc "プレイヤー切断イベントを記録"
  def record_player_left(room_id, player_name) do
    GenServer.cast(__MODULE__, {:player_left, room_id, player_name})
  end

  @doc "取り札イベントを記録（latency_ms は judge への往復時間）"
  def record_take(room_id, latency_ms) when is_integer(latency_ms) do
    GenServer.cast(__MODULE__, {:take, room_id, latency_ms})
  end

  @doc "現時点のスナップショットを取得"
  def snapshot do
    GenServer.call(__MODULE__, :snapshot)
  end

  @doc "ヒストリー（過去 N 個のスナップショット）を取得"
  def history do
    GenServer.call(__MODULE__, :history)
  end

  @doc "Prometheus 風のテキスト形式で出力"
  def render_prometheus do
    GenServer.call(__MODULE__, :render_prometheus)
  end

  ## ---- GenServer callbacks ----

  @impl true
  def init(_opts) do
    Process.send_after(self(), :flush, @flush_interval_ms)
    state = %{
      rooms: MapSet.new(),
      players: %{},
      takes_total: 0,
      latency_samples: [],
      history: []
    }
    {:ok, state}
  end

  @impl true
  def handle_cast({:room_created, room_id}, state) do
    {:noreply, %{state | rooms: MapSet.put(state.rooms, room_id)}}
  end

  @impl true
  def handle_cast({:room_closed, room_id}, state) do
    rooms = MapSet.delete(state.rooms, room_id)
    players = Map.delete(state.players, room_id)
    {:noreply, %{state | rooms: rooms, players: players}}
  end

  @impl true
  def handle_cast({:player_joined, room_id, player_name}, state) do
    current = Map.get(state.players, room_id, MapSet.new())
    players = Map.put(state.players, room_id, MapSet.put(current, player_name))
    {:noreply, %{state | players: players}}
  end

  @impl true
  def handle_cast({:player_left, room_id, player_name}, state) do
    current = Map.get(state.players, room_id, MapSet.new())
    updated = MapSet.delete(current, player_name)
    players =
      if MapSet.size(updated) == 0 do
        Map.delete(state.players, room_id)
      else
        Map.put(state.players, room_id, updated)
      end
    {:noreply, %{state | players: players}}
  end

  @impl true
  def handle_cast({:take, _room_id, latency_ms}, state) do
    samples = [latency_ms | state.latency_samples] |> Enum.take(1000)
    {:noreply, %{state | takes_total: state.takes_total + 1, latency_samples: samples}}
  end

  @impl true
  def handle_call(:snapshot, _from, state) do
    {:reply, build_snapshot(state), state}
  end

  @impl true
  def handle_call(:history, _from, state) do
    {:reply, Enum.reverse(state.history), state}
  end

  @impl true
  def handle_call(:render_prometheus, _from, state) do
    snap = build_snapshot(state)
    text =
      [
        "# HELP karuta_rooms_active number of active rooms",
        "# TYPE karuta_rooms_active gauge",
        "karuta_rooms_active #{snap.rooms_active}",
        "# HELP karuta_players_online total players online",
        "# TYPE karuta_players_online gauge",
        "karuta_players_online #{snap.players_online}",
        "# HELP karuta_takes_total total card-take events",
        "# TYPE karuta_takes_total counter",
        "karuta_takes_total #{snap.takes_total}",
        "# HELP karuta_judge_latency_ms judge round-trip latency",
        "# TYPE karuta_judge_latency_ms gauge",
        "karuta_judge_latency_ms_avg #{snap.judge_latency_ms_avg}",
        "karuta_judge_latency_ms_p95 #{snap.judge_latency_ms_p95}"
      ]
      |> Enum.join("\n")

    {:reply, text, state}
  end

  @impl true
  def handle_info(:flush, state) do
    snap = build_snapshot(state)
    history = [snap | state.history] |> Enum.take(@history_size)
    Process.send_after(self(), :flush, @flush_interval_ms)
    {:noreply, %{state | history: history, latency_samples: []}}
  end

  ## ---- helpers ----

  defp build_snapshot(state) do
    players_online =
      state.players
      |> Map.values()
      |> Enum.map(&MapSet.size/1)
      |> Enum.sum()

    {avg, p95} = latency_stats(state.latency_samples)

    %Snapshot{
      timestamp_ms: System.system_time(:millisecond),
      rooms_active: MapSet.size(state.rooms),
      players_online: players_online,
      takes_total: state.takes_total,
      judge_latency_ms_avg: avg,
      judge_latency_ms_p95: p95
    }
  end

  defp latency_stats([]), do: {0, 0}
  defp latency_stats(samples) do
    sorted = Enum.sort(samples)
    n = length(sorted)
    avg = div(Enum.sum(sorted), n)
    p95_idx = min(n - 1, trunc(n * 0.95))
    {avg, Enum.at(sorted, p95_idx)}
  end
end
