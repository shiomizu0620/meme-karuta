defmodule Realtime.GameStats do
  @moduledoc """
  ゲーム統計の追跡・集計・レポートを担う GenServer。
  ルームごとにプレイヤーの取り札数・応答速度・セッション情報を管理する。
  """

  use GenServer

  @type room_id :: String.t()
  @type player  :: String.t()

  @type card_event :: %{
    card_id:         integer(),
    winner:          player(),
    response_ms:     integer(),
    timestamp:       DateTime.t()
  }

  @type room_stats :: %{
    room_id:         room_id(),
    started_at:      DateTime.t() | nil,
    finished_at:     DateTime.t() | nil,
    player_scores:   %{player() => integer()},
    card_events:     [card_event()],
    total_cards:     integer(),
    settings:        map() | nil,
    error_count:     integer()
  }

  # ---- Public API ----

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  @doc "ゲーム開始を記録する"
  @spec record_game_start(room_id(), [player()], map()) :: :ok
  def record_game_start(room_id, players, settings) do
    GenServer.cast(__MODULE__, {:game_start, room_id, players, settings})
  end

  @doc "カード取得イベントを記録する"
  @spec record_card_taken(room_id(), integer(), player(), integer()) :: :ok
  def record_card_taken(room_id, card_id, winner, response_ms) do
    GenServer.cast(__MODULE__, {:card_taken, room_id, card_id, winner, response_ms})
  end

  @doc "ゲーム終了を記録する"
  @spec record_game_over(room_id(), %{player() => integer()}) :: :ok
  def record_game_over(room_id, final_scores) do
    GenServer.cast(__MODULE__, {:game_over, room_id, final_scores})
  end

  @doc "エラーイベントを記録する"
  @spec record_error(room_id(), String.t(), player() | nil) :: :ok
  def record_error(room_id, message, player_name \\ nil) do
    GenServer.cast(__MODULE__, {:error_event, room_id, message, player_name})
  end

  @doc "ルームの統計を返す"
  @spec get_room_stats(room_id()) :: room_stats() | nil
  def get_room_stats(room_id) do
    GenServer.call(__MODULE__, {:get_room_stats, room_id})
  end

  @doc "全ルームのサマリーを返す"
  @spec get_summary() :: map()
  def get_summary() do
    GenServer.call(__MODULE__, :get_summary)
  end

  @doc "特定ルームの勝者（取り札最多）を返す"
  @spec winner(room_id()) :: player() | nil
  def winner(room_id) do
    case get_room_stats(room_id) do
      nil -> nil
      stats ->
        stats.player_scores
        |> Enum.max_by(fn {_, v} -> v end, fn -> nil end)
        |> then(fn
          nil       -> nil
          {name, _} -> name
        end)
    end
  end

  @doc "特定ルームの平均応答速度(ms)を返す"
  @spec avg_response_ms(room_id()) :: float() | nil
  def avg_response_ms(room_id) do
    case get_room_stats(room_id) do
      nil -> nil
      stats ->
        events = stats.card_events
        if length(events) == 0 do
          0.0
        else
          total = Enum.sum(Enum.map(events, & &1.response_ms))
          total / length(events)
        end
    end
  end

  @doc "ルームのゲーム時間(秒)を返す"
  @spec game_duration_seconds(room_id()) :: integer() | nil
  def game_duration_seconds(room_id) do
    case get_room_stats(room_id) do
      nil -> nil
      %{started_at: nil} -> nil
      %{finished_at: nil, started_at: started} ->
        DateTime.diff(DateTime.utc_now(), started)
      %{started_at: started, finished_at: finished} ->
        DateTime.diff(finished, started)
    end
  end

  @doc "最速取り札プレイヤーとその応答時間を返す"
  @spec fastest_player(room_id()) :: {player(), integer()} | nil
  def fastest_player(room_id) do
    case get_room_stats(room_id) do
      nil -> nil
      stats ->
        if length(stats.card_events) == 0 do
          nil
        else
          stats.card_events
          |> Enum.min_by(& &1.response_ms)
          |> then(fn event -> {event.winner, event.response_ms} end)
        end
    end
  end

  # ---- GenServer Callbacks ----

  @impl true
  def init(_) do
    {:ok, %{}}
  end

  @impl true
  def handle_cast({:game_start, room_id, players, settings}, state) do
    initial = %{
      room_id:       room_id,
      started_at:    DateTime.utc_now(),
      finished_at:   nil,
      player_scores: Map.new(players, fn p -> {p, 0} end),
      card_events:   [],
      total_cards:   0,
      settings:      settings,
      error_count:   0
    }
    {:noreply, Map.put(state, room_id, initial)}
  end

  @impl true
  def handle_cast({:card_taken, room_id, card_id, winner, response_ms}, state) do
    case Map.get(state, room_id) do
      nil ->
        {:noreply, state}

      stats ->
        event = %{
          card_id:     card_id,
          winner:      winner,
          response_ms: response_ms,
          timestamp:   DateTime.utc_now()
        }
        new_scores = Map.update(stats.player_scores, winner, 1, &(&1 + 1))
        new_stats  = %{stats |
          card_events:   [event | stats.card_events],
          player_scores: new_scores
        }
        {:noreply, Map.put(state, room_id, new_stats)}
    end
  end

  @impl true
  def handle_cast({:game_over, room_id, final_scores}, state) do
    case Map.get(state, room_id) do
      nil ->
        {:noreply, state}

      stats ->
        new_stats = %{stats | finished_at: DateTime.utc_now(), player_scores: final_scores}
        {:noreply, Map.put(state, room_id, new_stats)}
    end
  end

  @impl true
  def handle_cast({:error_event, room_id, _message, _player}, state) do
    case Map.get(state, room_id) do
      nil   -> {:noreply, state}
      stats ->
        new_stats = %{stats | error_count: stats.error_count + 1}
        {:noreply, Map.put(state, room_id, new_stats)}
    end
  end

  @impl true
  def handle_call({:get_room_stats, room_id}, _from, state) do
    {:reply, Map.get(state, room_id), state}
  end

  @impl true
  def handle_call(:get_summary, _from, state) do
    total_rooms    = map_size(state)
    finished_rooms = Enum.count(state, fn {_, s} -> s.finished_at != nil end)
    total_cards    = Enum.sum(Enum.map(state, fn {_, s} -> length(s.card_events) end))
    all_events     = Enum.flat_map(state, fn {_, s} -> s.card_events end)

    avg_response =
      if length(all_events) == 0 do
        0.0
      else
        Enum.sum(Enum.map(all_events, & &1.response_ms)) / length(all_events)
      end

    summary = %{
      total_rooms:    total_rooms,
      finished_rooms: finished_rooms,
      active_rooms:   total_rooms - finished_rooms,
      total_cards_taken: total_cards,
      avg_response_ms:   Float.round(avg_response, 1)
    }

    {:reply, summary, state}
  end

  # ---- フォーマットヘルパー ----

  @doc "ルームの統計を人間が読める形式にフォーマットする"
  @spec format_room_report(room_id()) :: String.t()
  def format_room_report(room_id) do
    case get_room_stats(room_id) do
      nil ->
        "Room #{room_id}: no data"

      stats ->
        ranking =
          stats.player_scores
          |> Enum.sort_by(fn {_, v} -> -v end)
          |> Enum.with_index(1)
          |> Enum.map_join("\n", fn {{name, score}, rank} ->
            "  #{rank}. #{name}: #{score}枚"
          end)

        duration = game_duration_seconds(room_id)
        avg_ms   = avg_response_ms(room_id)

        """
        ========== Room #{room_id} ==========
        Cards taken: #{length(stats.card_events)}
        Duration:    #{duration && "#{duration}s" || "ongoing"}
        Avg resp:    #{avg_ms && "#{Float.round(avg_ms, 1)}ms" || "n/a"}
        Errors:      #{stats.error_count}
        Ranking:
        #{ranking}
        """
    end
  end
end
