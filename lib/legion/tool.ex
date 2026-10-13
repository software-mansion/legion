defmodule Legion.Tool do
  @moduledoc """
  `use Legion.Tool` to mark a module as a tool available to agents.

  By default, `description/0` returns the module's source code so the LLM
  knows what functions are available. An agent running with
  `tool_docs: :on_demand` (see `Legion.Agent`) first sees only each tool's
  `summary/0`, one sentence, and reads the full description with
  `Help.help(Name)` when it needs it.

  ## Overridable

    - `description/0` - override to return a hand-written summary **instead of**
      the source code. Defaults to the module's source code.
    - `description/1` - like `description/0`, but receives the active sandbox
      module, for tools whose usage differs by generated language. Preferred
      over `description/0` when defined.
    - `summary/0` - override to return the one sentence that stands for the tool
      in the tool list under `tool_docs: :on_demand`. Defaults to the first
      sentence of the `@moduledoc`, else of a hand-written `description/0`, else
      the module's short name. The example below has no `@moduledoc`, so its
      summary is `WeatherTool - fetches current weather data.` Mark an
      override `@impl Legion.Tool`: an unmarked `summary/0`, perhaps a tool
      function that was there first, gets a compile-time warning, since
      Legion takes it over and Lua code cannot call it.
    - `extra_allowed_modules/0` - override to return additional modules that the
      sandbox should alias and permit when this tool is available. Defaults to `[]`.
      Useful for tools like `Legion.Tools.AgentTool` that dispatch to other modules
      the agent needs to reference by name.
    - `mcp?/0` - override to return `false` to leave the tool out when the
      agent is served over `Legion.MCP.Server`, where an outside caller writes
      the code. Defaults to `true`.

  ## Example

      defmodule MyApp.WeatherTool do
        use Legion.Tool

        def description do
          \"""
          WeatherTool - fetches current weather data.

          ## Functions
          - `current(city)` - returns weather JSON for the given city name.
          \"""
        end

        @doc "Returns current weather for a city."
        def current(city) do
          Req.get!("https://wttr.in/\#{city}?format=j1").body
        end
      end

  ## Reading from Vault

  A map after a function head binds values from `Vault`, keyed as they were
  stored, before the body runs. The function keeps its arity, so the LLM
  cannot pass the values in:

      def orders(status), %{current_user: user} do
        MyApp.Orders.list(user, status)
      end

  A key's value can be destructured further with a nested map:

      def orders(status), %{current_user: %{id: user_id}} do
        MyApp.Orders.list(user_id, status)
      end

  Every key, at any depth, must bind a plain variable, and each variable
  name can be used only once - a literal, a pin, or a repeated name
  instead raises a `CompileError`, since any of them would make the
  match depend on a Vault value instead of just its presence. A key
  missing from Vault, or a value that isn't a map where the pattern
  expects one, raises an error that names neither the key nor its
  value, so a misconfigured tool fails without exposing other Vault
  values to the LLM.

  ## External modules as tools

  A module that does not `use Legion.Tool` (e.g. `Req`) can still be listed as
  a tool if its source code is registered at compile time, so the LLM can read
  what it offers:

      config :legion, extra_source_modules: [Req]
  """

  require Logger

  @doc "Description of the tool shown to the LLM. Defaults to the module's source code."
  @callback description() :: String.t()

  @doc """
  Description of the tool for the given sandbox, shown to the LLM. Preferred
  over `c:description/0` when defined, so a tool can tailor its usage notes
  to the generated language.
  """
  @callback description(sandbox :: module()) :: String.t()

  @doc """
  One sentence that stands for the tool in the tool list under
  `tool_docs: :on_demand`. Defaults to the first sentence of the `@moduledoc`,
  else of a hand-written `description/0`, else the module's short name.
  """
  @callback summary() :: String.t()
  @callback extra_allowed_modules() :: [module()]

  @doc "Whether `Legion.MCP.Server` serves the tool. Defaults to `true`."
  @callback mcp?() :: boolean()

  @optional_callbacks description: 1

  defmacro __using__(_opts) do
    source = extract_module_source(File.read!(__CALLER__.file), __CALLER__.module)

    quote do
      @behaviour Legion.Tool
      @before_compile Legion.Tool
      @on_definition Legion.Tool

      import Legion.Tool, only: [def: 3]

      def description, do: unquote(source)
      def extra_allowed_modules, do: []
      def mcp?, do: true

      defoverridable description: 0, extra_allowed_modules: 0, mcp?: 0
    end
  end

  @doc """
  Defines a function whose body sees the Vault values named in `pattern`.
  See "Reading from Vault" above.
  """
  defmacro def(head, {:%{}, _meta, pairs} = pattern, blocks) do
    tool = __CALLER__.module
    function = Macro.to_string(head)
    reject_repeated_vars!(pairs)

    # One read, so the checks and the match see the same map.
    vault = Macro.var(:vault, __MODULE__)
    checks = vault_checks(pairs, vault, [], tool, function)
    keys = for {key, _binding} <- pairs, do: key

    # blocks is just :do - try requires at least one of rescue/catch/after/else
    inner = if Keyword.keys(blocks) == [:do], do: blocks[:do], else: {:try, [], [blocks]}

    body =
      quote do
        unquote(vault) = Vault.take(unquote(keys))
        unquote_splicing(checks)
        unquote(pattern) = unquote(vault)
        unquote(inner)
      end

    quote do
      Kernel.def(unquote(head), do: unquote(body))
    end
  end

  # Checks every key up front so pattern's final match can never fail.
  defp vault_checks(pairs, level_expr, path, tool, function) do
    classified = classify!(pairs)

    leaf_keys = for {:leaf, key, _name} <- classified, do: key
    nested = for {:nested, key, inner_pairs} <- classified, do: {key, inner_pairs}
    nested_keys = for {key, _inner_pairs} <- nested, do: key

    level_check =
      quote do
        Legion.Tool.__check_vault__(
          unquote(level_expr),
          unquote(leaf_keys),
          unquote(nested_keys),
          unquote(tool),
          unquote(function),
          unquote(path)
        )
      end

    nested_checks =
      Enum.flat_map(nested, fn {key, inner_pairs} ->
        child_expr = quote(do: Map.get(unquote(level_expr), unquote(key), %{}))
        vault_checks(inner_pairs, child_expr, path ++ [key], tool, function)
      end)

    [level_check | nested_checks]
  end

  defp classify!(pairs) do
    for {key, binding} <- pairs do
      case binding do
        {name, _meta, context} when is_atom(name) and is_atom(context) ->
          {:leaf, key, name}

        {:%{}, _meta, inner_pairs} ->
          {:nested, key, inner_pairs}

        other ->
          raise CompileError,
            description:
              "def/3 only binds plain variables or nested maps from Vault, got `#{Macro.to_string(other)}` for key #{inspect(key)}"
      end
    end
  end

  @doc false
  # The agent is told nothing: the key names go to the operator, the only one
  # who can fix this.
  def __check_vault__(level, leaf_keys, nested_keys, tool, function, path) do
    missing =
      (leaf_keys -- Map.keys(level)) ++
        for key <- nested_keys, not is_map(Map.get(level, key)), do: key

    if missing != [] do
      Legion.Telemetry.emit([:legion, :tool, :vault_mismatch], %{}, %{
        tool: tool,
        function: function,
        path: path,
        missing: missing
      })

      Logger.error(
        "#{inspect(tool)}.#{function} is missing Vault key(s) #{inspect(missing)} at #{inspect(path)} - nothing the agent does can fix this"
      )

      raise "this tool cannot succeed for this call and will fail the same way every time; do not retry it"
    end
  end

  # A repeated name makes the second occurrence an equality check instead of a
  # bind, failing with a MatchError that names every Vault value.
  defp reject_repeated_vars!(pairs) do
    names = pairs |> leaf_var_names() |> Enum.reject(&(&1 == :_))
    repeated = names -- Enum.uniq(names)

    if repeated != [] do
      raise CompileError,
        description:
          "def/3 binds Vault variable(s) #{inspect(Enum.uniq(repeated))} more than once"
    end
  end

  defp leaf_var_names(pairs) do
    Enum.flat_map(classify!(pairs), fn
      {:leaf, _key, name} -> [name]
      {:nested, _key, inner_pairs} -> leaf_var_names(inner_pairs)
    end)
  end

  @doc false
  defmacro __before_compile__(env) do
    unless Module.defines?(env.module, {:summary, 0}) do
      sentence =
        case Module.get_attribute(env.module, :moduledoc) do
          {_line, doc} when is_binary(doc) -> first_sentence(doc)
          _ -> nil
        end

      quote do
        @legion_generated_summary true
        def summary, do: Legion.Tool.default_summary(__MODULE__, unquote(sentence))
      end
    end
  end

  @doc false
  def __on_definition__(env, :def, :summary, [], _guards, _body) do
    unless Module.get_attribute(env.module, :impl) ||
             Module.get_attribute(env.module, :legion_generated_summary) do
      IO.warn(
        "#{inspect(env.module)}.summary/0 is taken as the tool's one-line summary: " <>
          "agents with `tool_docs: :on_demand` list what it returns, and Lua code " <>
          "cannot call it. Mark it `@impl Legion.Tool` if that is what it is for, " <>
          "or rename it.",
        env
      )
    end
  end

  def __on_definition__(_env, _kind, _name, _args, _guards, _body), do: :ok

  @doc false
  # The one-line summary of any module listed as a tool, whether or not it
  # `use`s Legion.Tool: the first sentence of its moduledoc, else of a
  # hand-written `description/0`, else its short name. The default
  # `description/0` is the module's source, which has no first sentence.
  def default_summary(module), do: default_summary(module, moduledoc_sentence(module))

  @doc false
  def default_summary(module, moduledoc_sentence) do
    Code.ensure_loaded!(module)

    cond do
      moduledoc_sentence -> moduledoc_sentence
      sentence = description_sentence(module) -> sentence
      true -> module |> Module.split() |> List.last()
    end
  end

  defp moduledoc_sentence(module) do
    case Code.fetch_docs(module) do
      {:docs_v1, _, _, _, %{"en" => doc}, _, _} when is_binary(doc) -> first_sentence(doc)
      _ -> nil
    end
  end

  defp description_sentence(module) do
    if function_exported?(module, :description, 0) do
      text = module.description()
      if String.starts_with?(text, "defmodule"), do: nil, else: first_sentence(text)
    end
  end

  defp first_sentence(text) do
    sentence =
      text
      |> String.trim()
      |> String.split("\n\n", parts: 2)
      |> List.first()
      |> String.replace("\n", " ")
      |> String.split(~r/(?<=[.!?])\s/, parts: 2)
      |> List.first()
      |> String.trim()

    if sentence == "", do: nil, else: sentence
  end

  @doc false
  def extract_module_source(code, module) do
    module_header = "defmodule #{inspect(module)} do"
    lines = String.split(code, "\n")

    start_index =
      Enum.find_index(lines, &String.contains?(&1, module_header)) ||
        raise "Could not find #{module_header} in source file"

    end_line = find_matching_end_line(code, start_index + 1)

    lines
    |> Enum.slice(start_index, end_line - start_index)
    |> Enum.join("\n")
  end

  defp find_matching_end_line(code, start_line) do
    tokens = tokenize!(code)

    tokens
    |> Enum.reverse()
    |> Enum.reduce_while({0, nil}, fn token, {depth, _last_end_line} ->
      case token_line(token, start_line) do
        {:open, _line} -> {:cont, {depth + 1, nil}}
        {:close, line} when depth == 1 -> {:halt, {0, line}}
        {:close, line} -> {:cont, {depth - 1, line}}
        :skip -> {:cont, {depth, nil}}
      end
    end)
    |> case do
      {0, line} when is_integer(line) -> line
      _ -> raise "Could not find matching `end` for module starting on line #{start_line}"
    end
  end

  defp token_line({:do, {line, _, _}}, start_line) when line >= start_line, do: {:open, line}
  defp token_line({:fn, {line, _, _}}, start_line) when line >= start_line, do: {:open, line}
  defp token_line({:end, {line, _, _}}, start_line) when line >= start_line, do: {:close, line}
  defp token_line(_token, _start_line), do: :skip

  defp tokenize!(code) do
    case :elixir_tokenizer.tokenize(String.to_charlist(code), 1, []) do
      result when elem(result, 0) == :ok ->
        result
        |> Tuple.to_list()
        |> Enum.find([], &token_list?/1)

      {:error, reason, _, _, _} ->
        raise "Failed to tokenize source: #{inspect(reason)}"
    end
  end

  defp token_list?([head | _]) when is_tuple(head) and tuple_size(head) >= 2,
    do: is_atom(elem(head, 0))

  defp token_list?(_), do: false
end
