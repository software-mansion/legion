defmodule Legion.RateLimiter.ExceededError do
  @moduledoc """
  Raised by a `Legion.RateLimiter` when a rule denies a call.

  Carries the `:agent_id`, the `:identity` and `:policy` of the rule that
  denied it, the `:usage` the adapter measured for it, and the `:violations` -
  the policy fields that were exceeded, e.g. `[:max_agents]`. Legion rescues it
  to cancel the turn with `{:rate_limited, violations}`, or to answer an MCP
  `repl` call with a tool error.
  """

  defexception [:agent_id, :identity, :policy, :usage, :violations]

  @impl Exception
  def message(%__MODULE__{identity: identity, violations: violations}) do
    "rate limit exceeded for #{inspect(identity)}: #{inspect(violations)}"
  end
end
