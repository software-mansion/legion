defmodule Legion.Test.Support.VaultTool do
  @moduledoc """
  Reports what the calling process tree was seeded with.
  """
  use Legion.Tool

  @doc "The agent id this code runs under."
  def agent_id, do: Vault.get(:agent_id)

  @doc "The store this code runs under."
  def store, do: inspect(Vault.get(:store))
end
