defmodule Legion.RateLimiter.Policy do
  @moduledoc """
  Defines the limits enforced by a `Legion.RateLimiter`.

  Every policy has a rolling `:window_ms`. Within that window, it can
  limit new agents matching an identity, how many of them run a turn at
  once, recorded token usage for those agents, or any combination:

      %Legion.RateLimiter.Policy{
        window_ms: :timer.minutes(1),
        max_agents: 10,
        max_running_agents: 2,
        max_tokens: 100_000
      }

  ## Limits

    * `:window_ms` (required) - positive rolling-window duration in
      milliseconds.
    * `:max_agents` - maximum number of matching agent IDs started during the
      window, including sub-agents. `0` allows no agents; `nil` disables this
      limit.
    * `:max_running_agents` - maximum number of matching agents mid-turn at
      the same time, including sub-agents. A turn's usage is recorded only
      when it ends, so this is the limit that bounds how far one window can
      overshoot `:max_tokens`. `0` allows no turns; `nil` disables this limit.
    * `:max_tokens` - maximum recorded token total for matching agents during
      the window. Limits are checked when a turn starts and never interrupt
      a running turn, so one turn can carry the recorded total past the
      maximum before the next one is denied. `0` accepts no tokens and so
      denies every turn; `nil` disables this limit.

  A policy with every optional limit set to `nil` is unrestricted. See
  `Legion.RateLimiter` for the adapter interface and
  `Legion.RateLimiter.Postgres` for the bundled implementation.
  """

  @enforce_keys [:window_ms]
  defstruct [:window_ms, :max_agents, :max_running_agents, :max_tokens]

  @type t :: %__MODULE__{
          window_ms: pos_integer(),
          max_agents: non_neg_integer() | nil,
          max_running_agents: non_neg_integer() | nil,
          max_tokens: non_neg_integer() | nil
        }

  @doc """
  Returns `:ok` when `policy` is a usable policy.

  Raises `ArgumentError` naming the offending field otherwise. Legion calls
  this when an agent starts, so a misconfigured policy fails at the agent that
  configured it rather than at the first limit evaluation.
  """
  def validate!(%__MODULE__{} = policy) do
    validate_window!(policy.window_ms)
    validate_limit!(:max_agents, policy.max_agents)
    validate_limit!(:max_running_agents, policy.max_running_agents)
    validate_limit!(:max_tokens, policy.max_tokens)

    :ok
  end

  def validate!(other) do
    raise ArgumentError,
          "expected a #{inspect(__MODULE__)} struct, got: #{inspect(other)}"
  end

  defp validate_window!(window_ms) when is_integer(window_ms) and window_ms > 0, do: :ok

  defp validate_window!(other) do
    raise ArgumentError,
          "expected :window_ms to be a positive integer, got: #{inspect(other)}"
  end

  defp validate_limit!(_name, nil), do: :ok
  defp validate_limit!(_name, limit) when is_integer(limit) and limit >= 0, do: :ok

  defp validate_limit!(name, other) do
    raise ArgumentError,
          "expected #{inspect(name)} to be a non-negative integer or nil, got: #{inspect(other)}"
  end
end
