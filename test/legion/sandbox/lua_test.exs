defmodule Legion.Sandbox.LuaTest.EchoTool do
  use Legion.Tool

  def description, do: "EchoTool - test bridge tool."

  def add(a, b), do: a + b
  def add(a, b, c), do: a + b + c
  def shape(value), do: %{received: value, tag: :ok}
  def module_check(module), do: %{is_atom: is_atom(module), name: inspect(module)}
  def pair, do: {:ok, 42}
  def host_fun, do: %{name: "reader", read: fn path -> {:host_called, path} end}
  def boom, do: raise(ArgumentError, "tool exploded")
  def throw_it, do: throw(:tool_escaped)
  def exit_it, do: exit(:tool_exited)
end

defmodule Legion.Sandbox.LuaTest.ListStruct do
  defstruct [:id, :name]
end

defmodule Legion.Sandbox.LuaTest.ListTool do
  use Legion.Tool

  alias Legion.Sandbox.LuaTest.ListStruct

  def description, do: "ListTool - test bridge tool."

  def get_list(num_elements) do
    for id <- 1..num_elements, do: %ListStruct{id: id, name: "#{id}"}
  end
end

# NOT a Legion.Tool - stands in for a sub-agent module that only reaches the
# sandbox via AgentTool.extra_allowed_modules/0, where it is meant to be a bare
# module *reference* for `AgentTool.call(FakeSubAgent, task)`, never a callable.
defmodule Legion.Sandbox.LuaTest.FakeSubAgent do
  def internal_capability(marker), do: {:reached_host, marker}
end

defmodule Legion.Sandbox.LuaTest do
  use ExUnit.Case

  doctest Legion.Sandbox.Lua, import: true

  alias Legion.Sandbox.Lua
  alias Legion.Sandbox.LuaTest.EchoTool
  alias Legion.Sandbox.LuaTest.FakeSubAgent
  alias Legion.Sandbox.LuaTest.ListTool

  test "returns result and reusable bindings" do
    assert {:ok, {nil, bindings}} = Lua.execute("x = 40", 15_000)
    assert {:ok, {42, _}} = Lua.execute("return x + 2", 15_000, [], bindings)
  end

  test "chunk without return yields nil" do
    assert {:ok, {nil, _}} = Lua.execute("y = 1", 15_000)
  end

  test "multiple return values become a list" do
    assert {:ok, {[1, 2], _}} = Lua.execute("return 1, 2", 15_000)
  end

  test "local variables do not persist, globals do" do
    {:ok, {nil, bindings}} = Lua.execute("local a = 1\nb = 2", 15_000)
    assert {:ok, {nil, _}} = Lua.execute("return a", 15_000, [], bindings)
    assert {:ok, {2, _}} = Lua.execute("return b", 15_000, [], bindings)
  end

  test "bindings survive the term round-trip a store does" do
    {:ok, {nil, bindings}} = Lua.execute("count = EchoTool.add(1, 2)", 15_000, [EchoTool])

    revived = bindings |> :erlang.term_to_binary() |> :erlang.binary_to_term()

    assert {:ok, {3, _}} = Lua.execute("return count", 15_000, [EchoTool], revived)

    assert {:ok, {4, _}} =
             Lua.execute("return EchoTool.add(count, 1)", 15_000, [EchoTool], revived)

    assert Lua.binding_names(revived) == ["count"]
  end

  test "binding_names lists user globals only" do
    {:ok, {nil, bindings}} = Lua.execute("count = 1\nitems = {1, 2}", 15_000, [EchoTool])
    assert Enum.sort(Lua.binding_names(bindings)) == ["count", "items"]
    assert Lua.binding_names([]) == []
  end

  test "bindings are plain data: functions, cycles, and dead tables are not carried" do
    code = """
    count = 1
    flag = false
    items = {1, {x = 2}}
    cyclic = {}
    cyclic.self = cyclic
    local dead = {1, 2, 3}
    function helper() return 1 end
    saved = EchoTool.add
    """

    {:ok, {nil, bindings}} = Lua.execute(code, 15_000, [EchoTool])

    assert Enum.sort(bindings) ==
             [{"count", 1}, {"cyclic", []}, {"flag", false}, {"items", [1, %{"x" => 2}]}]

    assert {:ok, {2, _}} = Lua.execute("return items[2].x", 15_000, [EchoTool], bindings)
  end

  test "rebinding _G does not affect which globals are exported" do
    assert {:ok, {nil, [{"x", 1}]}} = Lua.execute("_G = nil\nx = 1", 15_000)
    assert {:ok, {nil, [{"y", 2}]}} = Lua.execute("_G = {evil = 1}\ny = 2", 15_000)
  end

  test "a tool removed from the agent is unreachable from restored bindings" do
    {:ok, {nil, bindings}} = Lua.execute("saved = EchoTool.add", 15_000, [EchoTool])

    assert {:ok, {nil, _}} = Lua.execute("return saved", 15_000, [], bindings)
    assert {:error, message} = Lua.execute("return EchoTool.add(1, 2)", 15_000, [], bindings)
    assert message =~ "attempt to index a nil value"
  end

  test "a stored tool reference resolves against the tools of the run that reads it" do
    {:ok, {nil, bindings}} = Lua.execute("planner = EchoTool", 15_000, [EchoTool])

    assert {:ok, {%{"is_atom" => true}, _}} =
             Lua.execute("return EchoTool.module_check(planner)", 15_000, [EchoTool], bindings)
  end

  test "a global named after a tool does not break later evaluations" do
    {:ok, {nil, bindings}} = Lua.execute("EchoTool = 1", 15_000, [EchoTool])

    assert {:ok, {3, _}} =
             Lua.execute("return EchoTool.add(1, 2)", 15_000, [EchoTool], bindings)
  end

  test "parse errors are caught by check" do
    assert {:error, message} = Lua.execute("local x =;", 15_000)
    assert message =~ "Failed to compile Lua!"
  end

  test "bare-expression mistake gets a return hint" do
    assert {:error, message} = Lua.execute("x = 1\nx", 15_000)
    assert message =~ "return <expression>"
  end

  test "tool tables passed as arguments resolve to their module atom" do
    assert {:ok, {value, _}} =
             Lua.execute("return EchoTool.module_check(EchoTool)", 15_000, [EchoTool])

    assert value == %{"is_atom" => true, "name" => "Legion.Sandbox.LuaTest.EchoTool"}
  end

  test "runtime errors are returned as error strings" do
    assert {:error, message} = Lua.execute("error('boom')", 15_000)
    assert message =~ "boom"
  end

  test "io and os escapes are sandboxed" do
    assert {:error, message} = Lua.execute("os.getenv('HOME')", 15_000)
    assert message =~ "sandboxed"

    assert {:error, message} = Lua.execute("print('hi')", 15_000)
    assert message =~ "sandboxed"
  end

  test "an oversized string is refused by the VM instead of racing the heap kill" do
    # 6 MB exceeds the 5 MB string ceiling derived from max_heap, yet stays
    # under the 10 MB binary budget - only the VM ceiling can catch it.
    assert {:error, message} =
             Lua.execute("return string.rep('x', 6000000)", 15_000, [], [], max_heap: 10_000_000)

    assert message =~ "resulting string too large"
  end

  test "debug library is sandboxed" do
    assert {:error, message} = Lua.execute("return debug.setmetatable", 15_000)
    assert message =~ "attempt to index a function value (global 'debug')"

    assert {:error, message} = Lua.execute("return debug(1)", 15_000)
    assert message =~ "sandboxed"
  end

  test "tool functions are callable with arity dispatch" do
    assert {:ok, {3, _}} = Lua.execute("return EchoTool.add(1, 2)", 15_000, [EchoTool])
    assert {:ok, {6, _}} = Lua.execute("return EchoTool.add(1, 2, 3)", 15_000, [EchoTool])
  end

  test "wrong tool arity returns a helpful error" do
    assert {:error, message} = Lua.execute("return EchoTool.add(1)", 15_000, [EchoTool])
    assert message =~ "EchoTool.add takes 2 or 3 argument(s), got 1"
  end

  test "lua tables arrive as maps or lists, results convert back" do
    assert {:ok, {value, _}} =
             Lua.execute("return EchoTool.shape({name = 'ada', tags = {1, 2}})", 15_000, [
               EchoTool
             ])

    assert value == %{"received" => %{"name" => "ada", "tags" => [1, 2]}, "tag" => "ok"}
  end

  test "lua tables correctly converted to lists" do
    num_elements = 40

    code = """
    talks=ListTool.get_list(#{num_elements})
    list={}
    for _,t in ipairs(talks) do table.insert(list, t.id) end
    return list
    """

    assert {:ok, {list, _}} = Lua.execute(code, 15_000, [ListTool])

    assert is_list(list)
    assert list == Enum.to_list(1..num_elements)
  end

  test "tuple results become arrays" do
    assert {:ok, {["ok", 42], _}} = Lua.execute("return EchoTool.pair()", 15_000, [EchoTool])
  end

  test "elixir functions in tool results and bindings are dropped, not bridged" do
    assert {:ok, {%{"name" => "reader"}, _}} =
             Lua.execute("return EchoTool.host_fun()", 15_000, [EchoTool])

    assert {:error, message} =
             Lua.execute("return EchoTool.host_fun().read('/etc/hosts')", 15_000, [EchoTool])

    assert message =~ "attempt to call a nil value"

    assert {:ok, {nil, _}} = Lua.execute("return p", 15_000, [], [{"p", fn _ -> :host end}])
  end

  test "tool exceptions surface with the tool name" do
    assert {:error, message} = Lua.execute("EchoTool.boom()", 15_000, [EchoTool])
    assert message =~ "EchoTool.boom"
    assert message =~ "tool exploded"
  end

  test "tool throws and exits are caught, matching the Elixir sandbox" do
    assert {:error, {:throw, :tool_escaped}} =
             Lua.execute("EchoTool.throw_it()", 15_000, [EchoTool])

    assert {:error, {:exit, :tool_exited}} =
             Lua.execute("EchoTool.exit_it()", 15_000, [EchoTool])
  end

  test "non-tool modules are reference-only: no functions bridged into Lua" do
    # The executor passes `tools ++ extra_allowed_modules` as one list; a
    # sub-agent module in that list is meant as a bare module reference for
    # `AgentTool.call(FakeSubAgent, task)`, never a callable. Only modules
    # built with `use Legion.Tool` get their functions bridged.
    assert {:error, message} =
             Lua.execute(
               "return FakeSubAgent.internal_capability('from_lua')",
               15_000,
               [FakeSubAgent]
             )

    assert message =~ "attempt to call a nil value"

    assert {:ok, {value, _}} =
             Lua.execute("return EchoTool.module_check(FakeSubAgent)", 15_000, [
               EchoTool,
               FakeSubAgent
             ])

    assert value == %{"is_atom" => true, "name" => "Legion.Sandbox.LuaTest.FakeSubAgent"}
  end

  test "non-Elixir modules in the tools list are left out instead of crashing" do
    # `extra_allowed_modules/0` may list Erlang modules for the Elixir
    # sandbox; they have no short name to register a Lua table under.
    assert {:ok, {3, _}} =
             Lua.execute("return EchoTool.add(1, 2)", 15_000, [:erlang, EchoTool, :math])

    assert {:ok, {nil, _}} = Lua.execute("return erlang", 15_000, [:erlang])
  end

  test "meta functions from Legion.Tool are not bridged" do
    assert {:error, _message} = Lua.execute("return EchoTool.description()", 15_000, [EchoTool])
  end

  test "timeout kills the evaluation" do
    assert {:error, :timeout} = Lua.execute("while true do end", 100)
  end

  test "reduction budget kills a busy loop" do
    assert {:error, message} =
             Lua.execute("local n = 0\nfor i = 1, 100000000 do n = n + 1 end", 60_000, [], [],
               max_reductions: 1_000_000
             )

    assert message =~ "reduction (CPU) limit"
  end

  test "prompt_info describes the Lua environment" do
    info = Lua.prompt_info()
    assert info.language == "Lua"
    assert info.constraints =~ "global"
    assert info.tool_usage =~ "Lua"
  end
end
