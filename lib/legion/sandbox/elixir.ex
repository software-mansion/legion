defmodule Legion.Sandbox.Elixir do
  @moduledoc """
  Sandboxed Elixir evaluation with AST-level safety checks.

  Evaluates Elixir code strings in a spawned process with:

  - **AST validation** — before evaluation, the code is parsed and walked to reject
    dangerous forms (`defmodule`, `import`, `spawn`, `send`, `receive`, etc.)
    and calls to modules not in the allow-list.
  - **Module allow-list** — only built-in safe modules (Kernel, Enum, Map, String, …)
    and explicitly passed modules may be called. If only some functions from a module
    should be exposed, wrap them in a dedicated facade module.
  - **Timeout and resource limits** — evaluation runs through
    `Legion.Sandbox.Runner`, which kills it on timeout or exceeded
    memory / CPU budgets.

  ## Examples

      iex> {:ok, {4, _}} = Legion.Sandbox.Elixir.execute("2 + 2", 5_000)

      iex> {:ok, {6, _}} = Legion.Sandbox.Elixir.execute("Enum.sum([1, 2, 3])", 5_000)

      iex> {:error, msg} = Legion.Sandbox.Elixir.execute("System.halt()", 5_000)
      iex> msg =~ "Module System is not allowed"
      true

      iex> {:error, msg} = Legion.Sandbox.Elixir.execute("import Enum", 5_000)
      iex> msg =~ "import is not allowed"
      true
  """

  @behaviour Legion.Sandbox

  alias Legion.Sandbox.Elixir.ASTChecker
  alias Legion.Sandbox.Runner

  require EEx

  EEx.function_from_file(:defp, :constraints, Path.join(__DIR__, "elixir/constraints.eex"))

  @doc false
  def default_max_heap, do: Runner.default_max_heap()

  @impl Legion.Sandbox
  def check(code_string, allowed_modules), do: ASTChecker.check(code_string, allowed_modules)

  @impl Legion.Sandbox
  def binding_names(bindings), do: Keyword.keys(bindings)

  @impl Legion.Sandbox
  def prompt_info do
    %{
      language: "Elixir #{System.version()}",
      constraints: constraints(),
      tool_usage:
        "Each tool below is a module aliased to its short name in the sandbox - call it as `ShortName.fun(...)`."
    }
  end

  @doc """
  Evaluates `code_string` in a sandboxed process.

  `timeout_ms` controls the maximum execution time (`:infinity` to disable).
  `allowed_modules` are aliased and made available to the evaluated code
  (on top of the built-in safe modules).

  `limits` bound what the evaluating process may take from the node - see
  `Legion.Sandbox.Runner.run/3`.

  Returns `{:ok, {result, new_bindings}}` on success, or `{:error, reason}` on
  validation failure, runtime exception, crash, timeout, or exceeded limit.
  The returned `new_bindings` can be passed to subsequent calls to preserve
  variable scope.
  """
  @impl Legion.Sandbox
  def execute(code_string, timeout_ms, allowed_modules \\ [], bindings \\ [], limits \\ [])
      when is_binary(code_string) and is_list(allowed_modules) and is_list(limits) and
             (is_integer(timeout_ms) or timeout_ms == :infinity) do
    with :ok <- check(code_string, allowed_modules) do
      env = env_with_aliases(allowed_modules)
      Runner.run(fn -> eval(code_string, bindings, env) end, timeout_ms, limits)
    end
  end

  # Aliases go into the evaluation env rather than being prepended as `alias`
  # lines, so error positions in diagnostics match the code the model wrote.
  defp env_with_aliases(allowed_modules) do
    aliases =
      for module <- allowed_modules, elixir_module?(module) do
        {Module.concat([module |> Module.split() |> List.last()]), module}
      end

    %{Code.env_for_eval([]) | aliases: aliases}
  end

  defp elixir_module?(module), do: String.starts_with?(Atom.to_string(module), "Elixir.")

  # sobelow_skip ["RCE.CodeModule"]
  defp eval(code_string, bindings, env) do
    {result, diagnostics} =
      Code.with_diagnostics(fn ->
        try do
          {value, new_bindings} = Code.eval_string(code_string, bindings, env)
          {:ok, {value, new_bindings}}
        rescue
          e -> {:error, e}
        catch
          :throw, value -> {:error, {:throw, value}}
          :exit, reason -> {:error, {:exit, reason}}
        end
      end)

    attach_diagnostics(result, diagnostics)
  end

  defp attach_diagnostics({:error, %CompileError{}}, [_ | _] = diagnostics) do
    {:error, format_diagnostics(diagnostics)}
  end

  defp attach_diagnostics(result, _diagnostics), do: result

  defp format_diagnostics(diagnostics) do
    Enum.map_join(diagnostics, "\n", fn diag ->
      "#{format_position(diag.position)}: #{diag.message}"
    end)
  end

  defp format_position({line, column}), do: "#{line}:#{column}"
  defp format_position(line) when is_integer(line), do: "#{line}"
  defp format_position(_), do: "?"
end
