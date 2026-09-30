defmodule Legion.AgentPrompt do
  @moduledoc false

  # Generates system prompts for agents based on their definitions and the
  # tools they have access to.

  @template_path Path.join(__DIR__, "prompts/system_prompt.eex")
  @external_resource @template_path
  @template EEx.compile_file(@template_path)

  def system_prompt(agent, config \\ nil, opts \\ []) do
    mode = Keyword.get(opts, :mode, :executor)

    # A hand-written `system_prompt/0` is written for the executor's action
    # loop, so only the executor uses it. Over MCP the instructions are always
    # generated; `server_instructions/0` in the server is the override point.
    if mode == :executor and function_exported?(agent, :system_prompt, 0) do
      agent.system_prompt()
    else
      build_system_prompt(agent, config || agent.config(), mode)
    end
  end

  defp build_system_prompt(agent, config, mode) do
    sandbox = Map.get(config, :sandbox, Legion.Sandbox.Lua)
    tool_contents = Enum.map(agent.tools(), &tool_description(&1, sandbox))
    description = agent.moduledoc()
    binding_scope = Map.get(config, :binding_scope, :turn)
    prompt_info = sandbox.prompt_info()

    assigns = [
      mode: mode,
      description: description,
      tool_contents: tool_contents,
      action_types: agent.action_types(),
      plain_text_result?: match?(%{"type" => "string"}, agent.output_schema()),
      binding_scope: binding_scope,
      language: prompt_info.language,
      constraints: String.trim_trailing(prompt_info.constraints),
      tool_usage: prompt_info.tool_usage
    ]

    assigns |> render() |> String.trim()
  end

  # The template is compiled at build time from a file in this repo; the
  # literal attribute keeps that visible to static analysis.
  defp render(assigns), do: elem(Code.eval_quoted(@template, assigns), 0)

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
