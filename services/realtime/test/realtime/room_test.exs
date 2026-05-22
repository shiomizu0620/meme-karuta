defmodule Realtime.RoomTest do
  use ExUnit.Case, async: true

  setup do
    room_id = "TEST#{:rand.uniform(9999)}"
    {:ok, _pid} = start_supervised({Realtime.Room, {room_id, 3}})
    %{room_id: room_id}
  end

  test "join returns player list with the new member", %{room_id: room_id} do
    {:ok, players} = Realtime.Room.join(room_id, self(), "Alice")
    assert players == ["Alice"]
  end

  test "second player is appended to the list", %{room_id: room_id} do
    {:ok, _} = Realtime.Room.join(room_id, self(), "Alice")
    player2 = spawn(fn -> receive do: (_ -> :ok) end)
    {:ok, players} = Realtime.Room.join(room_id, player2, "Bob")
    assert "Alice" in players
    assert "Bob" in players
  end

  test "joining with the same pid returns error", %{room_id: room_id} do
    {:ok, _} = Realtime.Room.join(room_id, self(), "Alice")
    assert {:error, "already in room"} = Realtime.Room.join(room_id, self(), "Alice2")
  end

  test "room rejects when full", %{room_id: room_id} do
    pids = for _ <- 1..3, do: spawn(fn -> receive do: (_ -> :ok) end)
    Enum.each(pids, fn pid -> Realtime.Room.join(room_id, pid, "p#{inspect(pid)}") end)
    extra = spawn(fn -> receive do: (_ -> :ok) end)
    assert {:error, "room is full"} = Realtime.Room.join(room_id, extra, "Extra")
  end

  test "player_left broadcast is sent to remaining members", %{room_id: room_id} do
    other = spawn(fn -> receive do: (_ -> :ok) end)
    {:ok, _} = Realtime.Room.join(room_id, other, "Alice")
    {:ok, _} = Realtime.Room.join(room_id, self(), "Bob")
    Realtime.Room.leave(room_id, other)
    assert_receive {:room_event, %{type: "player_left", player_name: "Alice"}}, 500
  end

  test "joining a nonexistent room returns error" do
    assert {:error, "room not found"} = Realtime.Room.join("NOSUCHROOM", self(), "Ghost")
  end

  test "player_joined broadcast is sent to existing members", %{room_id: room_id} do
    {:ok, _} = Realtime.Room.join(room_id, self(), "Alice")
    newcomer = spawn(fn -> receive do: (_ -> :ok) end)
    Realtime.Room.join(room_id, newcomer, "Bob")
    assert_receive {:room_event, %{type: "player_joined", player_name: "Bob"}}, 500
  end

  test "list_players returns names in join order", %{room_id: room_id} do
    p1 = spawn(fn -> receive do: (_ -> :ok) end)
    p2 = spawn(fn -> receive do: (_ -> :ok) end)
    Realtime.Room.join(room_id, p1, "First")
    Realtime.Room.join(room_id, p2, "Second")
    assert Realtime.Room.list_players(room_id) == ["First", "Second"]
  end

  test "leave from nonexistent room does not crash" do
    assert :ok = Realtime.Room.leave("NOSUCHROOM", self())
  end

  test "list_players on nonexistent room returns empty list" do
    assert [] = Realtime.Room.list_players("NOSUCHROOM")
  end

  test "player_count returns 0 for nonexistent room" do
    assert 0 = Realtime.Room.player_count("NOSUCHROOM")
  end

  test "get_host returns nil for nonexistent room" do
    assert is_nil(Realtime.Room.get_host("NOSUCHROOM"))
  end

  test "first joining player becomes host", %{room_id: room_id} do
    {:ok, _} = Realtime.Room.join(room_id, self(), "Alice")
    assert "Alice" = Realtime.Room.get_host(room_id)
    other = spawn(fn -> receive do: (_ -> :ok) end)
    Realtime.Room.join(room_id, other, "Bob")
    assert "Alice" = Realtime.Room.get_host(room_id)
  end

  test "player_count is updated as players join", %{room_id: room_id} do
    assert 0 = Realtime.Room.player_count(room_id)
    {:ok, _} = Realtime.Room.join(room_id, self(), "Alice")
    assert 1 = Realtime.Room.player_count(room_id)
    other = spawn(fn -> receive do: (_ -> :ok) end)
    Realtime.Room.join(room_id, other, "Bob")
    assert 2 = Realtime.Room.player_count(room_id)
  end

  test "get_settings returns nil before game starts", %{room_id: room_id} do
    {:ok, _} = Realtime.Room.join(room_id, self(), "Alice")
    assert is_nil(Realtime.Room.get_settings(room_id))
  end

  test "take_card before game start returns error", %{room_id: room_id} do
    {:ok, _} = Realtime.Room.join(room_id, self(), "Alice")
    assert {:error, _} = Realtime.Room.take_card(room_id, 1, "Alice")
  end
end
