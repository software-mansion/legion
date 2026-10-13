defmodule Legion.EvalGuard do
  @moduledoc """
  Last check before generated code runs.

  A guard sees the code an agent wrote and decides whether the sandbox may
  evaluate it. It runs after the sandbox's static check accepts the code and
  before the eval process is spawned, so it is the place for policy the
  sandbox cannot express: "never loop over checkout", "no bulk export of the
  orders table". `Legion.Sandbox.Lua` parses inside that process, under its
  limits, so a guard also reviews code that will fail to parse; the Elixir
  sandbox rejects such code before the guard.

      defmodule MyApp.CodeReview do
        @behaviour Legion.EvalGuard

        @impl true
        def check(code, _context) do
          if String.contains?(code, "checkout") and String.contains?(code, "Enum.each") do
            {:deny, "looping over checkout is not allowed - check out once"}
          else
            :allow
          end
        end
      end

  Guards are off unless configured, globally or per agent:

      config :legion, :config, %{eval_guard: MyApp.CodeReview}

      def config, do: %{eval_guard: MyApp.CodeReview}

  `context` carries `:agent`, `:agent_id`, and `:tools` (the modules the code
  may call).

  A `{:deny, reason}` reaches the agent as an execution error, the same path a
  runtime error takes, so it can rewrite the code or explain itself to the
  user. Make the reason something an LLM can act on.

  `Legion.EvalGuard.LLM` writes the guard for you from a policy in plain
  language:

      defmodule MyApp.CodeReview do
        use Legion.EvalGuard.LLM, policy: "Deny code that checks out more than once."
      end

  Guards run on the critical path - the agent waits for every one, so that
  review costs a model round trip on every eval. Prefer returning `:allow`
  and reviewing asynchronously until the async verdicts show blocking is
  worth it.

  A guard that raises, exits, or returns anything other than a verdict is
  itself a denial - a safety boundary that stops working has to stop the code
  with it. The `[:legion, :eval_guard, :denied]` event carries the failure as
  its reason, so a broken guard shows up as every eval being refused. It is
  also logged as an error - nothing the agent does can fix it, so it needs a
  reader who can.
  """

  require Logger

  alias Legion.Telemetry

  @type context :: %{agent: module(), agent_id: Legion.Store.agent_id(), tools: [module()]}

  @callback check(code :: String.t(), context :: context()) :: :allow | {:deny, String.t()}

  @doc false
  def check(nil, _code, _context), do: :allow

  def check(guard, code, context) do
    case verdict(guard, code, context) do
      :allow ->
        :allow

      {:deny, reason} ->
        Telemetry.emit([:legion, :eval_guard, :denied], %{}, %{
          agent: context.agent,
          guard: guard,
          code: code,
          reason: reason
        })

        {:deny, reason}
    end
  end

  defp verdict(guard, code, context) do
    case guard.check(code, context) do
      :allow -> :allow
      {:deny, reason} -> {:deny, reason}
      other -> broken(guard, "the guard returned #{inspect(other)} instead of a verdict")
    end
  rescue
    exception -> broken(guard, "the guard raised #{Exception.message(exception)}")
  catch
    :throw, value -> broken(guard, "the guard threw #{inspect(value)}")
    :exit, reason -> broken(guard, "the guard exited with #{inspect(reason)}")
  end

  # The agent only ever sees "your code was refused", and rewriting the code
  # will not help - a broken guard is the host's bug and has to be visible as
  # one, not as an agent that suddenly cannot run anything.
  defp broken(guard, reason) do
    Logger.error("#{inspect(guard)} failed to return a verdict, denying the eval: #{reason}")
    {:deny, reason}
  end
end
