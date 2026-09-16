defmodule Legion.AgentPrompt do
  @moduledoc false

  # Generates system prompts for agents based on their definitions and the
  # tools they have access to.

  @executor_template_path Path.join(__DIR__, "prompts/system_prompt.eex")
  @mcp_template_path Path.join(__DIR__, "prompts/mcp_instructions.eex")
  @external_resource @executor_template_path
  @external_resource @mcp_template_path
  @executor_template EEx.compile_file(@executor_template_path)
  @mcp_template EEx.compile_file(@mcp_template_path)

  # `mode: :executor` (default) renders the JSON action-loop prompt used by
  # `Legion.Executor`; `mode: :mcp` renders the instructions an MCP host gets,
  # where the model calls a `repl` tool instead. An agent's `system_prompt/0`
  # override wins in both modes.
  def system_prompt(agent, config \\ nil, opts \\ []) do
    if function_exported?(agent, :system_prompt, 0) do
      agent.system_prompt()
    else
      build_system_prompt(agent, config || agent.config(), Keyword.get(opts, :mode, :executor))
    end
  end

  defp build_system_prompt(agent, config, mode) do
    sandbox = Map.get(config, :sandbox, Legion.Sandbox.Lua)
    tool_contents = Enum.map(agent.tools(), &tool_description(&1, sandbox))
    description = agent.moduledoc()
    binding_scope = Map.get(config, :binding_scope, :turn)
    prompt_info = sandbox.prompt_info()

    assigns = [
      description: description,
      tool_contents: tool_contents,
      action_types: agent.action_types(),
      plain_text_result?: match?(%{"type" => "string"}, agent.output_schema()),
      binding_scope: binding_scope,
      language: prompt_info.language,
      constraints: String.trim_trailing(prompt_info.constraints),
      tool_usage: prompt_info.tool_usage
    ]

    mode |> render(assigns) |> String.trim()
  end

  # Both templates are compiled at build time from files in this repo; the
  # literal attribute per clause keeps that visible to static analysis.
  defp render(:executor, assigns), do: elem(Code.eval_quoted(@executor_template, assigns), 0)
  defp render(:mcp, assigns), do: elem(Code.eval_quoted(@mcp_template, assigns), 0)

  defp tool_description(module, sandbox) do
    Code.ensure_loaded!(module)

    content =
      cond do
        function_exported?(module, :description, 1) ->
          module.description(sandbox)

        function_exported?(module, :description, 0) ->
          module.description()

        true ->
          Legion.SourceRegistry.source!(module)
      end

    short_name = module |> Module.split() |> List.last()
    {short_name, String.trim(content)}
  end
end
