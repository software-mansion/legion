defmodule Legion.Test.Support.VaultTool do
  @moduledoc """
  Reports what the calling process tree was seeded with.
  """
  use Legion.Tool

  @doc "The current user this code runs for."
  def current_user, do: Vault.get(:current_user)

  @doc "The token the current call carried."
  def token, do: Vault.get(:token)

  @doc "The agent id this code runs under."
  def agent_id, do: Vault.get(:agent_id)

  @doc "The store this code runs under."
  def store, do: inspect(Vault.get(:store))

  @doc "The rate limit this code runs under."
  def rate_limit, do: inspect(Vault.get(:rate_limit))
end
