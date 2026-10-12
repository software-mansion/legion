defmodule Legion.Test.Support.LocalTool do
  @moduledoc """
  Pings back, outside MCP only.
  """
  use Legion.Tool

  @impl Legion.Tool
  def mcp?, do: false

  def ping, do: "pong"
end
