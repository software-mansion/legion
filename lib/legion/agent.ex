defmodule Legion.Agent do
  @moduledoc """
  `use Legion.Agent` to define your agent.

  ## Example

      defmodule MyAgent do
        @moduledoc "Researches topics and summarises findings."

        use Legion.Agent

        def tools, do: [MyApp.SearchTool, Legion.Tools.HumanTool]

        def tool_config(Legion.Tools.HumanTool), do: [handler: MyApp.ChatHandler, timeout: 30_000]

        def output_schema, do: %{"type" => "object", "properties" => %{"summary" => %{"type" => "string"}}}
      end

  ## Callbacks

  All callbacks are optional.

    - `tools/0` — list of tool modules available to the agent. Each tool's
      `tool_config/1` result is stored in the Vault under the tool's module key.
      Defaults to `[]`.

    - `tool_config/1` — per-tool configuration. Receives a tool module, returns a
      keyword list. The returned options are accessible to the tool at runtime via
      `Vault.get(__MODULE__)`. Defaults to `[]` for all tools.

    - `system_prompt/0` — override to return a fully custom system prompt. When
      not defined, the prompt is auto-generated from `@moduledoc`, tool source
      code, and the resolved `binding_scope`.

    - `output_schema/0` — JSON Schema map describing the agent's structured output.
      Used by the LLM for the `result` field. Defaults to `%{"type" => "string"}`.

    - `config/0` — agent-level configuration merged with application config and
      call-time opts. Defaults to `%{}`. Available keys:
      - `model` — LLM model identifier (default: `"openai:gpt-5.4"`)
      - `sandbox` — a `Legion.Sandbox` module that validates and evaluates the
        code the agent writes. `Legion.Sandbox.Lua` (the default) evaluates Lua
        in a pure-Elixir VM where only bridged tool functions can reach the
        host; `Legion.Sandbox.Elixir` evaluates Elixir behind an AST allowlist
        (default: `Legion.Sandbox.Lua`)
      - `max_iterations` — max successful execution steps per turn (default: `10`)
      - `max_retries` — max consecutive failures before giving up (default: `3`)
      - `sandbox_timeout` — timeout in ms for code execution. Set `:infinity` to
        disable it, leaving `sandbox_max_reductions` as the only limit that stops
        an eval that never returns (default: `60_000`)
      - `sandbox_max_heap` — memory budget in bytes for the process evaluating
        generated code. The VM kills the eval when its heap and stack exceed the
        budget; the binaries it references are polled separately (~50ms granularity)
        because they live off-heap, so an eval can briefly hold up to twice the
        budget. Also covers tool code called inline from the eval. Set `:infinity`
        to disable (default: `256_000_000`)
      - `eval_guard` — a `Legion.EvalGuard` module that vets generated code before
        it runs, for policy the sandbox cannot express. Runs on the critical path;
        a denial reaches the agent as an execution error (default: `nil`, no guard)
      - `sandbox_max_reductions` — CPU budget in reductions for the eval process,
        enforced by polling (~50ms granularity), so an eval that computes hard gets
        killed even while the wall clock is fine with it. Counts tool code called
        inline from the eval too. Set `:infinity` to disable (default: `:infinity`)
      - `sandbox_priority` — scheduler priority of the eval process, and so of any
        tool code it calls inline. The default keeps generated code from crowding
        out the rest of the node, at the cost of it taking longer under load -
        raise it to `:normal` if evals are hitting `sandbox_timeout` on a busy
        system (default: `:low`)
      - `binding_scope` — how long variable bindings from code execution live
        (default: `:turn`):
        - `:iteration` — bindings reset between every code execution
        - `:turn` — bindings persist across iterations within one turn, reset between turns
        - `:conversation` — bindings persist for the entire conversation (across turns)
      - `max_message_length` — max byte size of a single message added to the
        conversation (user input, code execution result, or error text). Longer
        content is truncated with a `[... truncated N bytes ...]` marker.
        Applies to text content only: each text part of a multipart message is
        truncated individually, while image data and URLs pass through untouched.
        Defaults to `20_000`. Set to `:infinity` to disable truncation.

    - `action_types/0` — list of action strings the LLM is allowed to respond with.
      Defaults to all four: `~w(eval_and_continue eval_and_complete return done)`.
      Override to restrict the agent - for example, a read-only agent that should
      never execute code can use `~w(return done)`.
  """

  @callback tools() :: [module()]
  @callback tool_config(tool :: atom()) :: keyword()
  @callback system_prompt() :: String.t()
  @callback output_schema() :: map()
  @callback config() :: map()
  @callback action_types() :: [String.t()]
  @optional_callbacks tools: 0,
                      tool_config: 1,
                      system_prompt: 0,
                      output_schema: 0,
                      config: 0,
                      action_types: 0

  require Logger

  defmacro __using__(_opts) do
    quote do
      @behaviour Legion.Agent
      @before_compile Legion.Agent

      def tools, do: []
      def output_schema, do: %{"type" => "string"}
      def config, do: %{}
      def action_types, do: ~w(eval_and_continue eval_and_complete return done)

      def child_spec(opts) do
        %{
          id: __MODULE__,
          start: {Legion, :start_link, [__MODULE__, opts]},
          restart: :transient
        }
      end

      defoverridable tools: 0,
                     output_schema: 0,
                     config: 0,
                     action_types: 0
    end
  end

  @known_config_keys ~w(binding_scope eval_guard max_iterations max_message_length max_retries model sandbox sandbox_max_heap sandbox_max_reductions sandbox_priority sandbox_timeout start_mode)a

  @doc false
  # Resolves the effective config for `agent_module`: Executor defaults, then the
  # `:legion, :config` app env, then `agent_module.config/0`, then `opts`. Warns
  # about unknown keys and validates `:max_message_length`. Shared by every
  # driver that runs the agent (AgentServer, Legion.MCP.Server).
  def resolve_config(agent_module, opts \\ []) do
    app_config = Application.get_env(:legion, :config, %{})
    call_config = Map.new(opts)

    merged =
      Legion.Executor.default_config()
      |> Map.merge(app_config)
      |> Map.merge(agent_module.config())
      |> Map.merge(call_config)

    unknown = Map.keys(merged) -- @known_config_keys

    if unknown != [] do
      Logger.warning("Unknown Legion config keys: #{inspect(unknown)}")
    end

    validate_max_message_length(merged)

    merged
  end

  @doc false
  # Seeds the calling process's Vault with each tool's `tool_config/1`, so tools
  # can read their options via `Vault.get(__MODULE__)` from sandboxed code.
  def seed_tool_configs(agent_module) do
    for tool <- agent_module.tools() do
      Vault.unsafe_put(tool, agent_module.tool_config(tool))
    end

    :ok
  end

  defp validate_max_message_length(%{max_message_length: :infinity}), do: :ok

  defp validate_max_message_length(%{max_message_length: n}) when is_integer(n) and n > 0,
    do: :ok

  defp validate_max_message_length(%{max_message_length: other}) do
    raise ArgumentError,
          "expected :max_message_length to be a positive integer or :infinity, got: #{inspect(other)}"
  end

  defp validate_max_message_length(_config), do: :ok

  defmacro __before_compile__(env) do
    moduledoc = Module.get_attribute(env.module, :moduledoc)

    doc =
      case moduledoc do
        {_line, doc} when is_binary(doc) and doc != "" -> doc
        _ -> nil
      end

    unless doc do
      raise CompileError,
        description: "#{inspect(env.module)} must define a @moduledoc",
        file: env.file,
        line: 0
    end

    quote do
      def moduledoc, do: unquote(doc)

      def tool_config(_tool), do: []
    end
  end
end
