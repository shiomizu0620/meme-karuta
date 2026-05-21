defmodule Realtime.SocketHandler do
  @behaviour :cowboy_websocket

  @type state :: %{room_id: String.t() | nil, player_name: String.t() | nil}

  @name_min 1
  @name_max 12
  @max_players_limit 8

  @impl true
  def init(req, _opts) do
    {:cowboy_websocket, req, %{room_id: nil, player_name: nil}}
  end

  @impl true
  def websocket_handle({:text, text}, state) do
    case Jason.decode(text) do
      {:ok, msg} -> dispatch(msg, state)
      {:error, _} -> reply(error("invalid JSON"), state)
    end
  end

  def websocket_handle(_frame, state), do: {:ok, state}

  @impl true
  def websocket_info({:room_event, event}, state) do
    {:reply, {:text, Jason.encode!(event)}, state}
  end

  def websocket_info(_msg, state), do: {:ok, state}

  @impl true
  def terminate(_reason, _req, %{room_id: room_id, player_name: _} = _state) do
    if room_id, do: Realtime.Room.leave(room_id, self())
    :ok
  end

  defp dispatch(%{"type" => "create_room"} = msg, state) do
    name = Map.get(msg, "player_name", "") |> String.trim()
    max_p = Map.get(msg, "max_players", @max_players_limit)

    with :ok <- validate_name(name),
         :ok <- validate_max_players(max_p) do
      room_id = generate_room_id()

      case Realtime.RoomSupervisor.start_room(room_id, max_p) do
        :ok ->
          {:ok, _} = Realtime.Room.join(room_id, self(), name)
          resp = %{type: "room_created", room_id: room_id, player_name: name, is_host: true}
          reply(resp, %{state | room_id: room_id, player_name: name})

        {:error, reason} ->
          reply(error(reason), state)
      end
    else
      {:error, reason} -> reply(error(reason), state)
    end
  end

  defp dispatch(%{"type" => "join_room"} = msg, state) do
    room_id = msg |> Map.get("room_id", "") |> String.trim() |> String.upcase()
    name = Map.get(msg, "player_name", "") |> String.trim()

    with :ok <- validate_name(name),
         :ok <- validate_room_id(room_id) do
      case Realtime.Room.join(room_id, self(), name) do
        {:ok, players} ->
          resp = %{type: "room_joined", room_id: room_id, players: players}
          reply(resp, %{state | room_id: room_id, player_name: name})

        {:error, reason} ->
          reply(error(reason), state)
      end
    else
      {:error, reason} -> reply(error(reason), state)
    end
  end

  defp dispatch(%{"type" => "leave_room"}, state) do
    if state.room_id, do: Realtime.Room.leave(state.room_id, self())
    reply(%{type: "left_room"}, %{state | room_id: nil, player_name: nil})
  end

  defp dispatch(_msg, state), do: reply(error("unknown message type"), state)

  defp validate_name(name) do
    len = String.length(name)
    cond do
      len < @name_min -> {:error, "プレイヤー名を入力してください"}
      len > @name_max -> {:error, "プレイヤー名は#{@name_max}文字以内にしてください"}
      true -> :ok
    end
  end

  defp validate_room_id(id) do
    if Regex.match?(~r/^[A-Z0-9]{4,8}$/, id),
      do: :ok,
      else: {:error, "ルームIDの形式が正しくありません"}
  end

  defp validate_max_players(n) when is_integer(n) and n >= 2 and n <= @max_players_limit, do: :ok
  defp validate_max_players(_), do: {:error, "人数は2〜#{@max_players_limit}人の範囲で指定してください"}

  defp reply(payload, state) do
    {:reply, {:text, Jason.encode!(payload)}, state}
  end

  defp error(msg), do: %{type: "error", message: to_string(msg)}

  defp generate_room_id do
    :crypto.strong_rand_bytes(3) |> Base.encode16()
  end
end
