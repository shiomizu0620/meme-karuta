defmodule Realtime.RoomSupervisor do
  use DynamicSupervisor

  def start_link(_opts) do
    DynamicSupervisor.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @impl true
  def init(:ok) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  def start_room(room_id, max_players) do
    spec = {Realtime.Room, {room_id, max_players}}
    case DynamicSupervisor.start_child(__MODULE__, spec) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _}} -> {:error, "room already exists"}
      {:error, reason} -> {:error, inspect(reason)}
    end
  end
end
