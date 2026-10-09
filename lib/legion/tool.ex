defmodule Legion.Tool do
  @moduledoc """
  `use Legion.Tool` to mark a module as a tool available to agents.

  By default, `description/0` returns the module's source code so the LLM
  knows what functions are available. An agent running with
  `tool_docs: :on_demand` (see `Legion.Agent`) first sees only each tool's
  `summary/0`, one sentence, and reads the full description with
  `Help.help(Name)` when it needs it.

  ## Overridable

    - `description/0` — override to return a hand-written summary **instead of**
      the source code. Defaults to the module's source code.
    - `description/1` — like `description/0`, but receives the active sandbox
      module, for tools whose usage differs by generated language. Preferred
      over `description/0` when defined.
    - `summary/0` — override to return the one sentence that stands for the tool
      in the tool list under `tool_docs: :on_demand`. Defaults to the first
      sentence of the `@moduledoc`, else of a hand-written `description/0`, else
      the module's short name. The example below has no `@moduledoc`, so its
      summary is `WeatherTool — fetches current weather data.` Mark an
      override `@impl Legion.Tool`: an unmarked `summary/0`, perhaps a tool
      function that was there first, gets a compile-time warning, since
      Legion takes it over and Lua code cannot call it.
    - `extra_allowed_modules/0` — override to return additional modules that the
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
          WeatherTool — fetches current weather data.

          ## Functions
          - `current(city)` — returns weather JSON for the given city name.
          \"""
        end

        @doc "Returns current weather for a city."
        def current(city) do
          Req.get!("https://wttr.in/\#{city}?format=j1").body
        end
      end

  ## External modules as tools

  A module that does not `use Legion.Tool` (e.g. `Req`) can still be listed as
  a tool if its source code is registered at compile time, so the LLM can read
  what it offers:

      config :legion, extra_source_modules: [Req]
  """

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

      def description, do: unquote(source)
      def extra_allowed_modules, do: []
      def mcp?, do: true

      defoverridable description: 0, extra_allowed_modules: 0, mcp?: 0
    end
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
  # A tool's own `summary/0` replaces the generated one, so a function that
  # was there first and means something else is taken over without a word:
  # listed as the summary and hidden from Lua code. `@impl` says the
  # override is meant.
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
