defmodule Realtime.SocketHandler do
  @behaviour :cowboy_websocket
  @name_min 1
  @name_max 12
  @max_players_limit 8

  @impl true
  def init(req, _opts), do: {:cowboy_websocket, req, %{room_id: nil, player_name: nil}}

  @impl true
  def websocket_handle({:text, text}, state) do
    case Jason.decode(text) do
      {:ok, msg} -> dispatch(msg, state)
      {:error, _} -> reply(error("invalid JSON"), state)
    end
  end
  def websocket_handle(_, state), do: {:ok, state}

  @impl true
  def websocket_info({:room_event, event}, state), do: {:reply, {:text, Jason.encode!(event)}, state}
  def websocket_info(_, state), do: {:ok, state}

  @impl true
  def terminate(_reason, _req, %{room_id: room_id}) do
    if room_id, do: Realtime.Room.leave(room_id, self())
    :ok
  end

  defp dispatch(%{"type" => "create_room"} = msg, state) do
    name = msg |> Map.get("player_name", "") |> String.trim()
    max_p = Map.get(msg, "max_players", @max_players_limit)
    with :ok <- validate_name(name),
         :ok <- validate_max_players(max_p) do
      room_id = generate_room_id()
      case Realtime.RoomSupervisor.start_room(room_id, max_p) do
        :ok ->
          {:ok, _} = Realtime.Room.join(room_id, self(), name)
          reply(%{type: "room_created", room_id: room_id, player_name: name, is_host: true},
                %{state | room_id: room_id, player_name: name})
        {:error, reason} -> reply(error(reason), state)
      end
    else
      {:error, reason} -> reply(error(reason), state)
    end
  end

  defp dispatch(%{"type" => "join_room"} = msg, state) do
    room_id = msg |> Map.get("room_id", "") |> String.trim() |> String.upcase()
    name = msg |> Map.get("player_name", "") |> String.trim()
    with :ok <- validate_name(name),
         :ok <- validate_room_id(room_id) do
      case Realtime.Room.join(room_id, self(), name) do
        {:ok, players} -> reply(%{type: "room_joined", room_id: room_id, players: players},
                                %{state | room_id: room_id, player_name: name})
        {:error, reason} -> reply(error(reason), state)
      end
    else
      {:error, reason} -> reply(error(reason), state)
    end
  end

  defp dispatch(%{"type" => "leave_room"}, state) do
    if state.room_id, do: Realtime.Room.leave(state.room_id, self())
    reply(%{type: "left_room"}, %{state | room_id: nil, player_name: nil})
  end

  defp dispatch(%{"type" => "start_game"} = msg, state) do
    selected_sets = Map.get(msg, "selected_sets", [])
    with {:ok, room_id} <- require_in_room(state),
         :ok <- require_host(room_id, state.player_name),
         {:ok, cards} <- fetch_cards(selected_sets),
         {:ok, shuffled} <- shuffle_cards(cards) do
      settings = %{"yomite_mode" => Map.get(msg, "yomite_mode", "ai"),
                   "yomite_name" => Map.get(msg, "yomite_name", state.player_name),
                   "end_mode" => Map.get(msg, "end_mode", "count"),
                   "end_value" => Map.get(msg, "end_value", 5)}
      case Realtime.Room.start_game(room_id, settings, shuffled) do
        :ok -> {:ok, state}
        {:error, reason} -> reply(error(reason), state)
      end
    else
      {:error, reason} -> reply(error(reason), state)
    end
  end

  defp dispatch(%{"type" => "next_card"}, state) do
    with {:ok, room_id} <- require_in_room(state) do
      settings = Realtime.Room.get_settings(room_id)
      if player_mode?(settings) and settings["yomite_name"] != state.player_name do
        reply(error("よみてのみ次の札を読むことができます"), state)
      else
        case Realtime.Room.next_card(room_id) do
          :ok -> {:ok, state}
          {:game_over, _} -> {:ok, state}
          {:error, reason} -> reply(error(reason), state)
        end
      end
    else
      {:error, reason} -> reply(error(reason), state)
    end
  end

  defp dispatch(%{"type" => "take_card"} = msg, state) do
    card_id = Map.get(msg, "card_id")
    with {:ok, room_id} <- require_in_room(state),
         :ok <- validate_card_id(card_id) do
      case Realtime.Room.attempt_take(room_id, card_id, state.player_name) do
        :valid ->
          case call_judge(room_id, card_id, state.player_name) do
            :won ->
              case Realtime.Room.take_card(room_id, card_id, state.player_name) do
                {:ok, _} -> {:ok, state}
                {:game_over, _} -> {:ok, state}
                {:error, reason} -> reply(error(reason), state)
              end
            :lost -> reply(%{type: "card_missed", card_id: card_id}, state)
            :error -> reply(error("判定サービスに接続できませんでした"), state)
          end
        {:foul, _} -> {:ok, state}
        {:error, :fouled} -> {:ok, state}
        {:error, reason} -> reply(error(reason), state)
      end
    else
      {:error, reason} -> reply(error(reason), state)
    end
  end

  defp dispatch(_, state), do: reply(error("unknown message type"), state)

  defp fetch_cards(selected_sets) when is_list(selected_sets) do
    sets_qs = case selected_sets do
      [] -> ""
      ids -> "?sets=" <> Enum.join(ids, ",")
    end
    url = String.to_charlist(card_gen_url() <> "/cards" <> sets_qs)
    case :httpc.request(:get, {url, []}, [], body_format: :string) do
      {:ok, {{_, 200, _}, _, body}} ->
        case Jason.decode(body) do
          {:ok, %{"cards" => cards}} when is_list(cards) -> {:ok, cards}
          {:ok, cards} when is_list(cards) -> {:ok, cards}
          _ -> {:error, "カードデータの形式が不正です"}
        end
      _ -> {:error, "カードの取得に失敗しました"}
    end
  end

  defp shuffle_cards(cards) do
    ids = Enum.map(cards, & &1["id"])
    body = Jason.encode!(ids)
    case :httpc.request(:post, {String.to_charlist(shuffle_url() <> "/shuffle"), [], ~c"application/json", body}, [], body_format: :string) do
      {:ok, {{_, 200, _}, _, resp}} ->
        shuffled_ids = Jason.decode!(resp)
        card_map = Map.new(cards, fn c -> {c["id"], c} end)
        {:ok, Enum.map(shuffled_ids, fn id -> card_map[id] end)}
      _ -> {:ok, Enum.shuffle(cards)}
    end
  end

  defp call_judge(room_id, card_id, name) do
    body = Jason.encode!(%{room_id: room_id, card_id: card_id, player_id: name, timestamp: DateTime.utc_now()})
    case :httpc.request(:post, {String.to_charlist(judge_url() <> "/judge"), [], ~c"application/json", body}, [], []) do
      {:ok, {{_, 200, _}, _, _}} -> :won
      {:ok, {{_, 409, _}, _, _}} -> :lost
      _ -> :error
    end
  end

  defp require_in_room(%{room_id: nil}), do: {:error, "ルームに参加していません"}
  defp require_in_room(%{room_id: id}), do: {:ok, id}
  defp require_host(room_id, name), do: if(Realtime.Room.get_host(room_id) == name, do: :ok, else: {:error, "ホストのみこの操作ができます"})
  defp player_mode?(%{"yomite_mode" => "player"}), do: true
  defp player_mode?(_), do: false
  defp validate_card_id(id) when is_integer(id), do: :ok
  defp validate_card_id(_), do: {:error, "card_id must be an integer"}

  defp validate_name(name) do
    len = String.length(name)
    cond do
      len < @name_min -> {:error, "プレイヤー名を入力してください"}
      len > @name_max -> {:error, "プレイヤー名は#{@name_max}文字以内にしてください"}
      true -> :ok
    end
  end

  defp validate_room_id(id), do: if(Regex.match?(~r/^[A-Z0-9]{4,8}$/, id), do: :ok, else: {:error, "ルームIDの形式が正しくありません"})
  defp validate_max_players(n) when is_integer(n) and n >= 2 and n <= @max_players_limit, do: :ok
  defp validate_max_players(_), do: {:error, "人数は2〜#{@max_players_limit}人の範囲で指定してください"}

  defp card_gen_url, do: Application.get_env(:realtime, :card_gen_url, "http://card-gen:5000")
  defp shuffle_url, do: Application.get_env(:realtime, :shuffle_url, "http://shuffle:5001")
  defp judge_url, do: Application.get_env(:realtime, :judge_url, "http://judge:5002")

  defp reply(payload, state), do: {:reply, {:text, Jason.encode!(payload)}, state}
  defp error(msg), do: %{type: "error", message: to_string(msg)}
  defp generate_room_id, do: :crypto.strong_rand_bytes(3) |> Base.encode16()
end
