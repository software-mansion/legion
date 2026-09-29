defmodule Legion.Sandbox.Runner do
  @moduledoc """
  Runs a sandbox evaluation function in a monitored process with resource
  limits. Shared by every `Legion.Sandbox` implementation, so timeout, memory,
  and CPU budgets behave identically regardless of language.

  `limits` bound what the evaluating process may take from the node:

    - `:max_heap` — memory budget in bytes, applied twice: the VM kills the
      eval when its heap and stack exceed it, and the parent kills it when the
      binaries it references do (those live off-heap, so the VM flag misses
      them). Set `:infinity` to disable (default: `256_000_000`)
    - `:max_reductions` — CPU budget in reductions, enforced by polling. Set
      `:infinity` to disable (default: `:infinity`)
    - `:priority` — scheduler priority for the eval, any value `Process.flag/2`
      accepts (default: `:low`, so generated code yields to the rest of the node)
  """

  alias Legion.Telemetry

  # Generated code runs with a memory budget by default
  @default_max_heap 256_000_000

  @doc false
  def default_max_heap, do: @default_max_heap

  @doc """
  Runs `eval_fun` in a spawned, monitored, resource-limited process.

  `eval_fun` must return `{:ok, {value, bindings}}` or `{:error, reason}`;
  that result is passed through. The runner adds `{:error, :timeout}`,
  `{:error, reason}` for exceeded limits, and `{:error, {:process_crashed,
  reason}}` for crashes.
  """
  def run(eval_fun, timeout_ms, limits \\ [])
      when is_function(eval_fun, 0) and (is_integer(timeout_ms) or timeout_ms == :infinity) do
    parent = self()

    # 0 is ambiguous: "no limit" to the BEAM's max_heap_size flag, but a
    # budget here would floor at the VM minimum heap and kill nearly every
    # eval - refuse it rather than guess.
    max_heap_bytes =
      case Keyword.get(limits, :max_heap, @default_max_heap) do
        0 -> raise ArgumentError, "max_heap: 0 is ambiguous - pass :infinity to disable the limit"
        bytes -> bytes
      end

    max_reductions = Keyword.get(limits, :max_reductions, :infinity)
    priority = Keyword.get(limits, :priority, :low)

    # Tool code (and any agent it calls) runs under the caller's
    # OpenTelemetry context, so its spans nest under the eval's.
    otel_ctx = Telemetry.capture_context()

    {pid, ref} =
      spawn_monitor(fn ->
        kill_eval_when_parent_dies(parent)

        Process.flag(:priority, priority)

        if is_integer(max_heap_bytes) do
          {:min_heap_size, min_words} = :erlang.system_info(:min_heap_size)
          heap_words = max(div(max_heap_bytes, :erlang.system_info(:wordsize)), min_words)
          Process.flag(:max_heap_size, %{size: heap_words, kill: true, error_logger: false})
        end

        send(parent, {:result, self(), Telemetry.with_context(otel_ctx, eval_fun)})
      end)

    deadline =
      if timeout_ms == :infinity,
        do: :infinity,
        else: System.monotonic_time(:millisecond) + timeout_ms

    await_result(pid, ref, deadline, max_reductions, max_heap_bytes)
  end

  # How often the parent samples the eval's reduction counter and binary
  # footprint. Only relevant when one of those limits is set - either budget
  # can be overshot by up to one interval's worth of work.
  @poll_interval_ms 50

  defp await_result(pid, ref, deadline, max_reductions, max_heap_bytes) do
    receive do
      {:result, ^pid, result} ->
        Process.demonitor(ref, [:flush])
        result

      # A :killed exit with a heap budget set is the VM enforcing it - nothing
      # else brutally kills the eval while we still hold its monitor.
      {:DOWN, ^ref, :process, _pid, :killed} when is_integer(max_heap_bytes) ->
        {:error, memory_limit_error()}

      {:DOWN, ^ref, :process, _pid, reason} ->
        {:error, {:process_crashed, reason}}
    after
      wait_ms(deadline, polling?(max_reductions, max_heap_bytes)) ->
        reductions = reductions_over_budget(pid, max_reductions)
        binary_bytes = binaries_over_budget(pid, max_heap_bytes)

        cond do
          deadline != :infinity and System.monotonic_time(:millisecond) >= deadline ->
            kill(pid, ref)
            {:error, :timeout}

          reductions != nil ->
            kill(pid, ref)

            {:error,
             "evaluation exceeded the reduction (CPU) limit after ~#{reductions} reductions and was killed"}

          binary_bytes != nil ->
            kill(pid, ref)
            {:error, memory_limit_error()}

          true ->
            await_result(pid, ref, deadline, max_reductions, max_heap_bytes)
        end
    end
  end

  defp memory_limit_error, do: "evaluation exceeded the memory limit and was killed"

  defp kill_eval_when_parent_dies(parent) do
    eval = self()

    spawn(fn ->
      parent_ref = Process.monitor(parent)
      eval_ref = Process.monitor(eval)

      receive do
        {:DOWN, ^parent_ref, :process, _pid, _reason} -> Process.exit(eval, :kill)
        {:DOWN, ^eval_ref, :process, _pid, _reason} -> :ok
      end
    end)
  end

  defp polling?(max_reductions, max_heap_bytes),
    do: is_integer(max_reductions) or is_integer(max_heap_bytes)

  defp wait_ms(:infinity, false), do: :infinity
  defp wait_ms(deadline, false), do: max(deadline - System.monotonic_time(:millisecond), 0)
  defp wait_ms(:infinity, true), do: @poll_interval_ms

  defp wait_ms(deadline, true) do
    deadline
    |> Kernel.-(System.monotonic_time(:millisecond))
    |> max(0)
    |> min(@poll_interval_ms)
  end

  defp reductions_over_budget(_pid, :infinity), do: nil

  defp reductions_over_budget(pid, max_reductions) do
    # nil process_info means the eval already exited - its final message is
    # in our mailbox and the next receive picks it up.
    case Process.info(pid, :reductions) do
      {:reductions, reductions} when reductions > max_reductions -> reductions
      _ -> nil
    end
  end

  defp binaries_over_budget(_pid, :infinity), do: nil

  defp binaries_over_budget(pid, max_heap_bytes) do
    # :max_heap_size counts the heap and stack only, so binaries over 64 bytes
    # - the cheapest way for generated code to eat the node - slip past it.
    # A process can reference the same binary many times, hence the uniq.
    with {:binary, entries} <- Process.info(pid, :binary) do
      bytes =
        entries
        |> Enum.uniq_by(&elem(&1, 0))
        |> Enum.sum_by(&elem(&1, 1))

      if bytes > max_heap_bytes, do: bytes
    end
  end

  defp kill(pid, ref) do
    Process.demonitor(ref, [:flush])
    Process.exit(pid, :kill)

    # The eval may have finished between the budget check and the kill -
    # drop its stray result so it cannot leak into the caller's mailbox.
    receive do
      {:result, ^pid, _result} -> :ok
    after
      0 -> :ok
    end
  end
end
