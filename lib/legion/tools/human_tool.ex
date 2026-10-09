defmodule Legion.Tools.HumanTool do
  @moduledoc """
  Built-in tool for asking a human a question mid-execution.

  ## Configuration

  Configure via `tool_config/1` in your agent:

      def tool_config(Legion.Tools.HumanTool) do
        [handler: MyApp.ChatHandler, timeout: 30_000]
      end

  Options:

    - `:handler` (required) — a pid or registered name that receives
      `{:human_request, ref, from_pid, question, meta}` and must send
      `{:human_response, ref, answer}` back to `from_pid`.
    - `:timeout` — milliseconds to wait for a response. Defaults to `:infinity`.

  `ask/1` blocks inside the code evaluation, so the agent's `sandbox_timeout`
  (60 seconds by default) still applies and kills the eval regardless of this
  setting. Raise it, or set it to `:infinity`, for agents that wait on humans.

  ## Usage (for LLM agent)

      HumanTool.ask("What format do you prefer?")
  """

  use Legion.Tool

  # Over MCP, the caller would write what the application's human handler
  # reads as the agent's question.
  @impl Legion.Tool
  def mcp?, do: false

  @doc """
  Asks a human a question and blocks until they respond.

  Returns the human's answer as a string.

  Only works under `eval_and_continue` - the answer comes back to you as the
  eval result so you can act on it. Under `eval_and_complete` the turn would
  end the moment this code returns and the answer would be discarded, so
  `ask/1` raises there.
  """
  def ask(question) when is_binary(question) do
    if Vault.get(:current_action) == "eval_and_complete" do
      raise "HumanTool.ask/1 must run under eval_and_continue: with eval_and_complete " <>
              "the turn ends when this code returns and the human's answer is discarded. " <>
              "Re-run this code with action eval_and_continue, then act on the answer."
    end

    config = Vault.get(__MODULE__, [])
    handler = config[:handler]

    unless handler do
      raise ArgumentError,
            "HumanTool requires a handler; configure via tool_config/1: [handler: pid_or_name]"
    end

    timeout = config[:timeout] || :infinity
    ref = make_ref()
    send(handler, {:human_request, ref, self(), question, %{agent_id: Vault.get(:agent_id)}})

    receive do
      {:human_response, ^ref, answer} -> answer
    after
      timeout -> raise "HumanTool: timed out waiting for human response after #{timeout}ms"
    end
  end
end
