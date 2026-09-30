defmodule Legion.EvalGuard.LLM do
  @moduledoc """
  A `Legion.EvalGuard` that asks a model whether the code may run.

  Define a guard with a policy written in plain language:

      defmodule MyApp.CodeReview do
        use Legion.EvalGuard.LLM,
          policy: \"\"\"
          Deny code that checks out more than once, exports the whole orders
          table, or reads a cart that is not the current conversation's.
          \"\"\"
      end

      def config, do: %{eval_guard: MyApp.CodeReview}

  Options are `:policy` and `:model` (which defaults to Legion's built-in
  default model, regardless of the model the agent is configured with). The reviewing model sees the policy, the agent's name, the
  tool modules the code may call, and the code itself - not the conversation.

  Without a `:policy` the guard falls back to `default_policy/0`, which denies
  code that goes after the host rather than the task - shelling out, touching
  the filesystem or the network directly, reaching into other processes or the
  runtime:

      defmodule MyApp.HostGuard do
        use Legion.EvalGuard.LLM
      end

  The sandbox already blocks the modules that do most of this, so the default
  earns its keep against what an allowed tool can be talked into.

  This is a blocking review: the agent waits for a second model round trip on
  every eval. Read the latency note in `Legion.EvalGuard` before reaching for
  it. If the review request fails, the code is denied, per the same module's
  rule that a broken guard denies.
  """

  alias Legion.Executor

  @default_policy """
  Deny code that acts on the machine or the runtime instead of the task:

  - running shell commands, spawning OS processes, or loading native code
  - reading, writing or deleting files outside what a tool exposes
  - opening its own network connections, or sending data to an address the
    code itself chose
  - reading credentials, environment variables, or application config
  - reaching into other processes or nodes, killing them, or changing runtime
    state (tracing, code loading, system flags)
  - consuming the machine on purpose: unbounded recursion or loops, allocating
    huge terms, sleeping for a long time

  Allow ordinary work: arithmetic, data shuffling, and calls to the tool
  modules the agent was given, including ones that happen to touch files or
  the network on the agent's behalf.
  """

  @verdict_schema %{
    "type" => "object",
    "required" => ["verdict", "reason"],
    "additionalProperties" => false,
    "properties" => %{
      "verdict" => %{"type" => "string", "enum" => ["allow", "deny"]},
      "reason" => %{
        "type" => "string",
        "description" =>
          "Why the code was denied, addressed to the agent that wrote it, so it can " <>
            "write something acceptable instead. Empty string when allowing."
      }
    }
  }

  defmacro __using__(opts) do
    quote do
      @behaviour Legion.EvalGuard

      @impl true
      def check(code, context), do: unquote(__MODULE__).review(code, context, unquote(opts))

      defoverridable check: 2
    end
  end

  @doc """
  The policy used when a guard does not give one: deny code that goes after the
  host rather than the task.

  Useful as a starting point for your own - `policy: default_policy() <> "..."`.
  """
  def default_policy, do: @default_policy

  @doc false
  def review(code, context, opts) do
    model = Keyword.get(opts, :model, Executor.default_config().model)
    policy = Keyword.get(opts, :policy, @default_policy)

    messages = [
      Executor.message(:system, system_prompt(policy, context)),
      Executor.message(:user, code)
    ]

    case ReqLLM.generate_object(model, messages, @verdict_schema,
           telemetry: Executor.telemetry_opts()
         ) do
      {:ok, %{object: %{"verdict" => "allow"}}} -> :allow
      {:ok, %{object: %{"verdict" => "deny", "reason" => reason}}} -> {:deny, reason}
      {:ok, response} -> {:deny, "the review returned #{inspect(response)}"}
      {:error, reason} -> {:deny, "the review request failed: #{inspect(reason)}"}
    end
  end

  defp system_prompt(policy, context) do
    """
    You are reviewing code an AI agent wrote, before it runs in a sandbox.
    Allow anything the policy does not forbid - you are the last check, not the
    only one, and a wrongly denied eval costs the agent a turn.

    Policy:
    #{policy}

    The code was written by #{inspect(context.agent)} and may call these modules:
    #{Enum.map_join(context.tools, ", ", &inspect/1)}
    """
  end
end
