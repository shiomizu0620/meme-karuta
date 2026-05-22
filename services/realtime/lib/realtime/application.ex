defmodule Realtime.Application do
  use Application
  require Logger

  @impl true
  def start(_type, _args) do
    port = Application.get_env(:realtime, :port, 4000)

    routes = [{:_, [{"/ws", Realtime.SocketHandler, []}]}]
    dispatch = :cowboy_router.compile(routes)

    {:ok, _} =
      :cowboy.start_clear(:http, [{:port, port}], %{env: %{dispatch: dispatch}})

    Logger.info("Realtime WebSocket server listening on port #{port}")

    children = [
      {Registry, keys: :unique, name: Realtime.RoomRegistry},
      Realtime.RoomSupervisor
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: Realtime.Supervisor)
  end
end
