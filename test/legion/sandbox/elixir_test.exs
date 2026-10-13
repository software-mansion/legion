defmodule Legion.Sandbox.ElixirTest do
  use ExUnit.Case, async: true

  doctest Legion.Sandbox.Elixir, import: true

  alias Legion.Sandbox.Elixir, as: Sandbox

  test "returns result and bindings" do
    assert {:ok, {5, bindings}} = Sandbox.execute("a = 2 + 2\na + 1", 15_000)
    assert Keyword.get(bindings, :a) == 4
  end

  test "bindings survive the term round-trip a store does" do
    {:ok, {_result, bindings}} = Sandbox.execute("posts = [1, 2, 3]", 15_000)

    revived = bindings |> :erlang.term_to_binary() |> :erlang.binary_to_term()

    assert {:ok, {6, _}} = Sandbox.execute("Enum.sum(posts)", 15_000, [], revived)
    assert Sandbox.binding_names(revived) == [:posts]
  end

  test "bindings accumulate across calls" do
    {:ok, {_, b1}} = Sandbox.execute("x = 10", 15_000)
    {:ok, {_, b2}} = Sandbox.execute("y = 20", 15_000, [], b1)
    assert {:ok, {30, _}} = Sandbox.execute("x + y", 15_000, [], b2)
  end

  test "throw returns an error tuple instead of crashing" do
    assert {:error, {:throw, :foo}} = Sandbox.execute("throw(:foo)", 15_000)
  end

  test "exit returns an error tuple instead of crashing" do
    assert {:error, {:exit, :boom}} = Sandbox.execute("exit(:boom)", 15_000)
  end

  test "eval exceeding the heap budget is killed with a memory error" do
    assert {:error, message} =
             Sandbox.execute("Enum.to_list(1..50_000_000)", 15_000, [], [], max_heap: 10_000_000)

    assert message =~ "memory limit"
  end

  test "a brutal kill without a heap budget reports a crash, not a memory limit" do
    # The AST checker blocks Process for generated code; allowing it here is
    # the only way to provoke the :killed exit an external kill would cause.
    assert {:error, {:process_crashed, :killed}} =
             Sandbox.execute("Process.exit(self(), :kill)", 15_000, [Process], [],
               max_heap: :infinity
             )
  end

  test "eval exceeding the reduction budget is killed with a CPU error" do
    code = "Enum.reduce(1..100_000_000, 0, fn n, acc -> acc + n end)"

    assert {:error, message} =
             Sandbox.execute(code, 60_000, [], [], max_reductions: 1_000_000)

    assert message =~ "reduction (CPU) limit"
  end

  test "heap and reduction budgets leave ordinary evals untouched" do
    assert {:ok, {499_500, _}} =
             Sandbox.execute("Enum.sum(1..999)", 15_000, [], [],
               max_heap: 10_000_000,
               max_reductions: 1_000_000
             )
  end

  test "eval piling up binaries is killed by the heap budget even though they live off-heap" do
    code = """
    chunk = String.duplicate("x", 1_000_000)
    Enum.reduce(1..500, "", fn _, acc -> acc <> chunk end) |> byte_size()
    """

    assert {:error, message} =
             Sandbox.execute(code, 30_000, [], [], max_heap: 10_000_000)

    assert message =~ "memory limit"
  end

  test "binaries under the heap budget are left alone, even referenced many times over" do
    code = """
    chunk = String.duplicate("x", 1_000_000)
    List.duplicate(chunk, 500) |> Enum.map(&byte_size/1) |> Enum.sum()
    """

    assert {:ok, {500_000_000, _}} =
             Sandbox.execute(code, 30_000, [], [], max_heap: 10_000_000)
  end

  test "a heap budget below the VM's minimum still bounds the eval" do
    assert {:error, message} =
             Sandbox.execute("Enum.to_list(1..3_000_000)", 15_000, [], [], max_heap: 4)

    assert message =~ "memory limit"
  end

  test "a heap budget of 0 raises instead of guessing what it means" do
    assert_raise ArgumentError, ~r/pass :infinity/, fn ->
      Sandbox.execute("1 + 1", 15_000, [], [], max_heap: 0)
    end
  end

  test "priority defaults to low and is configurable" do
    # Process is off limits to generated code; the test allows it to read the flag back.
    code = "Process.info(self(), :priority)"

    assert {:ok, {{:priority, :low}, _}} = Sandbox.execute(code, 15_000, [Process])

    assert {:ok, {{:priority, :normal}, _}} =
             Sandbox.execute(code, 15_000, [Process], [], priority: :normal)
  end

  test "compile error surfaces diagnostics instead of the generic wrapper message" do
    code = ~S|x = 1
String.upcase(t)|

    assert {:error, msg} = Sandbox.execute(code, 15_000)
    assert is_binary(msg)
    assert msg =~ "undefined variable"
    assert msg =~ "\"t\""
    refute msg =~ "cannot compile file"
  end

  test "runtime exception is returned as the original struct" do
    assert {:error, %RuntimeError{message: "boom"}} =
             Sandbox.execute(~S|raise "boom"|, 15_000)
  end

  test "Calendar module is callable from sandboxed code" do
    code = ~S|Calendar.strftime(~D[2026-04-17], "%Y-%m-%d")|
    assert {:ok, {"2026-04-17", _}} = Sandbox.execute(code, 15_000)
  end
end
