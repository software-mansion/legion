defmodule Legion.Sandbox.Elixir.ASTChecker.RCEAttackVectorsTest do
  @moduledoc """
  RCE attack vectors against the Elixir sandbox.

  The recurring class is getting the `:__struct__` atom at runtime to forge a
  struct (a fake `%File.Stream{}` turns `for ..., into:` into arbitrary file
  write), and getting a module atom into a position the runtime dispatches on
  or force-loads (running its `@on_load`).

  `assert_blocked/2` requires the AST check itself to reject a vector - a
  runtime error does not count, and a regression fails here without the code
  ever running. `assert_runs/1` is the positive control: the code passes the
  check and executes cleanly.
  """
  use ExUnit.Case, async: true

  alias Legion.Sandbox.Elixir, as: Sandbox
  alias Legion.Sandbox.Elixir.ASTChecker

  # Tool modules whose alias tails collide with the real System / Code / File.
  defmodule Tools.System do
    def hello, do: :ok
  end

  defmodule Tools.Code do
    def hello, do: :ok
  end

  defmodule Tools.File do
    def hello, do: :ok
  end

  @tools_system __MODULE__.Tools.System
  @tools_code __MODULE__.Tools.Code
  @tools_file __MODULE__.Tools.File

  defp assert_blocked(cases) do
    for {name, code} <- cases do
      result = ASTChecker.check(code, [])

      assert match?({:error, _}, result),
             "[#{name}] passed the AST check\n  code: #{inspect(code)}"
    end
  end

  defp assert_runs(cases) do
    for {name, code} <- cases do
      result = Sandbox.execute(code, 5_000)

      assert match?({:ok, _}, result),
             "[#{name}] did not execute cleanly\n  code: #{inspect(code)}\n  result: #{inspect(result)}"
    end
  end

  defp assert_rejected_with(cases) do
    for {code, expected} <- cases do
      assert {:error, message} = ASTChecker.check(code, [])

      assert message =~ expected,
             "#{inspect(code)} was rejected for the wrong reason: #{message}"
    end
  end

  describe "forging a struct from a literal :__struct__" do
    test "a fake %File.Stream{} cannot write files through for/into" do
      path = Path.join(System.tmp_dir!(), "legion-rce-#{System.unique_integer([:positive])}")

      code = """
      fake = %{
        __struct__: File.Stream,
        path: path,
        modes: [:write],
        line_or_bytes: :line,
        raw: true,
        node: node()
      }

      for line <- ["pwned"], into: fake, do: line
      """

      try do
        assert {:error, "literal :__struct__ atom is not allowed"} =
                 Sandbox.execute(code, 5_000, [], path: path)

        refute File.exists?(path)
      after
        File.rm(path)
      end
    end

    test "every syntax placing the :__struct__ atom is rejected" do
      for code <- [
            "%{:__struct__ => :os, foo: 1}",
            "%{__struct__: :os, foo: 1}",
            "%{m | __struct__: File.Stream}",
            ~s[%{} |> Map.put(:__struct__, File.Stream) |> Map.put(:path, "/tmp/x")]
          ] do
        assert {:error, "literal :__struct__ atom is not allowed"} = ASTChecker.check(code, [])
      end
    end

    test "protocol gadgets on a fake struct are rejected" do
      assert_blocked([
        {"Inspect on a fake Code struct", ~s|inspect(%{__struct__: Code, foo: 1})|},
        {"String.Chars on a fake Version",
         ~s|to_string(%{__struct__: Version, major: 1, minor: 0, patch: 0, pre: [], build: nil})|},
        {"Inspect on a fake Range",
         ~s|inspect(%{__struct__: Range, first: 1, last: 10, step: 1})|},
        {"Collectable into a fake MapSet",
         ~s|for x <- [1, 2], into: %{__struct__: MapSet, map: %{}, version: 2}, do: x|},
        {"Enumerable on a fake Range",
         ~s|Enum.to_list(%{__struct__: Range, first: 1, last: 3, step: 1})|},
        {"Enum.reduce on a fake MapSet",
         "Enum.reduce(%{__struct__: MapSet, map: %{a: [], b: []}, version: 2}, [], fn x, acc -> [x | acc] end)"},
        {"Enum.count on a fake Date.Range",
         ~s|Enum.count(%{__struct__: Date.Range, first: ~D[2026-01-01], last: ~D[2026-01-05], first_in_iso_days: 0, last_in_iso_days: 0, step: 1})|},
        {"struct pattern matching a fake Range",
         ~s|case %{__struct__: Range, first: 1, last: 5, step: 1} do %Range{} = r -> Enum.to_list(r); _ -> :no end|},
        {"Inspect with a fake Inspect.Opts",
         ~s|inspect(%{__struct__: Inspect.Opts, base: :decimal, binaries: :infer, char_lists: :infer, charlists: :infer, custom_options: [], inspect_fun: fn _, _ -> :ok end, limit: 50, pretty: true, printable_limit: 4096, safe: true, structs: true, syntax_colors: [], width: 80})|},
        {"in operator on a fake Range", ~s|3 in %{__struct__: Range, first: 1, last: 5, step: 1}|}
      ])
    end
  end

  describe "recovering :__struct__ at runtime" do
    test "Map.keys and Map.to_list are rejected (they return the :__struct__ key)" do
      assert_rejected_with([
        {"Map.keys(1..3)", "Map.keys is not allowed"},
        {"Map.to_list(1..3)", "Map.to_list is not allowed"}
      ])
    end

    test "callback-based Map functions are rejected (the callback sees the :__struct__ pair)" do
      for function <- ~w(map filter reject split_with) do
        assert {:error, message} =
                 ASTChecker.check("Map.#{function}(%URI{}, fn {k, _v} -> throw(k) end)", [])

        assert message =~ "Map.#{function} is not allowed"
        assert message =~ "Enum.#{function}"
      end

      for function <- ~w(merge intersect) do
        assert {:error, message} =
                 ASTChecker.check(
                   "Map.#{function}(%URI{}, %URI{}, fn k, _v1, _v2 -> throw(k) end)",
                   []
                 )

        assert message =~ "Map.#{function}/3 is not allowed"
        assert message =~ "__struct__"
      end
    end

    test "Map.from_struct and the callback-free Map.merge/2 and Map.intersect/2 still run" do
      assert {:ok, {%{first: 1, last: 3, step: 1}, _}} =
               Sandbox.execute("Map.from_struct(1..3)", 5_000)

      assert_runs([
        {"Map.merge/2", "Map.merge(%{a: 1}, %{b: 2})"},
        {"Map.intersect/2", "Map.intersect(%{a: 1}, %{a: 2})"}
      ])
    end

    test "a binary containing __struct__ is rejected" do
      assert {:error, message} = ASTChecker.check(~s|"prefix __struct__ suffix"|, [])
      assert message =~ ~S|literal binary containing "__struct__"|
    end

    # The `a` modifier maps each token through `String.to_atom/1` at
    # macro-expansion time, after the AST check.
    test "atom-list sigils cannot materialise :__struct__" do
      assert_rejected_with([
        {"~w(_a __struct__)a |> List.last()", ~S|token "__struct__" is not allowed|},
        {"~W(_a __struct__)a |> List.last()", ~S|token "__struct__" is not allowed|},
        {"~w(__struct__)a |> hd()", ~S|token "__struct__" is not allowed|},
        {~S|s = "_" <> "_str" <> "uct__"; ~w(#{s})a|, "interpolation is not allowed"},
        {~S|x = String.upcase("foo"); ~w(#{x})a|, "interpolation is not allowed"}
      ])
    end

    test "a sigil-built :__struct__ and File.Stream cannot write files" do
      witness =
        Path.join(System.tmp_dir!(), "legion_rce_witness_#{System.unique_integer([:positive])}")

      code = """
      s = "_" <> "_str" <> "uct__"
      [ss] = ~w(\#{s})a
      [fs] = ~w(Elixir.File.Stream)a
      fake = %{} |> Map.put(ss, fs)
                 |> Map.put(:path, "#{witness}")
                 |> Map.put(:modes, [:write])
                 |> Map.put(:line_or_bytes, :line)
                 |> Map.put(:raw, true)
                 |> Map.put(:node, :nonode@nohost)
      for c <- ["pwned\\n"], into: fake, do: c
      """

      assert {:error, _message} = Sandbox.execute(code, 5_000)
      assert {:error, :enoent} = File.read(witness)
    end

    test "non-interpolated sigils without the __struct__ token still run" do
      for {code, expected} <- [
            {"~w(foo bar baz)", ["foo", "bar", "baz"]},
            {"~w(foo bar baz)s", ["foo", "bar", "baz"]},
            {"~w(foo bar baz)c", [~c"foo", ~c"bar", ~c"baz"]},
            {"~W(foo bar)s", ["foo", "bar"]},
            {"~w(red green blue)a", [:red, :green, :blue]},
            {"~W(ok error)a", [:ok, :error]},
            # Module-shaped atoms are inert: dispatch, struct and raise
            # positions all require literals.
            {"~w(Elixir.System asn1rt_nif)a", [System, :asn1rt_nif]}
          ] do
        assert {:ok, {^expected, _}} = Sandbox.execute(code, 5_000)
      end
    end
  end

  describe "dynamic dispatch on a runtime module atom" do
    test "every non-literal dispatch base is rejected" do
      assert_blocked([
        {"variable holding :erlang", "v = :erlang; v.halt()"},
        {"variable holding File", ~s|m = File\nm.read!("/etc/passwd")|},
        {"variable holding an allowed module", "m = Enum\nm.map([1, 2, 3], & &1 + 1)"},
        {"variable holding a safe module", "m = Date; m.utc_today()"},
        {"no-parens call on a variable", "m = :os\nm.getenv"},
        {"capture on a variable", ~s|m = :os\nf = &m.cmd/1\nf.(~c"id")|},
        {"head of a list", "hd([:erlang]).halt()"},
        {"Module.concat result", ~s|Module.concat([Code]).eval_string("1")|},
        {"fn returning a module", "(fn -> :erlang end).().spawn(fn -> :ok end)"},
        {"map field chain", ~s|m = %{a: Code}; m.a.eval_string("1")|},
        {"pid as a dispatch base", "p = self(); p.send(:hi)"},
        {"struct with a variable module", "m = Code; %m{}"},
        {"unquote in call position", ~s|Code.unquote(:eval_string)("1")|}
      ])
    end

    test "module atoms as plain values are inert" do
      assert_runs([
        {"bare module atom", "Code"},
        {"module bound to a variable", "x = Code"},
        {"module in a tuple", ~s|{Code, :eval_string, ["1"]}|},
        {"module from a list", "hd([Code])"},
        {"module-function tuple", "tuple = {:erlang, :halt}; tuple"},
        {"unknown alias as a tag", "{Phoenix.LiveView, :mount}"},
        {"unknown alias nested in a map", "%{kind: [Phoenix.Endpoint]}"},
        {"variable named apply", "apply = fn _ -> 1 end\napply.(1)"},
        {"AST-shaped tuple is data only", ~s|{{:., [], [Code, :eval_string]}, [], ["1"]}|}
      ])
    end
  end

  describe "captures" do
    test "captures of denied functions are rejected" do
      assert_blocked([
        {"&Code.eval_string/1", "&Code.eval_string/1"},
        {"&:erlang.halt/0", "&:erlang.halt/0"},
        {"&Kernel.spawn/1", "&Kernel.spawn/1"},
        {"capture body calling a denied module", ~s|(& System.cmd("id", [])).()|},
        {"capture body dispatching on its argument", "(&(&1.send(self(), :hi))).(:erlang)"}
      ])
    end

    test "captures of allowed functions still run" do
      assert_runs([
        {"invoked capture", "f = &Enum.sum/1; f.([1, 2, 3])"},
        {"&Map.get/2", "&Map.get/2"},
        {"anonymous capture", "&(&1 + 1)"}
      ])
    end
  end

  describe "raise / reraise force-loading arbitrary modules" do
    test "a literal non-allowlisted exception module is rejected" do
      assert_rejected_with([
        {~s|raise Some.User.Module, message: "hi"|, "raise of Some.User.Module is not allowed"},
        {~s|raise :"Elixir.Some.User.Module", []|, "raise of Some.User.Module is not allowed"},
        {~s|reraise Some.User.Module, [message: "x"], []|,
         "reraise of Some.User.Module is not allowed"}
      ])
    end

    test "an indirected first argument is rejected whatever it holds" do
      assert_rejected_with(
        for code <- [
              "v = :asn1rt_nif; raise v",
              "m = ArgumentError; raise m",
              "raise hd([Some.User.Module])",
              "raise (fn -> Some.Mod end).()",
              "raise Map.get(%{a: Some.Mod}, :a)",
              ~s|raise %{__struct__: RuntimeError, __exception__: true, message: "boom"}|
            ],
            do: {code, "raise requires a literal exception module"}
      )

      assert_rejected_with([
        {~s|v = :asn1rt_nif; reraise v, [message: "x"], []|,
         "reraise requires a literal exception module"}
      ])
    end

    test "captures of raise / reraise are rejected (the module arrives at runtime)" do
      assert_rejected_with([
        {"&raise/1", "&raise/1 is not allowed"},
        {"&raise/2", "&raise/2 is not allowed"},
        {"&reraise/2", "&reraise/2 is not allowed"},
        {"&reraise/3", "&reraise/3 is not allowed"},
        {"&Kernel.raise/1", "Kernel.raise is not allowed"},
        {"&Kernel.reraise/2", "Kernel.reraise is not allowed"}
      ])
    end

    test "stdlib exceptions and string messages still raise" do
      assert {:error, %RuntimeError{message: "boom"}} =
               Sandbox.execute(~s|raise RuntimeError, "boom"|, 5_000)

      assert {:error, %ArgumentError{message: "x"}} =
               Sandbox.execute(~s|raise ArgumentError, "x"|, 5_000)

      assert {:error, %RuntimeError{message: "x=42"}} =
               Sandbox.execute(~S|x = 42; raise "x=#{x}"|, 5_000)
    end
  end

  # Calendar functions take a calendar / time-zone-database module that is
  # dispatched at runtime, force-loading it. The arity that takes it is capped.
  describe "calendar module arguments" do
    test "Date.new/4 is rejected whatever the calendar argument" do
      assert_rejected_with(
        for calendar <- [
              "EvilCal",
              ~s|:"Elixir.EvilCal"|,
              ":asn1rt_nif",
              "(& &1).(:asn1rt_nif)",
              "hd([ExUnit])",
              "Calendar.ISO"
            ],
            do: {"Date.new(2026, 1, 1, #{calendar})", "Date.new/4 is not allowed"}
      )
    end

    test "capped arities are rejected, called or captured" do
      assert_rejected_with([
        {~s|DateTime.shift_zone(DateTime.utc_now(), "Europe/Warsaw", EvilTZ)|,
         "DateTime.shift_zone/3 is not allowed"},
        {"Date.utc_today(EvilCal)", "Date.utc_today/1 is not allowed"},
        {~s|DateTime.from_iso8601("2026-01-01T00:00:00Z", :asn1rt_nif)|,
         "DateTime.from_iso8601/2 is not allowed"},
        {"&Date.new/4", "Date.new/4 is not allowed"},
        {"&DateTime.shift_zone/3", "DateTime.shift_zone/3 is not allowed"},
        {"f = &Date.new/4\nf.(2026, 1, 1, Calendar.ISO)", "Date.new/4 is not allowed"},
        {"Calendar.compatible_calendars?(Calendar.ISO, Calendar.ISO)",
         "Calendar.compatible_calendars? is not allowed"}
      ])
    end

    test "default-calendar forms and non-module atom arguments still run" do
      assert_runs([
        {"Date.new/3", "Date.new(2026, 1, 1)"},
        {"DateTime.utc_now/0", "DateTime.utc_now()"},
        {"DateTime.from_iso8601/1", ~s|DateTime.from_iso8601("2026-01-01T00:00:00Z")|},
        {"unit atom", "Time.truncate(Time.utc_now(), :microsecond)"},
        {"unit atom", "DateTime.from_unix(0, :second)"},
        {"starting-day atom", "Date.beginning_of_week(~D[2026-01-15], :default)"},
        {"starting-day atom", "Date.day_of_week(~D[2026-01-15], :sunday)"},
        {"capture at the arity cap", "&Date.new/3"},
        {"capture at the arity cap", "&DateTime.shift_zone/2"}
      ])
    end
  end

  describe "tool alias-tail collisions" do
    test "an atom-literal call does not unlock the real module behind a tool's tail" do
      for {code, tool, module} <- [
            {~s|:"Elixir.System".cmd("printf", ["pwned"])|, @tools_system, "System"},
            {~s|:"Elixir.Code".eval_string("1 + 1")|, @tools_code, "Code"},
            {~s|:"Elixir.File".read!("/etc/hostname")|, @tools_file, "File"}
          ] do
        assert {:error, message} = Sandbox.execute(code, 5_000, [tool])
        assert message =~ "Module #{module} is not allowed"
      end
    end

    test "a tool's namespace does not unlock modules nested under it" do
      code = ~s|#{inspect(@tools_system)}.Nested.cmd("id", [])|
      assert {:error, message} = ASTChecker.check(code, [@tools_system])
      assert message =~ "Nested is not allowed"
    end

    test "the short name routes to the tool, never to the stdlib module" do
      assert {:ok, {:ok, _}} = Sandbox.execute("System.hello()", 5_000, [@tools_system])

      assert {:error, %UndefinedFunctionError{module: @tools_system, function: :cmd}} =
               Sandbox.execute(~s|System.cmd("echo", ["pwned"])|, 5_000, [@tools_system])
    end
  end

  describe "callbacks and control-flow bodies" do
    test "denied calls inside them are rejected" do
      assert_blocked([
        {"Enum.reduce callback", ~s|Enum.reduce([1], 0, fn _, _ -> :erlang.halt() end)|},
        {"Enum.map callback", ~s|Enum.map([1], fn _ -> System.cmd("id", []) end)|},
        {"Stream.unfold callback",
         "Stream.unfold(0, fn x -> {x, :erlang.halt()} end) |> Stream.run()"},
        {"then callback", ~s|then(1, fn _ -> :erlang.halt() end)|},
        {"tap callback", ~s|tap(1, fn _ -> :erlang.halt() end)|},
        {"pipe into apply", "[:erlang, :halt, []] |> apply()"},
        {"with else clause", ~s|with :nope <- :ok, do: :a, else: (_ -> :erlang.halt())|},
        {"try after", ~s|try do :ok after :erlang.halt() end|},
        {"for reduce", ~s|for x <- [1], reduce: 0 do _ -> :erlang.halt() end|},
        {"fn IIFE", ~s|(fn -> :erlang.halt() end).()|}
      ])
    end

    test "benign callbacks still run" do
      assert_runs([
        {"lazy stream without running it", ~s|Stream.iterate(0, fn x -> x + 1 end)|},
        {"inspect a fn", ~s|inspect(fn -> 1 end)|}
      ])
    end
  end

  # The AST check accepts any bare identifier as a variable; the compiler then
  # refuses to resolve these to the denied local calls.
  test "bare identifiers naming denied calls fail to compile as undefined variables" do
    for code <- ["binding", "super"] do
      assert {:error, message} = Sandbox.execute(code, 5_000)
      assert message =~ ~s|undefined variable "#{code}"|
    end
  end

  test "literals, bitstrings and comprehensions still run" do
    assert_runs([
      {"plain map", "%{a: 1, b: 2}"},
      {"sigil_S", ~s|~S"hello"|},
      {"charlist sigil", ~s|~c"id"|},
      {"to_charlist", ~s|to_charlist("id")|},
      {"utf8 segment", ~s|<<"id"::utf8>>|},
      {"size segment", "<<1::size(8)>>"},
      {"variable size segment", "n = 8\n<<1::size(n)>>"},
      {"size and unit segment", "<<1::size(8)-unit(4)>>"},
      {"shorthand unit segment", "<<255::8-unit(1)>>"},
      {"type and size segment", "<<1::big-integer-size(32)>>"},
      {"for into a map", "for x <- [1], into: %{}, do: {x, x}"},
      {"for into a binary", ~s|for x <- [1], into: "", do: <<x>>|}
    ])
  end
end
