defmodule Legion.Executor do
  @moduledoc """
  Drives the LLM thinking loop for a single agent turn.

  Given a complete message history, calls the LLM, parses its response, runs
  sandboxed code if needed, and recurses until the LLM signals completion.

  Returns the final result and updated message history so the caller can persist
  context across turns.
  """

  alias Legion.{EvalGuard, Telemetry}
  alias Legion.Sandbox.Runner

  @default_config %{
    model: "openai:gpt-5.4",
    max_iterations: 10,
    max_retries: 3,
    sandbox: Legion.Sandbox.Lua,
    sandbox_timeout: 60_000,
    sandbox_max_heap: Runner.default_max_heap(),
    sandbox_max_reductions: :infinity,
    sandbox_priority: :low,
    eval_guard: nil,
    binding_scope: :turn,
    max_message_length: 20_000
  }

  @doc false
  def default_config, do: @default_config

  @message_roles %{
    system: "system",
    user: "user",
    assistant: "assistant",
    eval_result: "user",
    error: "user"
  }

  @doc """
  Builds a conversation message stamped with its `:type` and creation time
  (`:at`, milliseconds). The extra keys ride along into persisted state so
  consumers (e.g. LegionWeb) can classify messages without parsing content;
  ReqLLM ignores them.
  """
  def message(type, content) do
    %{
      role: Map.fetch!(@message_roles, type),
      type: type,
      content: content,
      at: System.system_time(:millisecond)
    }
  end

  @action_descriptions %{
    "eval_and_continue" =>
      "Execute code and continue the turn. Use when you need the result before deciding the next step.",
    "eval_and_complete" =>
      "Finish the turn with the code's result. Use when the final answer comes from executing code.",
    "return" =>
      "Finish the turn with a result and no code execution. Only use when the task is fully done - not to report in-progress work, ask the user something, or bail out of execution errors (fix the code and re-run instead). The result is a final answer, not a chat message: never return a status like \"starting\" or \"working on it\" - do the work first.",
    "done" =>
      "Finish the turn with no result to return. This ends your run - nothing executes after it, so only use it when everything you were asked to do is fully done. Never announce upcoming work and then pick this action; do the work first (eval_and_continue)."
  }

  defp action_schema(agent_module, config) do
    types = agent_module.action_types()
    language = config.sandbox.prompt_info().language

    description =
      types
      |> Enum.map_join("\n", fn t -> "- \"#{t}\": #{action_description(t, agent_module)}" end)

    %{
      "type" => "object",
      "required" => ["action", "code", "result"],
      "additionalProperties" => false,
      "properties" => %{
        "action" => %{
          "type" => "string",
          "enum" => types,
          "description" => "The action to take:\n" <> description
        },
        "code" => %{
          "type" => "string",
          "description" =>
            "#{language} code to execute. Required for eval_* actions. Empty string otherwise."
        },
        "result" => enforce_no_additional_properties(agent_module.output_schema())
      }
    }
  end

  defp action_description("return", agent_module) do
    if plain_text_output?(agent_module) do
      "Finish the turn with your final answer and no code execution. The result is plain text shown to the user - never wrap it in JSON. " <>
        "Only use when the task is fully done - not to report in-progress work, ask the user something, or bail out of execution errors (fix the code and re-run instead). " <>
        "The result is a final answer, not a chat message: never return a status like \"starting\" or \"working on it\" - do the work first."
    else
      Map.fetch!(@action_descriptions, "return")
    end
  end

  defp action_description(type, _agent_module), do: Map.fetch!(@action_descriptions, type)

  defp plain_text_output?(agent_module),
    do: match?(%{"type" => "string"}, agent_module.output_schema())

  # OpenAI strict mode requires `additionalProperties: false` on every object
  # in the schema tree. Inject it recursively so users don't have to.
  defp enforce_no_additional_properties(%{"type" => "object", "properties" => props} = schema) do
    props = Map.new(props, fn {k, v} -> {k, enforce_no_additional_properties(v)} end)

    schema
    |> Map.put("properties", props)
    |> Map.put("additionalProperties", false)
  end

  defp enforce_no_additional_properties(%{"type" => "array", "items" => items} = schema) do
    Map.put(schema, "items", enforce_no_additional_properties(items))
  end

  defp enforce_no_additional_properties(schema), do: schema

  @doc """
  Runs the LLM loop against the given message history.

  `messages` must already include the system prompt and the current user message.
  `bindings` seeds the code-evaluation binding. `executor_state` resumes a step
  checkpoint when present: `:awaiting_llm` continues from its saved iteration
  and retry counters, while `:completing` finishes without another LLM request.
  Pass `:nonexistent` (the default) to start a new loop. `:turn_usage` is the turn's combined
  usage: one map per LLM request, in order, holding the tokens the response reported and
  `"evals" => 1` when the request's action ran code. Each map's `"message_index"` is the
  position in the returned `messages` of the assistant message it produced, or `nil` when the
  response had no usable object.

  Returns `{:ok, result, messages, bindings, turn_usage}` or
  `{:cancel, reason, messages, bindings, turn_usage}`.
  """
  def run(agent_module, messages, config, bindings \\ [], executor_state \\ :nonexistent) do
    config = Map.merge(@default_config, config)

    case executor_state do
      :nonexistent ->
        loop(agent_module, messages, config, 0, 0, bindings, [])

      %{phase: :awaiting_llm, iteration: i, retries: r} ->
        loop(agent_module, messages, config, i, r, bindings, [])

      %{phase: :completing, iteration: _i, retries: _r} ->
        {:ok, nil, messages, bindings, []}
    end
  end

  defp loop(agent_module, messages, config, iteration, retries, bindings, turn_usage) do
    if iteration >= config.max_iterations do
      {:cancel, :reached_max_iterations, messages, bindings, turn_usage}
    else
      Telemetry.span(
        [:legion, :iteration],
        %{agent: agent_module, iteration: iteration},
        fn ->
          iterate(agent_module, messages, config, iteration, retries, bindings, turn_usage)
        end
      )
    end
  end

  defp iterate(agent_module, messages, config, iteration, retries, bindings, turn_usage) do
    # credo:disable-for-next-line
    llm_result =
      try do
        call_llm(agent_module, messages, config, iteration, turn_usage)
      rescue
        error -> {:error, error, turn_usage}
      end

    case llm_result do
      {:ok, action, messages, turn_usage} ->
        case validate_action_type(agent_module, action) do
          :ok ->
            result =
              handle_action(
                agent_module,
                messages,
                config,
                action,
                iteration,
                retries,
                bindings,
                turn_usage
              )

            {result, %{action: action["action"]}}

          {:error, reason} ->
            result =
              handle_execution_error(
                agent_module,
                messages,
                config,
                reason,
                iteration,
                retries,
                bindings,
                turn_usage
              )

            {result, %{action: nil}}
        end

      {:error, reason, turn_usage} ->
        result =
          handle_execution_error(
            agent_module,
            messages,
            config,
            reason,
            iteration,
            retries,
            bindings,
            turn_usage
          )

        {result, %{action: nil}}
    end
  end

  defp call_llm(agent_module, messages, config, iteration, turn_usage) do
    message_count = length(messages)

    Telemetry.span(
      [:legion, :llm, :request],
      %{
        agent: agent_module,
        model: config.model,
        message_count: message_count,
        iteration: iteration
      },
      fn ->
        case ReqLLM.generate_object(config.model, messages, action_schema(agent_module, config)) do
          {:ok, response} ->
            handle_llm_response(response, messages, message_count, turn_usage)

          {:error, reason} ->
            {{:error, "LLM request failed: #{inspect(reason)}", turn_usage}, %{error: reason}}
        end
      end
    )
  end

  defp handle_llm_response(response, messages, message_count, turn_usage) do
    usage =
      (response.usage || %{})
      |> normalize_usage()
      |> Map.put("at", System.system_time(:millisecond))

    case extract_object(response) do
      {:ok, action} when is_map(action) ->
        usage = Map.put(usage, "message_index", message_count)
        messages = messages ++ [message(:assistant, Jason.encode!(action))]
        {{:ok, action, messages, turn_usage ++ [usage]}, %{object: action, usage: usage}}

      {:error, reason} ->
        # No message stored for this request: its slot goes to the retry
        # prompt, or stays empty when retries run out.
        usage = Map.put(usage, "message_index", nil)

        {{:error, "LLM response object invalid: #{inspect(reason)}", turn_usage ++ [usage]},
         %{error: reason, usage: usage}}
    end
  end

  defp normalize_usage(usage) when is_map(usage) do
    Map.new(usage, fn {key, value} ->
      {normalize_usage_key(key), normalize_usage(value)}
    end)
  end

  defp normalize_usage(usage) when is_list(usage), do: Enum.map(usage, &normalize_usage/1)
  defp normalize_usage(usage), do: usage

  defp normalize_usage_key(key) when is_atom(key), do: Atom.to_string(key)
  defp normalize_usage_key(key), do: key

  defp checkpoint!(config, messages, bindings, executor_state) do
    case config[:checkpoint] do
      nil ->
        :ok

      callback ->
        try do
          :ok =
            callback.(%{
              messages: messages,
              bindings: bindings,
              executor_state: executor_state
            })
        rescue
          error -> exit({:checkpoint_persistence_failed, error})
        end
    end
  end

  defp handle_action(
         _agent,
         messages,
         _config,
         %{"action" => "return", "result" => result},
         _i,
         _r,
         bindings,
         turn_usage
       ),
       do: {:ok, result, messages, bindings, turn_usage}

  defp handle_action(
         _agent,
         messages,
         _config,
         %{"action" => "done"},
         _i,
         _r,
         bindings,
         turn_usage
       ),
       do: {:ok, nil, messages, bindings, turn_usage}

  defp handle_action(
         agent,
         messages,
         config,
         %{"action" => eval, "code" => code},
         i,
         retries,
         bindings,
         turn_usage
       )
       when eval in ["eval_and_continue", "eval_and_complete"] and code != "" do
    # Tools that must see the answer come back to the model (e.g. HumanTool)
    # read this to reject running under a turn-ending action.
    Vault.unsafe_put(:current_action, eval)

    # Flags the request whose action ran code: this is what `:max_evals`
    # counts. Set before the run so a failed evaluation counts too.
    turn_usage = List.update_at(turn_usage, -1, &Map.put(&1, "evals", 1))

    case eval_in_span(agent, code, config, bindings) do
      {:ok, {result, new_bindings}} ->
        new_bindings = if config.binding_scope == :iteration, do: [], else: new_bindings

        messages =
          messages ++ [message(:eval_result, format_result(result, new_bindings, config))]

        executor_state =
          if eval == "eval_and_continue" do
            %{phase: :awaiting_llm, iteration: i + 1, retries: 0}
          else
            %{phase: :completing, iteration: i, retries: 0}
          end

        checkpoint!(config, messages, new_bindings, executor_state)

        if eval == "eval_and_continue",
          do: loop(agent, messages, config, i + 1, 0, new_bindings, turn_usage),
          else: {:ok, result, messages, new_bindings, turn_usage}

      {:error, error} ->
        handle_execution_error(agent, messages, config, error, i, retries, bindings, turn_usage)
    end
  end

  defp handle_action(agent, messages, config, action, i, retries, bindings, turn_usage),
    do:
      handle_execution_error(
        agent,
        messages,
        config,
        "Unexpected action: #{inspect(action)}",
        i,
        retries,
        bindings,
        turn_usage
      )

  defp eval_in_span(agent_module, code, config, bindings) do
    Telemetry.span([:legion, :sandbox, :eval], %{agent: agent_module, code: code}, fn ->
      tools = agent_module.tools()

      allowed = tools ++ Enum.flat_map(tools, &extra_allowed_modules/1)

      sandbox_limits = [
        max_heap: config.sandbox_max_heap,
        max_reductions: config.sandbox_max_reductions,
        priority: config.sandbox_priority
      ]

      guard_context = %{agent: agent_module, agent_id: Vault.get(:agent_id), tools: tools}

      with :ok <- config.sandbox.check(code, allowed),
           :allow <- EvalGuard.check(config.eval_guard, code, guard_context),
           {:ok, {value, new_bindings}} <-
             config.sandbox.execute(
               code,
               config.sandbox_timeout,
               allowed,
               bindings,
               sandbox_limits
             ) do
        {{:ok, {value, new_bindings}}, %{success: true, result: value}}
      else
        {:deny, reason} ->
          error = "refused by #{inspect(config.eval_guard)}: #{reason}"
          {{:error, error}, %{success: false, error: error}}

        {:error, error} ->
          {{:error, error}, %{success: false, error: error}}
      end
    end)
  end

  defp extra_allowed_modules(tool) do
    if function_exported?(tool, :extra_allowed_modules, 0) do
      tool.extra_allowed_modules()
    else
      []
    end
  end

  defp handle_execution_error(
         agent_module,
         messages,
         config,
         error,
         iteration,
         retries,
         bindings,
         turn_usage
       ) do
    if retries >= config.max_retries do
      {:cancel, :reached_max_retries, messages, bindings, turn_usage}
    else
      error_text = error |> format_error() |> truncate_content(config[:max_message_length])

      messages =
        messages ++
          [
            message(
              :error,
              "Code execution failed:\n\n#{error_text}\n\nPlease fix the error and try again."
            )
          ]

      next_retries = retries + 1

      checkpoint!(config, messages, bindings, %{
        phase: :awaiting_llm,
        iteration: iteration,
        retries: next_retries
      })

      loop(agent_module, messages, config, iteration, next_retries, bindings, turn_usage)
    end
  end

  defp validate_action_type(agent_module, %{"action" => action_type}) do
    allowed = agent_module.action_types()

    if action_type in allowed do
      :ok
    else
      {:error,
       "Action #{inspect(action_type)} is not allowed for #{inspect(agent_module)}. " <>
         "Allowed: #{inspect(allowed)}"}
    end
  end

  defp validate_action_type(_agent_module, action) do
    {:error, "Response missing required 'action' field, got: #{inspect(action)}"}
  end

  defp extract_object(%{object: object}) when is_map(object), do: {:ok, object}

  defp extract_object(%{message: %{tool_calls: tool_calls}}) when is_list(tool_calls) do
    case ReqLLM.ToolCall.find_args(tool_calls, "structured_output") do
      args when is_map(args) -> {:ok, args}
      _ -> {:error, "LLM response contained no structured object"}
    end
  end

  defp extract_object(_response), do: {:error, "LLM response contained no structured object"}

  defp format_result(result, bindings, config) do
    variable_names = bindings |> config.sandbox.binding_names() |> Enum.map(&"`#{&1}`")

    inspected =
      result
      |> inspect(pretty: true, limit: 1000)
      |> truncate_content(config[:max_message_length])

    base = """
    Code executed successfully. Result:
    ```
    #{inspected}
    ```
    """

    if variable_names == [] do
      base
    else
      base <> "\nAvailable variables: #{Enum.join(variable_names, ", ")}"
    end
  end

  defp format_error(message) when is_binary(message), do: message
  defp format_error(%{message: message}) when is_binary(message), do: message
  defp format_error(error) when is_exception(error), do: Exception.message(error)
  defp format_error(error), do: inspect(error, pretty: true, limit: 50)

  @doc false
  def truncate_content(content, :infinity), do: content

  def truncate_content(content, max)
      when is_binary(content) and is_integer(max) and byte_size(content) > max do
    binary_part(content, 0, max) <> "\n\n[... truncated #{byte_size(content) - max} bytes ...]"
  end

  def truncate_content(content, _max), do: content
end
