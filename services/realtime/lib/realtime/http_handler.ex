defmodule Realtime.HttpHandler do
  @moduledoc false

  @behaviour :cowboy_handler

  @impl true
  def init(req, opts) do
    path = :cowboy_req.path(req)
    req2 = handle(path, req)
    {:ok, req2, opts}
  end

  defp handle("/health", req) do
    body = Jason.encode!(%{status: "ok"})
    json_reply(200, body, req)
  end

  defp handle("/rooms/count", req) do
    count =
      Realtime.RoomSupervisor
      |> DynamicSupervisor.which_children()
      |> length()

    body = Jason.encode!(%{count: count})
    json_reply(200, body, req)
  end

  defp handle(_, req) do
    body = Jason.encode!(%{error: "not found"})
    json_reply(404, body, req)
  end

  defp json_reply(status, body, req) do
    :cowboy_req.reply(
      status,
      %{"content-type" => "application/json"},
      body,
      req
    )
  end
end
