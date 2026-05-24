defmodule Realtime.Presence do
  @moduledoc """
  各ルームのプレイヤー接続状態（オンライン／一時切断／離脱）を追跡する GenServer。

  WebSocket は不安定なので一時的に切れることがある。完全に離脱したのか単発の切断なのかを
  即座に判定すると誤検出が増えるので、本モジュールでは以下のタイムラインで管理する:

      接続中 (online)
        │ websocket close
        ▼
      一時切断 (idle)   ─ grace_period 内に再接続 ─► online
        │ grace 経過
        ▼
      離脱確定 (gone)
  """

  use GenServer

  @grace_period_ms 8_000
  @sweep_interval_ms 2_000

  defmodule Entry do
    @moduledoc false
    defstruct [:room_id, :player_name, :status, :pid, :since_ms]
  end

  ## ---- public API ----

  def start_link(_opts \\ []) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  def online(room_id, player_name, pid) do
    GenServer.cast(__MODULE__, {:online, room_id, player_name, pid})
  end

  def idle(room_id, player_name) do
    GenServer.cast(__MODULE__, {:idle, room_id, player_name})
  end

  def gone(room_id, player_name) do
    GenServer.cast(__MODULE__, {:gone, room_id, player_name})
  end

  def list(room_id) do
    GenServer.call(__MODULE__, {:list, room_id})
  end

  def summary do
    GenServer.call(__MODULE__, :summary)
  end

  def online_count(room_id) do
    GenServer.call(__MODULE__, {:online_count, room_id})
  end

  def stale_players(room_id) do
    GenServer.call(__MODULE__, {:stale_players, room_id})
  end

  def status_of(room_id, player_name) do
    GenServer.call(__MODULE__, {:status_of, room_id, player_name})
  end

  ## ---- callbacks ----

  @impl true
  def init(_) do
    schedule_sweep()
    {:ok, %{entries: %{}, grace: @grace_period_ms}}
  end

  @impl true
  def handle_cast({:online, room_id, player_name, pid}, state) do
    key = {room_id, player_name}
    entry = %Entry{room_id: room_id, player_name: player_name, status: :online,
                   pid: pid, since_ms: now_ms()}
    {:noreply, %{state | entries: Map.put(state.entries, key, entry)}}
  end

  def handle_cast({:idle, room_id, player_name}, state) do
    key = {room_id, player_name}
    entries =
      case Map.fetch(state.entries, key) do
        {:ok, e} ->
          Map.put(state.entries, key, %Entry{e | status: :idle, since_ms: now_ms()})
        :error ->
          state.entries
      end
    {:noreply, %{state | entries: entries}}
  end

  def handle_cast({:gone, room_id, player_name}, state) do
    key = {room_id, player_name}
    {:noreply, %{state | entries: Map.delete(state.entries, key)}}
  end

  @impl true
  def handle_call({:list, room_id}, _from, state) do
    rows =
      state.entries
      |> Enum.filter(fn {{rid, _}, _} -> rid == room_id end)
      |> Enum.map(fn {_, e} -> %{player_name: e.player_name, status: e.status} end)
    {:reply, rows, state}
  end

  def handle_call({:online_count, room_id}, _from, state) do
    n =
      state.entries
      |> Enum.count(fn {{rid, _}, e} -> rid == room_id and e.status == :online end)
    {:reply, n, state}
  end

  def handle_call(:summary, _from, state) do
    by_room =
      state.entries
      |> Enum.group_by(fn {{rid, _}, _} -> rid end)
      |> Enum.map(fn {rid, list} ->
        statuses = Enum.frequencies_by(list, fn {_, e} -> e.status end)
        {rid, %{
          total:  length(list),
          online: Map.get(statuses, :online, 0),
          idle:   Map.get(statuses, :idle, 0),
        }}
      end)
      |> Enum.into(%{})
    {:reply, %{rooms: map_size(by_room), per_room: by_room}, state}
  end

  @doc """
  グレースピリオド経過後に idle のままだった離脱予定者の一覧を返す。
  Room モジュールが「もう本当に居ない」と判断するときの参照に使う。
  """
  def handle_call({:stale_players, room_id}, _from, state) do
    cutoff = now_ms() - state.grace
    rows =
      state.entries
      |> Enum.filter(fn {{rid, _}, e} ->
        rid == room_id and e.status == :idle and e.since_ms < cutoff
      end)
      |> Enum.map(fn {_, e} -> e.player_name end)
    {:reply, rows, state}
  end

  @doc """
  特定プレイヤーの現在のステータスと最終更新時刻を返す。
  Room.players_meta/1 経由でクライアントへ送信する想定。
  """
  def handle_call({:status_of, room_id, player_name}, _from, state) do
    key = {room_id, player_name}
    reply =
      case Map.fetch(state.entries, key) do
        {:ok, e} -> %{status: e.status, since_ms: e.since_ms, age_ms: now_ms() - e.since_ms}
        :error   -> %{status: :gone, since_ms: nil, age_ms: nil}
      end
    {:reply, reply, state}
  end

  @impl true
  def handle_info(:sweep, state) do
    cutoff = now_ms() - state.grace
    entries =
      state.entries
      |> Enum.reject(fn {_, e} -> e.status == :idle and e.since_ms < cutoff end)
      |> Enum.into(%{})
    schedule_sweep()
    {:noreply, %{state | entries: entries}}
  end

  ## ---- internal helpers ----

  defp schedule_sweep do
    Process.send_after(self(), :sweep, @sweep_interval_ms)
  end

  defp now_ms, do: System.monotonic_time(:millisecond)
end
