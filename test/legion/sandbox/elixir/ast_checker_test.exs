defmodule Legion.Sandbox.Elixir.ASTCheckerTest do
  use ExUnit.Case, async: true

  alias Legion.Sandbox.Elixir.ASTChecker

  describe "allowed code" do
    for code <- [
          "1 + 2 * 3",
          "x = 10\nx * 2",
          "Enum.map([1, 2], fn x -> Integer.to_string(x) end)",
          ~s|String.upcase("hello")|,
          "Map.get(%{a: 1}, :a)",
          "m = %{a: 1}\nMap.fetch!(m, :a)",
          "m = %{a: %{b: 2}}\nm[:a][:b]",
          "Map.values(%{a: 1})",
          "Atom.to_string(:foo)",
          "Atom.to_charlist(:foo)",
          ~s|JSON.decode!("[1,2,3]")|,
          "JSON.encode!(%{a: 1})",
          ~s|URI.parse("https://example.com")|,
          ~s|URI.encode("hello world")|,
          ":math.sqrt(4.0)",
          ":erlang.float_to_binary(1.5, decimals: 2)",
          "f = fn -> 1 end\nf.()",
          "fn x when is_integer(x) -> x; x when is_atom(x) -> :atom end",
          "case x do y when is_atom(y) -> :ok end",
          "fn x when is_struct(x, ArgumentError) -> :ok end",
          "m = %{}\nfor x <- [1, 2], into: m, do: {x, x}"
        ] do
      test "accepts #{inspect(code)}" do
        assert :ok = ASTChecker.check(unquote(code), [])
      end
    end

    test "qualified Kernel.exit and Kernel.throw mirror their bare forms" do
      assert :ok = ASTChecker.check("Kernel.exit(:normal)", [])
      assert :ok = ASTChecker.check("Kernel.throw(:bad)", [])
    end

    test "rescue _e in Mod does not force-load Mod" do
      assert :ok = ASTChecker.check(~s|try do raise "x" rescue _e in File -> :hit end|, [])
    end
  end

  describe "input validation" do
    test "non-binary input is rejected" do
      assert {:error, message} = ASTChecker.check(nil, [])
      assert message =~ "must be a binary"
      assert {:error, _} = ASTChecker.check(42, [])
      assert {:error, _} = ASTChecker.check([], [])
    end

    test "syntax error returns parse error" do
      assert {:error, message} = ASTChecker.check("def foo(", [])
      assert message =~ "Parse error"
    end

    test "code exceeding the size cap is rejected" do
      big = String.duplicate("x = 1\n", 20_000)
      assert {:error, message} = ASTChecker.check(big, [])
      assert message =~ "exceeds maximum size"
    end
  end

  describe "denied modules" do
    for {code, module} <- [
          {~s|File.read!("/etc/passwd")|, "File"},
          {"System.halt()", "System"},
          {~s|IO.puts("hi")|, "IO"},
          {~s|Code.eval_string("1+1")|, "Code"},
          {"Process.flag(:priority, :high)", "Process"},
          {~s|:os.getenv("PATH")|, ":os"},
          {~s|:file.read_file("/etc/passwd")|, ":file"},
          {~s|:io.format("hello~n")|, ":io"},
          {"MyTool.run(1)", "MyTool"}
        ] do
      test "rejects #{inspect(code)}" do
        assert {:error, message} = ASTChecker.check(unquote(code), [])
        assert message =~ "Module #{unquote(module)} is not allowed"
      end
    end

    test "a violation nested inside an allowed call is caught" do
      assert {:error, message} =
               ASTChecker.check("Enum.map([1], fn _ -> System.halt() end)", [])

      assert message =~ "Module System is not allowed"
    end

    test "only the first violation is reported" do
      assert {:error, message} = ASTChecker.check(~s[File.read!("x") || System.halt()], [])
      assert message =~ "Module File is not allowed"
      refute message =~ "System"
    end
  end

  describe "denied bare forms" do
    for {code, form} <- [
          {"defmodule Foo do end", "defmodule"},
          {"def foo(x), do: x + 1", "def"},
          {"defp foo(x), do: x + 1", "defp"},
          {"defstruct foo: 1", "defstruct"},
          {"defexception []", "defexception"},
          {"defmacrop foo, do: 1", "defmacrop"},
          {"defguard is_x(x) when x > 0", "defguard"},
          {"defguardp is_x(x) when x > 0", "defguardp"},
          {"defdelegate read(p), to: File", "defdelegate"},
          {"defoverridable [foo: 0]", "defoverridable"},
          {"defimpl Foo, for: List do end", "defimpl"},
          {"alias File, as: String", "alias"},
          {"import Enum", "import"},
          {"require Logger", "require"},
          {"use GenServer", "use"},
          {"quote do: 1 + 1", "quote"},
          {"unquote(:foo)", "unquote"},
          {"unquote_splicing([1])", "unquote_splicing"},
          {"spawn(fn -> :ok end)", "spawn"},
          {"send(self(), :hi)", "send"},
          {"receive do message -> message end", "receive"},
          {"apply(:erlang, :halt, [])", "apply"},
          {"binding()", "binding"},
          {"var!(x)", "var!"},
          {"alias!(Foo)", "alias!"},
          {"node()", "node"},
          {"node(self())", "node"},
          {"@something", "@"},
          {"__ENV__", "__ENV__"},
          {"__MODULE__", "__MODULE__"},
          {"__CALLER__", "__CALLER__"},
          {"__DIR__", "__DIR__"},
          {"__STACKTRACE__", "__STACKTRACE__"}
        ] do
      test "rejects #{inspect(code)}" do
        assert {:error, message} = ASTChecker.check(unquote(code), [])
        assert message =~ "#{unquote(form)} is not allowed"
      end
    end
  end

  describe "denied functions on allowed modules" do
    for code <- [
          "Kernel.spawn(fn -> :ok end)",
          "Kernel.spawn_link(fn -> :ok end)",
          "Kernel.spawn_request(fn -> :ok end)",
          "Kernel.send(self(), :hi)",
          ~s|Kernel.apply(IO, :puts, ["hi"])|,
          ~s|Kernel.raise("x")|,
          "Kernel.node()",
          "Kernel.def(foo, do: 1)",
          "Kernel.defp(foo, do: 1)",
          "Kernel.defmodule(Foo, do: nil)",
          "Kernel.defmacro(foo, do: 1)",
          "Kernel.defstruct(foo: 1)",
          "Kernel.use(GenServer)",
          "Kernel.alias!(File)",
          "Kernel.var!(x)",
          "Kernel.dbg(1 + 1)",
          "Kernel.binding()",
          ~s|Kernel.binary_to_atom("x", :utf8)|,
          ~s|Kernel.binary_to_existing_atom("x", :utf8)|,
          ~s|Kernel.list_to_atom(~c"x")|,
          ~s|Kernel.list_to_existing_atom(~c"x")|,
          "Kernel.struct(Foo, %{})",
          "Kernel.struct!(Foo, %{})",
          "Kernel.function_exported?(File, :read, 1)",
          ~s|String.to_atom("hi")|,
          ~s|String.to_existing_atom("ok")|,
          ~s|List.to_atom(~c"hi")|,
          ~s|List.to_existing_atom(~c"ok")|,
          "Calendar.put_time_zone_database(Some.DB)",
          "Enum.zip3([1], [2], [3])",
          ~s|URI.default_port("http")|,
          ":erlang.length([1, 2, 3])",
          ":erlang.spawn(fn -> :ok end)",
          ":erlang.spawn_opt(fn -> :ok end, [])",
          ~s|:erlang.apply(IO, :puts, ["hi"])|,
          ":erlang.get()",
          ":erlang.put(:key, :value)",
          ":erlang.process_flag(:trap_exit, true)",
          ~s|:erlang.list_to_atom(~c"boom")|,
          ":erlang.system_info(:process_count)"
        ] do
      call = code |> String.split("(", parts: 2) |> hd()

      test "rejects #{inspect(code)}" do
        assert {:error, message} = ASTChecker.check(unquote(code), [])
        assert message =~ "#{unquote(call)} is not allowed"
      end
    end
  end

  describe "struct literals" do
    for code <- [
          "%Date{year: 2024, month: 1, day: 1, calendar: Calendar.ISO}",
          "%MapSet{}",
          ~s|%ArgumentError{message: "x"}|,
          "fn %Date{day: d} -> d end",
          "case x do %ArgumentError{} -> :err; _ -> :ok end"
        ] do
      test "accepts safe struct #{inspect(code)}" do
        assert :ok = ASTChecker.check(unquote(code), [])
      end
    end

    test "rejects a struct of an unknown module" do
      assert {:error, message} = ASTChecker.check("%Unknown.Mod{}", [])
      assert message =~ "%Unknown.Mod{} is not allowed"
    end

    for code <- [
          "%File.Stream{}",
          "fn %File.Stream{} -> 1 end",
          "case x do %File.Stream{} -> 1 end",
          "with %File.Stream{} <- x do x end",
          "%File.Stream{} = x",
          "for x <- [1, 2], into: %File.Stream{}, do: x"
        ] do
      test "rejects unsafe struct in #{inspect(code)}" do
        assert {:error, message} = ASTChecker.check(unquote(code), [])
        assert message =~ "%File.Stream{} is not allowed"
      end
    end
  end

  describe "tools (caller-supplied modules) are unrestricted" do
    test "any function on a tool module is allowed" do
      assert :ok = ASTChecker.check("MyTool.anything_at_all(1, 2, 3)", [MyTool])
    end

    test "tool modules are matched by tail alias, and only for the tool" do
      assert :ok = ASTChecker.check("MyTool.run(1)", [Some.Namespace.MyTool])
      assert {:error, _} = ASTChecker.check("Other.run(1)", [Some.Namespace.MyTool])
    end

    test "tool struct literal is allowed" do
      assert :ok = ASTChecker.check("%MyTool.Result{}", [MyTool.Result])
    end

    test "remote capture of a tool function is allowed at any arity" do
      assert :ok = ASTChecker.check("&MyTool.x/9", [MyTool])
    end

    test "tool whose tail collides with a stdlib module is allowed (shadows stdlib at runtime)" do
      # After the host aliases `MyApp.Date`, source-level `Date.utc_today()`
      # routes to the tool, not stdlib Date. Not an RCE escalation (tool functions
      # are callable directly anyway), but can produce surprising semantics.
      # Documented in the module's `## Tools` section; not enforced.
      assert :ok = ASTChecker.check("Date.utc_today()", [MyApp.Date])

      assert :ok =
               ASTChecker.check(~s|raise ArgumentError, "x"|, [MyApp.ArgumentError])
    end

    test "passing a stdlib module as a tool unlocks the entire module (caller's responsibility)" do
      # Per-function allowlists only apply when the module is NOT in the tools
      # list. Callers must vet what they expose.
      assert :ok = ASTChecker.check(~s|File.read!("/etc/passwd")|, [File])
      assert :ok = ASTChecker.check(~s|System.cmd("id", [])|, [System])
      assert :ok = ASTChecker.check("Map.keys(%{a: 1})", [Map])
    end
  end

  describe "error messages guide the model" do
    test "IO module hints to return values" do
      assert {:error, message} = ASTChecker.check(~s|IO.puts("x")|, [])
      assert message =~ "return values"
    end

    test "map dot access hints to use Map.fetch!" do
      assert {:error, message} = ASTChecker.check("user.name", [])
      assert message =~ "dynamic dispatch"
      assert message =~ "Map.fetch!"
    end

    test "struct literal lists the safe modules" do
      assert {:error, message} = ASTChecker.check("%Foo{}", [])
      assert message =~ "Date"
      assert message =~ "MapSet"
    end

    test "defmodule mentions anonymous functions" do
      assert {:error, message} = ASTChecker.check("defmodule X do end", [])
      assert message =~ "anonymous functions"
    end
  end
end
