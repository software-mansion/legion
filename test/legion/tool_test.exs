defmodule Legion.ToolTest do
  use ExUnit.Case, async: true

  describe "extract_module_source/2" do
    for {case_name, module, code} <- [
          {"a plain module", MyApp.Greeter,
           """
           defmodule MyApp.Greeter do
             def hello, do: "hi"
           end
           """},
          {"nested do/end blocks", MyApp.Nested,
           """
           defmodule MyApp.Nested do
             def run do
               if true do
                 :ok
               end
             end
           end
           """},
          {"fn blocks", MyApp.WithFn,
           """
           defmodule MyApp.WithFn do
             def run do
               Enum.map([1], fn x ->
                 x + 1
               end)
             end
           end
           """},
          {"a nested module", MyApp.Outer,
           """
           defmodule MyApp.Outer do
             defmodule Inner do
               def inner_fn, do: :inner
             end

             def outer_fn, do: :outer
           end
           """},
          {"do/end inside strings and comments", MyApp.Strings,
           """
           defmodule MyApp.Strings do
             def example do
               # this end should not count
               x = "do not end this"
               x
             end
           end
           """},
          {"do/end inside a heredoc", MyApp.Heredoc,
           ~S'''
           defmodule MyApp.Heredoc do
             @moduledoc """
             Use this tool to end the session.
             You can also do things with it.
             """

             def hello, do: :hi
           end
           '''},
          {"do/end inside a single-quoted charlist", MyApp.Charlist,
           """
           defmodule MyApp.Charlist do
             def chars do
               'this end should not count'
             end
           end
           """}
        ] do
      test "extracts the whole module with #{case_name}" do
        code = String.trim_trailing(unquote(code))
        assert Legion.Tool.extract_module_source(code, unquote(module)) == code
      end
    end

    test "stops at the end of the requested module when others follow" do
      code = """
      defmodule MyApp.First do
        def one, do: 1
      end

      defmodule MyApp.Second do
        def two, do: 2
      end
      """

      assert Legion.Tool.extract_module_source(code, MyApp.First) ==
               "defmodule MyApp.First do\n  def one, do: 1\nend"
    end

    test "raises unless the source defines the module under its full name" do
      code = """
      defmodule MyApp.Outer do
        defmodule Inner do
          def inner_fn, do: :inner
        end
      end
      """

      assert_raise RuntimeError, ~r/Could not find/, fn ->
        Legion.Tool.extract_module_source(code, MyApp.Missing)
      end

      assert_raise RuntimeError, ~r/Could not find/, fn ->
        Legion.Tool.extract_module_source(code, MyApp.Outer.Inner)
      end
    end
  end

  describe "summary/0" do
    alias Legion.Test.Support.{BareTool, DescribedTool, MathTool, SummaryTool}

    test "defaults to the first sentence of the moduledoc" do
      assert MathTool.summary() == "This is math tool moduledoc."
    end

    test "cuts a multi-sentence moduledoc at the first sentence" do
      assert Legion.Tool.default_summary(SummaryTool) == "Sums numbers."
    end

    test "falls back to the first sentence of a hand-written description/0" do
      assert DescribedTool.summary() == "DescribedTool - counts things."
    end

    test "falls back to the short module name when the description is the source" do
      assert BareTool.summary() == "BareTool"
    end

    test "an overriding summary/0 wins" do
      assert SummaryTool.summary() == "Custom summary."
    end

    test "default_summary/1 reads the moduledoc of a module that does not use Legion.Tool" do
      assert Legion.Tool.default_summary(Jason) =~ "JSON"
    end

    # Modules compiled from a file in memory have no Docs chunk to read.
    @tag :tmp_dir
    test "summary/0 comes from the moduledoc even without a Docs chunk", %{tmp_dir: dir} do
      {tool, _warnings} = compile_tool(dir, "def add(a, b), do: a + b")

      assert tool.summary() == "Adds numbers."
    end

    @tag :tmp_dir
    test "warns when a summary/0 not marked @impl takes over", %{tmp_dir: dir} do
      {tool, [warning]} = compile_tool(dir, "def summary, do: %{total: 1}")

      assert warning =~ "#{inspect(tool)}.summary/0 is taken as the tool's one-line summary"
    end

    @tag :tmp_dir
    test "an @impl summary/0 and the generated one compile without warning", %{tmp_dir: dir} do
      assert {_tool, []} = compile_tool(dir, "@impl Legion.Tool\ndef summary, do: \"x\"")
      assert {_tool, []} = compile_tool(dir, "def add(a, b), do: a + b")
    end
  end

  # A unique module name per call keeps --repeat-until-failure free of
  # redefinition warnings, and diagnostics are collected in this process so
  # concurrent tests writing to stderr cannot leak in.
  defp compile_tool(dir, body) do
    name = "Legion.CompiledTool#{System.unique_integer([:positive])}"
    path = Path.join(dir, "#{name}.ex")

    File.write!(path, """
    defmodule #{name} do
      use Legion.Tool
      @moduledoc "Adds numbers. More text."
      #{body}
    end
    """)

    {[{tool, _bytecode}], diagnostics} = Code.with_diagnostics(fn -> Code.compile_file(path) end)
    {tool, Enum.map(diagnostics, & &1.message)}
  end
end
