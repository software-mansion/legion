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
    4. A size check of the variables the code leaves behind against
       `:max_bindings_bytes`.

  The whole pipeline runs inside a `[:legion, :sandbox, :eval]` telemetry span,
  so callers get timing and success metadata for free. `bindings` is the
  sandbox-owned state threaded between evaluations (see `Legion.Sandbox`).
  """

  alias Legion.{EvalGuard, Executor, Telemetry}

  @doc """
  Evaluates `code` for `agent_module` using `config` and the current
  `bindings`.

  Returns `{:ok, {value, new_bindings}}` on success, or `{:error, reason}`
  when the static check, the eval guard, or the evaluation itself fails, or
  when the variables it leaves behind would exceed `:max_bindings_bytes`; the
  previous bindings stand in that case, as after any error.
  A guard refusal is reported as `{:error, "refused by <guard>: <reason>"}`.
  """
  def run(agent_module, code, config, bindings) do
    Telemetry.span([:legion, :sandbox, :eval], %{agent: agent_module, code: code}, fn ->
      tools =
        Enum.uniq((agent_module.tools() -- Vault.get(:excluded_tools, [])) ++ [Legion.Tools.Help])

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
             ),
           :ok <- check_bindings_size(new_bindings, config) do
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
  # value plus the variables now in scope, each truncated to `max_message_length`.
  # `inspect` has its own cap on strings, 4096 characters by default, so it is
  # raised to the configured one; the byte-level truncation below still rules.
  def format_result(result, bindings, config) do
    variable_names = bindings |> config.sandbox.binding_names() |> Enum.map(&"`#{&1}`")
    max_length = config[:max_message_length] || :infinity

    inspected =
      result
      |> inspect(pretty: true, limit: 1000, printable_limit: max_length)
      |> Executor.truncate_content(max_length)

    base = """
    Code executed successfully. Result:
    ```
    #{inspected}
    ```
    """

    if variable_names == [] do
      base
    else
      variables = variable_names |> Enum.join(", ") |> Executor.truncate_content(max_length)
      base <> "\nAvailable variables: #{variables}"
    end
  end

  @doc false
  # Renders any `{:error, reason}` from `run/4` as one line of text. Code can
  # raise any bytes, and the text goes to an LLM or an MCP host as JSON, so
  # whatever is not UTF-8 is replaced.
  def format_error(error), do: error |> error_text() |> String.replace_invalid()

  defp error_text(message) when is_binary(message), do: message
  defp error_text(%{message: message}) when is_binary(message), do: message
  defp error_text(error) when is_exception(error), do: Exception.message(error)
  defp error_text(error), do: inspect(error, pretty: true, limit: 50)

  # `:iteration` drops the variables after every execution, so their size
  # never matters.
  defp check_bindings_size(_bindings, %{binding_scope: :iteration}), do: :ok

  defp check_bindings_size(bindings, %{max_bindings_bytes: max}) when is_integer(max) do
    size = :erlang.external_size(bindings)

    if size > max do
      {:error,
       "variables would take #{size} bytes, over the #{max} byte limit; " <>
         "the result was discarded, keep less in variables"}
    else
      :ok
    end
  end

  defp check_bindings_size(_bindings, _config), do: :ok

  defp extra_allowed_modules(tool) do
    if function_exported?(tool, :extra_allowed_modules, 0) do
      tool.extra_allowed_modules()
    else
      []
    end
  end
end
