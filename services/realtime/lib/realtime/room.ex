defmodule Realtime.Room do
  use GenServer

  def start_link({room_id, max_players}) do
    GenServer.start_link(__MODULE__, max_players, name: via(room_id))
  end

  def join(room_id, pid, name), do: call(room_id, {:join, pid, name}, {:error, "room not found"})
  def leave(room_id, pid), do: (try do GenServer.cast(via(room_id), {:leave, pid}) rescue _ -> :ok end)
  def list_players(room_id), do: call(room_id, :list_players, [])
  def player_count(room_id), do: call(room_id, :player_count, 0)
  def get_host(room_id), do: call(room_id, :get_host, nil)
  def get_settings(room_id), do: call(room_id, :get_settings, nil)
  def start_game(room_id, settings, cards), do: call(room_id, {:start_game, settings, cards}, {:error, "room not found"})
  def next_card(room_id), do: call(room_id, :next_card, {:error, "room not found"})
  def take_card(room_id, card_id, name), do: call(room_id, {:take_card, card_id, name}, {:error, "room not found"})

  defp call(room_id, msg, fallback) do
    GenServer.call(via(room_id), msg)
  rescue
    _ -> fallback
  end

  @impl true
  def init(max_players) do
    {:ok, %{players: [], max_players: max_players, host: nil, status: :waiting,
            settings: nil, cards: [], current_card_idx: -1,
            taken_card_ids: MapSet.new(), scores: %{}}}
  end

  @impl true
  def handle_call({:join, pid, name}, _from, state) do
    cond do
      length(state.players) >= state.max_players -> {:reply, {:error, "room is full"}, state}
      Enum.any?(state.players, fn {p, _} -> p == pid end) -> {:reply, {:error, "already in room"}, state}
      true ->
        Process.monitor(pid)
        new_players = state.players ++ [{pid, name}]
        host = state.host || name
        broadcast(state.players, %{type: "player_joined", player_name: name})
        names = Enum.map(new_players, fn {_, n} -> n end)
        {:reply, {:ok, names}, %{state | players: new_players, host: host}}
    end
  end

  def handle_call(:list_players, _from, s), do: {:reply, Enum.map(s.players, fn {_, n} -> n end), s}
  def handle_call(:player_count, _from, s), do: {:reply, length(s.players), s}
  def handle_call(:get_host, _from, s), do: {:reply, s.host, s}
  def handle_call(:get_settings, _from, s), do: {:reply, s.settings, s}

  def handle_call({:start_game, settings, cards}, _from, state) do
    if state.status != :waiting do
      {:reply, {:error, "game already started"}, state}
    else
      scores = Map.new(state.players, fn {_, n} -> {n, 0} end)
      new_state = %{state | status: :playing, settings: settings, cards: cards,
                            current_card_idx: 0, taken_card_ids: MapSet.new(), scores: scores}
      broadcast(state.players, %{type: "game_started", cards: cards, settings: settings,
                                  players: Enum.map(state.players, fn {_, n} -> n end)})
      broadcast_card_reading(state.players, cards, 0)
      schedule_time_limit(settings)
      {:reply, :ok, new_state}
    end
  end

  def handle_call(:next_card, _from, state) do
    case find_next_card_idx(state) do
      nil -> do_finish_game(state)
      idx ->
        broadcast_card_reading(state.players, state.cards, idx)
        {:reply, :ok, %{state | current_card_idx: idx}}
    end
  end

  def handle_call({:take_card, card_id, name}, _from, state) do
    cond do
      state.status != :playing -> {:reply, {:error, "game not in progress"}, state}
      MapSet.member?(state.taken_card_ids, card_id) -> {:reply, {:error, "card already taken"}, state}
      true ->
        new_taken = MapSet.put(state.taken_card_ids, card_id)
        new_scores = Map.update(state.scores, name, 1, &(&1 + 1))
        new_state = %{state | taken_card_ids: new_taken, scores: new_scores}
        broadcast(state.players, %{type: "card_taken", card_id: card_id, winner: name, scores: new_scores})
        if end_condition_met?(new_state), do: do_finish_game(new_state), else: {:reply, {:ok, new_scores}, new_state}
    end
  end

  @impl true
  def handle_cast({:leave, pid}, state), do: do_leave(pid, state)

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state), do: do_leave(pid, state)
  def handle_info(:time_up, state) do
    if state.status == :playing do
      broadcast_game_over(state)
      {:noreply, %{state | status: :finished}}
    else
      {:noreply, state}
    end
  end

  defp do_finish_game(state) do
    broadcast_game_over(state)
    {:reply, {:game_over, state.scores}, %{state | status: :finished}}
  end

  defp broadcast_game_over(state) do
    ranking = state.scores |> Enum.sort_by(fn {_, s} -> -s end) |> Enum.map(fn {n, _} -> n end)
    broadcast(state.players, %{type: "game_over", scores: state.scores, ranking: ranking})
  end

  defp broadcast_card_reading(players, cards, idx) do
    broadcast(players, %{type: "card_reading", card: Enum.at(cards, idx), index: idx, total: length(cards)})
  end

  defp find_next_card_idx(state) do
    state.cards
    |> Enum.with_index()
    |> Enum.find_value(fn {card, idx} ->
      if idx > state.current_card_idx and not MapSet.member?(state.taken_card_ids, card["id"]), do: idx
    end)
  end

  defp end_condition_met?(%{settings: %{"end_mode" => "count", "end_value" => n}, taken_card_ids: t}) when is_integer(n), do: MapSet.size(t) >= n
  defp end_condition_met?(_), do: false

  defp schedule_time_limit(%{"end_mode" => "time", "end_value" => secs}) when is_integer(secs) and secs > 0 do
    Process.send_after(self(), :time_up, secs * 1000)
  end
  defp schedule_time_limit(_), do: :ok

  defp do_leave(pid, state) do
    case Enum.find(state.players, fn {p, _} -> p == pid end) do
      nil -> {:noreply, state}
      {_, name} ->
        remaining = Enum.reject(state.players, fn {p, _} -> p == pid end)
        broadcast(remaining, %{type: "player_left", player_name: name})
        new_state = %{state | players: remaining}
        if remaining == [], do: {:stop, :normal, new_state}, else: {:noreply, new_state}
    end
  end

  defp broadcast(players, event), do: Enum.each(players, fn {pid, _} -> send(pid, {:room_event, event}) end)
  defp via(room_id), do: {:via, Registry, {Realtime.RoomRegistry, room_id}}
end
