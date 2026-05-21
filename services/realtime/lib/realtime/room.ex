defmodule Realtime.Room do
  use GenServer

  @type player :: {pid(), String.t()}
  @type state :: %{players: [player()], max_players: pos_integer()}

  def start_link({room_id, max_players}) do
    GenServer.start_link(__MODULE__, max_players, name: via(room_id))
  end

  def join(room_id, pid, name) do
    GenServer.call(via(room_id), {:join, pid, name})
  rescue
    _ -> {:error, "room not found"}
  end

  def leave(room_id, pid) do
    GenServer.cast(via(room_id), {:leave, pid})
  rescue
    _ -> :ok
  end

  def list_players(room_id) do
    GenServer.call(via(room_id), :list_players)
  rescue
    _ -> []
  end

  def player_count(room_id) do
    GenServer.call(via(room_id), :player_count)
  rescue
    _ -> 0
  end

  @impl true
  def init(max_players) do
    {:ok, %{players: [], max_players: max_players}}
  end

  @impl true
  def handle_call({:join, pid, name}, _from, state) do
    cond do
      length(state.players) >= state.max_players ->
        {:reply, {:error, "room is full"}, state}

      Enum.any?(state.players, fn {p, _} -> p == pid end) ->
        {:reply, {:error, "already in room"}, state}

      true ->
        Process.monitor(pid)
        new_players = state.players ++ [{pid, name}]
        broadcast(state.players, %{type: "player_joined", player_name: name})
        names = Enum.map(new_players, fn {_, n} -> n end)
        {:reply, {:ok, names}, %{state | players: new_players}}
    end
  end

  @impl true
  def handle_call(:list_players, _from, state) do
    {:reply, Enum.map(state.players, fn {_, n} -> n end), state}
  end

  @impl true
  def handle_call(:player_count, _from, state) do
    {:reply, length(state.players), state}
  end

  @impl true
  def handle_cast({:leave, pid}, state) do
    do_leave(pid, state)
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    do_leave(pid, state)
  end

  defp do_leave(pid, state) do
    case Enum.find(state.players, fn {p, _} -> p == pid end) do
      nil ->
        {:noreply, state}

      {_, name} ->
        remaining = Enum.reject(state.players, fn {p, _} -> p == pid end)
        broadcast(remaining, %{type: "player_left", player_name: name})
        new_state = %{state | players: remaining}
        if remaining == [], do: {:stop, :normal, new_state}, else: {:noreply, new_state}
    end
  end

  defp broadcast(players, event) do
    Enum.each(players, fn {pid, _} -> send(pid, {:room_event, event}) end)
  end

  defp via(room_id), do: {:via, Registry, {Realtime.RoomRegistry, room_id}}
end
