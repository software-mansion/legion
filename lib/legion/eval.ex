defmodule Legion.Eval do
  @moduledoc """
  Evaluates a piece of LLM-generated code on behalf of an agent.

  This is the single entry point through which any driver (the
  `Legion.Executor` thinking loop, an MCP tool, a test) runs code in an
  agent's sandbox. `run/4` composes everything the agent's config asks for:

    1. Static validation via `c:Legion.Sandbox.check/2`.
    2. The optional `Legion.EvalGuard` review.
    3. Evaluation via `c:Legion.Sandbox.execute/5`, with the timeout, heap,
       reduction and priority limits taken from `config`.

  The whole pipeline runs inside a `[:legion, :sandbox, :eval]` telemetry span,
  so callers get timing and success metadata for free. `bindings` is the
  sandbox-owned state threaded between evaluations (see `Legion.Sandbox`).
  """

  alias Legion.{EvalGuard, Executor, Telemetry}

  @doc """
  Evaluates `code` for `agent_module` using `config` and the current
  `bindings`.

  Returns `{:ok, {value, new_bindings}}` on success, or `{:error, reason}`
  when the static check, the eval guard, or the evaluation itself fails.
  A guard refusal is reported as `{:error, "refused by <guard>: <reason>"}`.
  """
  def run(agent_module, code, config, bindings) do
    Telemetry.span([:legion, :sandbox, :eval], %{agent: agent_module, code: code}, fn ->
      tools = agent_module.tools()

      allowed = tools ++ Enum.flat_map(tools, &extra_allowed_modules/1)

      sandbox_limits = [
        max_heap: config.sandbox_max_heap,
        max_reductions: config.sandbox_max_reductions,
        priority: config.sandbox_priority
      ]

      guard_context = %{agent: agent_module, agent_id: Vault.get(:agent_id), tools: tools}

      with :ok <- config.sandbox.check(code, allowed),
           :allow <- EvalGuard.check(config.eval_guard, code, guard_context),
           {:ok, {value, new_bindings}} <-
             config.sandbox.execute(
               code,
               config.sandbox_timeout,
               allowed,
               bindings,
               sandbox_limits
             ) do
        {{:ok, {value, new_bindings}}, %{success: true, result: value}}
      else
        {:deny, reason} ->
          error = "refused by #{inspect(config.eval_guard)}: #{reason}"
          {{:error, error}, %{success: false, error: error}}

        {:error, error} ->
          {{:error, error}, %{success: false, error: error}}
      end
    end)
  end

  @doc false
  # Renders a successful eval as the text the model reads back: the inspected
  # value (truncated to `max_message_length`) plus the variables now in scope.
  def format_result(result, bindings, config) do
    variable_names = bindings |> config.sandbox.binding_names() |> Enum.map(&"`#{&1}`")

    inspected =
      result
      |> inspect(pretty: true, limit: 1000)
      |> Executor.truncate_content(config[:max_message_length])

    base = """
    Code executed successfully. Result:
    ```
    #{inspected}
    ```
    """

    if variable_names == [] do
      base
    else
      base <> "\nAvailable variables: #{Enum.join(variable_names, ", ")}"
    end
  end

  @doc false
  # Renders any `{:error, reason}` from `run/4` as one line of text.
  def format_error(message) when is_binary(message), do: message
  def format_error(%{message: message}) when is_binary(message), do: message
  def format_error(error) when is_exception(error), do: Exception.message(error)
  def format_error(error), do: inspect(error, pretty: true, limit: 50)

  defp extra_allowed_modules(tool) do
    if function_exported?(tool, :extra_allowed_modules, 0) do
      tool.extra_allowed_modules()
    else
      []
    end
  end
end
