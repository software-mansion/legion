defmodule Legion.Sandbox.Lua do
  @moduledoc """
  Sandboxed Lua evaluation via [lua](https://hexdocs.pm/lua) - a Lua 5.3 VM
  written in pure Elixir. The default `Legion.Sandbox`.

  Unlike `Legion.Sandbox.Elixir`, which must deny-list its way around the
  entire Elixir surface, Lua code simply has no way to reach the host BEAM:
  the only bridges out of the VM are the tool functions registered by this
  module. That makes it the safer sandbox for less trusted code.

  - **Tools** - each tool module becomes a global Lua table named after the
    module's last segment; every public function of a `Legion.Tool` module is
    callable as `ShortName.fun(...)`. Other listed modules (sub-agents, extra
    allowed modules) get a reference-only table: usable where a tool expects a
    module, but exposing no functions. Arguments are decoded to Elixir values (Lua tables
    become maps, or lists when array-shaped) and results are encoded back
    (tuples become arrays, structs become tables of fields, atoms become
    strings).
  - **Bindings** - the user-defined globals, as a list of `{name, value}`
    pairs of plain Elixir data (tables become maps, or lists when
    array-shaped). Globals persist across executions that share bindings;
    `local` variables, functions, and metatables do not.
  - **Blocked** - `io`, `file`, `os.execute/exit/getenv/...`, `require`,
    `load`, `print`, and `debug` are sandboxed and raise when called.
  - **Timeout and resource limits** - evaluation runs through
    `Legion.Sandbox.Runner`, same as `Legion.Sandbox.Elixir`. The VM
    additionally refuses to build any single string larger than half the
    memory budget, before allocating it.

  ## Examples

      iex> {:ok, {4, _}} = Legion.Sandbox.Lua.execute("return 2 + 2", 5_000)

      iex> {:ok, {nil, [{"x", 40}]}} = Legion.Sandbox.Lua.execute("x = 40", 5_000)
      iex> {:ok, {42, _}} = Legion.Sandbox.Lua.execute("return x + 2", 5_000, [], [{"x", 40}])

      iex> {:error, message} = Legion.Sandbox.Lua.execute("os.getenv('HOME')", 5_000)
      iex> message =~ "sandboxed"
      true
  """

  @behaviour Legion.Sandbox

  alias Legion.Sandbox.Runner
  alias Lua.VM.Limits
  alias Lua.VM.State

  import Lua.API, only: [is_table: 1, is_lua_func: 1, is_erl_func: 1, is_userdata: 1]

  require EEx

  EEx.function_from_file(:defp, :constraints, Path.join(__DIR__, "lua/constraints.eex"))

  @max_code_size 64 * 1024

  # Defined by `use Legion.Tool`, not part of a tool's callable surface.
  @tool_meta_functions [description: 0, description: 1, extra_allowed_modules: 0]

  @module_key "__module"

  @impl Legion.Sandbox
  def check(code, _tools) when not is_binary(code),
    do: {:error, "code must be a binary, got: #{inspect(code)}"}

  def check(code, _tools) when byte_size(code) > @max_code_size,
    do: {:error, "code exceeds maximum size of #{@max_code_size} bytes"}

  def check(code, _tools) do
    case Lua.parse_chunk(code) do
      {:ok, _chunk} ->
        :ok

      {:error, exception} ->
        {:error,
         Exception.message(exception) <>
           "\nNote: a bare expression is not a valid Lua statement - " <>
           "to produce a value, write `return <expression>`."}
    end
  end

  @impl Legion.Sandbox
  def binding_names(bindings), do: for({name, _value} <- bindings, do: name)

  @impl Legion.Sandbox
  def prompt_info do
    %{
      language: "Lua",
      constraints: constraints(),
      tool_usage:
        "Each tool below is implemented in Elixir and exposed as a global Lua table - call it from Lua as `ShortName.fun(...)`. The source shown is Elixir; call the same function names with positional arguments."
    }
  end

  @doc """
  Evaluates Lua code in a sandboxed process.

  `timeout_ms` controls the maximum execution time (`:infinity` to disable).
  `tools` are Elixir modules bridged in as global Lua tables. `limits` bound
  the evaluating process - see `Legion.Sandbox.Runner.run/3`.

  Returns `{:ok, {result, bindings}}` where `result` is the chunk's `return`
  value (`nil` when it returns nothing) and `bindings` holds the user-defined
  globals to pass to subsequent calls, or `{:error, reason}`.
  """
  @impl Legion.Sandbox
  def execute(code, timeout_ms, tools \\ [], bindings \\ [], limits \\ [])
      when is_binary(code) and is_list(tools) do
    with :ok <- check(code, tools) do
      max_heap_bytes = Keyword.get(limits, :max_heap, Runner.default_max_heap())
      Runner.run(fn -> eval(code, tools, bindings, max_heap_bytes) end, timeout_ms, limits)
    end
  end

  defp eval(code, tools, bindings, max_heap_bytes) do
    tools = Enum.filter(tools, &elixir_module?/1)
    lua = init(tools, max_heap_bytes)
    baseline = global_names(lua)
    lua = restore(lua, bindings, baseline)
    module_refs = module_refs(tools)

    {results, lua} = Lua.eval!(lua, code)

    value =
      case results do
        [] -> nil
        [single] -> lua_to_elixir(single, module_refs)
        many -> Enum.map(many, &lua_to_elixir(&1, module_refs))
      end

    {:ok, {value, export(lua, baseline)}}
  rescue
    e in [Lua.RuntimeException, Lua.CompilerException] -> {:error, Exception.message(e)}
  catch
    :throw, value -> {:error, {:throw, value}}
    :exit, reason -> {:error, {:exit, reason}}
  end

  defp init(tools, max_heap_bytes) do
    new_vm(max_heap_bytes)
    |> Lua.sandbox([:print])
    |> Lua.sandbox([:debug])
    |> register_tools(tools)
  end

  defp restore(lua, bindings, baseline) do
    for {name, value} <- bindings, name not in baseline, reduce: lua do
      lua -> Lua.set!(lua, [name], elixir_to_lua(value))
    end
  end

  # Copies the user's globals out of the VM as plain data - functions,
  # userdata, and cycles are dropped. `__module` tables are kept as tables (no
  # `module_refs`), so a stored tool reference resolves against the tools of
  # whichever run reads it back.
  defp export(lua, baseline) do
    globals =
      for {name, value} <- State.globals(lua.state),
          name not in baseline,
          do: {name, Lua.decode!(lua, value)}

    for {name, value} <- plain(globals), do: {name, lua_to_elixir(value, %{})}
  end

  # A bare table reference is what `Lua.decode!` leaves where a table contains
  # itself.
  defp plain(value)
       when is_table(value) or is_lua_func(value) or is_erl_func(value) or is_userdata(value),
       do: nil

  defp plain(table) when is_list(table) do
    Enum.flat_map(table, fn {key, item} ->
      case {plain(key), plain(item)} do
        {nil, _item} -> []
        {_key, nil} -> []
        pair -> [pair]
      end
    end)
  end

  defp plain(other), do: other

  defp new_vm(:infinity), do: Lua.new()

  defp new_vm(max_heap_bytes),
    do: Lua.new(max_string_bytes: min(div(max_heap_bytes, 2), Limits.max_string_bytes()))

  defp module_refs(tools), do: Map.new(tools, &{Atom.to_string(&1), &1})

  defp elixir_module?(module), do: String.starts_with?(Atom.to_string(module), "Elixir.")

  defp register_tools(lua, tools) do
    module_refs = module_refs(tools)

    for tool <- tools, reduce: lua do
      lua ->
        short_name = tool |> Module.split() |> List.last()

        # The marker lets sandboxed code pass the table itself where an Elixir
        # module is expected (`AgentTool.call(PlannerAgent, task)`) - the
        # bridge resolves marked tables back to their module atom.
        lua = Lua.set!(lua, [short_name, @module_key], Atom.to_string(tool))

        for {name, arities} <- callable_functions(tool), reduce: lua do
          lua ->
            Lua.set!(
              lua,
              [short_name, Atom.to_string(name)],
              bridge(tool, short_name, name, arities, module_refs)
            )
        end
    end
  end

  defp callable_functions(tool) do
    Code.ensure_loaded!(tool)

    if legion_tool?(tool) do
      tool.__info__(:functions)
      |> Kernel.--(@tool_meta_functions)
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    else
      %{}
    end
  end

  defp legion_tool?(module) do
    behaviours =
      module.module_info(:attributes)
      |> Keyword.get_values(:behaviour)
      |> List.flatten()

    Legion.Tool in behaviours
  end

  defp bridge(tool, short_name, name, arities, module_refs) do
    fn encoded_args, lua ->
      args = for arg <- Lua.decode_list!(lua, encoded_args), do: lua_to_elixir(arg, module_refs)

      if length(args) in arities do
        result =
          try do
            apply(tool, name, args)
          rescue
            e ->
              reraise Lua.RuntimeException,
                      "#{short_name}.#{name}: #{Exception.message(e)}",
                      __STACKTRACE__
          end

        {encoded, lua} = Lua.encode!(lua, elixir_to_lua(result))
        {[encoded], lua}
      else
        raise Lua.RuntimeException,
              "#{short_name}.#{name} takes #{Enum.join(arities, " or ")} argument(s), " <>
                "got #{length(args)}"
      end
    end
  end

  defp global_names(lua), do: Map.keys(State.globals(lua.state))

  # Decoded Lua values -> Elixir. Tables carrying the bridge's module marker
  # resolve to their module atom; array-shaped tables (keys exactly 1..n)
  # become lists; the rest become maps.
  defp lua_to_elixir(table, module_refs) when is_list(table) do
    map = Map.new(table)
    size = map_size(map)

    cond do
      module = bridged_module(table, module_refs) ->
        module

      Enum.all?(1..size//1, &Map.has_key?(map, &1)) ->
        for index <- 1..size//1, do: lua_to_elixir(map[index], module_refs)

      true ->
        Map.new(map, fn {key, value} ->
          {lua_to_elixir(key, module_refs), lua_to_elixir(value, module_refs)}
        end)
    end
  end

  defp lua_to_elixir(other, _module_refs), do: other

  defp bridged_module(table, module_refs) do
    case List.keyfind(table, @module_key, 0) do
      {@module_key, name} -> module_refs[name]
      nil -> nil
    end
  end

  # Elixir values -> value the VM can encode. Tuples and structs have no
  # Lua counterpart: tuples become arrays, structs lose their module.
  # Functions are dropped: the VM would bridge any 1- or 2-arity fun as a
  # callable, handing sandboxed code whatever a tool result happens to carry
  defp elixir_to_lua(fun) when is_function(fun), do: nil

  defp elixir_to_lua(%_{} = struct), do: struct |> Map.from_struct() |> elixir_to_lua()

  defp elixir_to_lua(map) when is_map(map),
    do: Map.new(map, fn {key, value} -> {elixir_to_lua(key), elixir_to_lua(value)} end)

  defp elixir_to_lua(list) when is_list(list), do: Enum.map(list, &elixir_to_lua/1)

  defp elixir_to_lua(tuple) when is_tuple(tuple),
    do: tuple |> Tuple.to_list() |> Enum.map(&elixir_to_lua/1)

  defp elixir_to_lua(other), do: other
end
