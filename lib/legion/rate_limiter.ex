defmodule Legion.RateLimiter do
  @moduledoc """
  Behaviour for enforcing rate limits across Legion agents.

  A rate limiter decides whether an agent may proceed under a list of
  `Legion.RateLimiter.Rule`s. Each rule pairs an identity - the group of
  agents sharing a limit - with a `Legion.RateLimiter.Policy`. Legion calls
  `enforce!/2` for you: configure a limiter and rules, and every turn is
  checked against them.

      Legion.start_link(ChatAgent,
        rate_limit: [
          limiter: MyApp.RateLimiter,
          rules: [
            %Legion.RateLimiter.Rule{
              identity: %{"ip" => "203.0.113.42", "tenant" => "acme"},
              policy: %Legion.RateLimiter.Policy{
                window_ms: :timer.minutes(30),
                max_agents: 40,
                max_tokens: 200_000
              }
            },
            %Legion.RateLimiter.Rule{
              identity: %{"email" => "someone@example.com"},
              policy: %Legion.RateLimiter.Policy{window_ms: :timer.hours(24), max_agents: 5}
            }
          ]
        ]
      )

  A turn runs only if every rule allows it; the first rule that denies it
  cancels the turn. Rules are evaluated in the order given, so put the rule
  whose denial you want reported first.

  For Postgres users there is a ready-made adapter - see
  `Legion.RateLimiter.Postgres`. It extends `Legion.Store.Postgres`, keeping
  rate-limit metadata in the store's table and counting the usage persisted
  there:

      defmodule MyApp.RateLimiter do
        use Legion.RateLimiter.Postgres, repo: MyApp.Repo
      end

  ## Configuration

  The limiter and a default policy can be set globally, leaving only the
  identities to the call site:

      config :legion, :rate_limit,
        limiter: MyApp.RateLimiter,
        default_policy: %Legion.RateLimiter.Policy{window_ms: :timer.minutes(1), max_agents: 10}

      Legion.start_link(ChatAgent,
        rate_limit: [rules: [%Legion.RateLimiter.Rule{identity: %{"ip" => "203.0.113.42"}}]]
      )

  A rule given without a `:policy` takes the default one. Rules belong to the
  call site: the application config accepts `:limiter` and `:default_policy`.
  Rate limiting applies only when a limiter and at least one rule resolve.
  Rules without a limiter raise. A limiter without rules runs the agent without
  rate limiting and logs a warning - pass `rules: []` to opt out on purpose
  and silence it. Unknown keys in either place are logged and ignored.
  Sub-agents inherit whatever their parent resolved - a parent started
  without rate limiting runs its whole subtree without it, and rules given
  below it raise rather than re-enable it. Each sub-agent is a separate agent
  ID in every group, so it counts towards `:max_agents`, towards
  `:max_running_agents` while its turn runs, and its usage towards
  `:max_tokens`.

  Rules must agree on their identities: two rules may share a field only with
  the same value, since the adapter records one group membership per agent.
  Two rules with the same identity and different policies are fine - for
  example a per-minute and a per-day window on one IP. Identity keys must be
  strings; an empty identity `%{}` matches every agent and acts as a global cap.

  ## When Legion enforces

  Enforcement happens once per turn, before the incoming message is appended
  and before any LLM request. A denial therefore leaves the conversation
  untouched and costs nothing.

  Denied turns return `{:cancel, {:rate_limited, violations}}` - the same
  shape as `{:cancel, :reached_max_iterations}` - so a denied sub-agent
  reports back to its caller as a value rather than a crash. Legion also emits
  `[:legion, :rate_limit, :exceeded]` with the identity and policy of the rule
  that denied it; see `Legion.Telemetry`.

  Resumed and recovered runs are *not* checked again. They are finishing work
  that was already allowed, so checking it again would discard accepted work
  instead of shedding new load.

  ## Calling it yourself

  `resolve!/1` and `enforce!/2` are public, so an application can rate-limit its
  own work - a webhook, a queue worker - under the same configuration as
  agents. Resolve the configured limiter and rules, which fills in the
  default policy, then enforce them under a stable id:

      %{limiter: limiter, rules: rules} =
        Legion.RateLimiter.resolve!(
          rules: [%Legion.RateLimiter.Rule{identity: %{"ip" => "203.0.113.42"}}]
        )

      if limiter, do: :ok = limiter.enforce!(agent_id, rules)

  A `nil` limiter means rate limiting is off. An adapter can also be called
  directly with complete rules, skipping `resolve!/1`.

  ## Implementing a rate limiter

  Define a module that implements `enforce!/2` when rate-limit state lives
  outside Postgres or needs application-specific coordination:

      defmodule MyApp.RateLimiter do
        @behaviour Legion.RateLimiter

        @impl Legion.RateLimiter
        def enforce!(agent_id, rules) do
          # Check and record the rate-limit state for every rule, atomically.
          :ok
        end
      end

  An adapter receives all of an agent's rules in one call so it can allow or
  deny the call as a unit. See `Legion.RateLimiter.Rule`,
  `Legion.RateLimiter.Policy`, and `Legion.RateLimiter.Postgres`.
  """
  require Logger

  alias Legion.RateLimiter.Rule
  alias Legion.Store

  @type limit_identity :: %{String.t() => any()}

  @doc """
  Enforces every rule in `rules` for the agent identified by `agent_id`.

  Returns `:ok` when every rule allows the call, and the agent counts towards
  each rule's limits from then on; a denied call counts for nothing. Rules are
  allowed together or denied together, never one by one. How identities match
  and where that state lives is up to the adapter.

  Raises `Legion.RateLimiter.ExceededError` for the first rule, in list order,
  that is exceeded. Legion catches that exception and cancels the turn; any
  other error propagates, so an adapter that cannot reach its backing store
  fails the agent rather than silently allowing the call.
  """
  @callback enforce!(
              agent_id :: Store.agent_id(),
              rules :: [Rule.t()]
            ) ::
              :ok | no_return()

  @off %{limiter: nil, rules: []}
  @override_keys [:limiter, :rules]
  @app_config_keys [:limiter, :default_policy]

  @doc """
  Resolves the limiter and rules to enforce.

  Reads the application's `:rate_limit` config and applies `overrides`, a
  keyword list with `:limiter` and `:rules`, on top. Each key given in
  `overrides` replaces the configured value wholesale - rules are never
  merged one by one. When called inside an agent, the rate limit that agent
  resolved sits between the two, so overrides win over it and it wins over
  the application config.

  Rules given without a `:policy` take the configured `:default_policy`. A
  policy that is present is used as is; missing fields are not filled in.

  Returns `%{limiter: module | nil, rules: [Legion.RateLimiter.Rule.t()]}`.
  With no limiter and no rules the result is `%{limiter: nil, rules: []}`,
  meaning rate limiting is off. A limiter without rules resolves to the same
  and logs a warning, unless `overrides` gives `rules: []` explicitly.

  Raises `ArgumentError` when `overrides` is not `nil` or a keyword list, when
  rules are given without a limiter, when `:rules` is not a list of
  `Legion.RateLimiter.Rule` structs, when a rule fails
  `Legion.RateLimiter.Rule.validate!/1`, or when two rules give one identity
  key different values. Keys other than `:limiter` and `:rules` in
  `overrides`, or other than `:limiter` and `:default_policy` in the
  application config, are logged and ignored.

  ## Examples

      # config :legion, :rate_limit, limiter: MyApp.RateLimiter, default_policy: policy
      Legion.RateLimiter.resolve!(rules: [%Legion.RateLimiter.Rule{identity: %{"ip" => ip}}])
      #=> %{limiter: MyApp.RateLimiter, rules: [%Legion.RateLimiter.Rule{identity: %{"ip" => ip}, policy: policy}]}

      Legion.RateLimiter.resolve!(nil)
      #=> %{limiter: nil, rules: []}
  """
  def resolve!(nil), do: resolve!([])

  def resolve!(overrides) when is_list(overrides) do
    overrides = known_keys!(overrides, @override_keys, ":rate_limit")

    app_config =
      known_keys!(
        Application.get_env(:legion, :rate_limit, []),
        @app_config_keys,
        "config :legion, :rate_limit"
      )

    overrides = fill_policies(overrides, Keyword.get(app_config, :default_policy))

    @off
    |> Map.merge(layer(app_config))
    |> Map.merge(layer(Vault.get(:rate_limit) || %{}))
    |> Map.merge(layer(overrides))
    |> finish!(Keyword.has_key?(overrides, :rules))
  end

  def resolve!(other) do
    raise ArgumentError,
          "expected :rate_limit to be a keyword list or nil, got: #{inspect(other)}"
  end

  defp fill_policies(overrides, default_policy) do
    case Keyword.fetch(overrides, :rules) do
      {:ok, rules} when is_list(rules) ->
        Keyword.put(overrides, :rules, Enum.map(rules, &fill(&1, default_policy)))

      {:ok, other} ->
        raise ArgumentError, "expected :rules to be a list, got: #{inspect(other)}"

      :error ->
        overrides
    end
  end

  defp fill(%Rule{policy: nil} = rule, default_policy), do: %{rule | policy: default_policy}
  defp fill(%Rule{} = rule, _default_policy), do: rule

  defp fill(other, _default_policy),
    do: raise(ArgumentError, "expected a #{inspect(Rule)} in :rules, got: #{inspect(other)}")

  defp known_keys!(config, allowed, source) do
    unless Keyword.keyword?(config) do
      raise ArgumentError, "expected #{source} to be a keyword list, got: #{inspect(config)}"
    end

    {known, unknown} = Keyword.split(config, allowed)

    if unknown != [] do
      Logger.warning(
        "#{source} ignores unknown keys #{inspect(Enum.uniq(Keyword.keys(unknown)))}; " <>
          "allowed keys are #{inspect(allowed)}"
      )
    end

    known
  end

  defp layer(config), do: config |> Map.new() |> Map.take(@override_keys)

  defp finish!(%{limiter: limiter, rules: rules}, explicit_rules?) do
    Enum.each(rules, &Rule.validate!/1)
    validate_identities!(rules)

    case {limiter, rules} do
      {nil, []} ->
        @off

      {nil, _rules} ->
        raise ArgumentError,
              "rate-limit rules need a limiter - pass `limiter: MyLimiter`, set " <>
                "`config :legion, :rate_limit, limiter: MyLimiter`, or drop the rules " <>
                "when the parent agent runs without rate limiting"

      {limiter, []} ->
        unless explicit_rules? do
          Logger.warning(
            "#{inspect(limiter)} is configured but no rules were given, so this agent " <>
              "runs without rate limiting; pass `rules: [...]`, or `rules: []` to opt " <>
              "out on purpose (as `rate_limit: [rules: ...]` when starting an agent)"
          )
        end

        @off

      {limiter, rules} ->
        %{limiter: limiter, rules: rules}
    end
  end

  defp validate_identities!(rules) do
    Enum.reduce(rules, %{}, fn rule, seen ->
      Map.merge(seen, rule.identity, fn key, a, b ->
        a == b ||
          raise ArgumentError,
                "rate-limit rules disagree on #{inspect(key)}: #{inspect(a)} vs #{inspect(b)}"

        a
      end)
    end)
  end
end
