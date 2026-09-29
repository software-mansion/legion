defmodule Legion.OpenTelemetry.Attributes do
  @moduledoc false

  # GenAI semantic-convention attributes for Legion's own spans, and the
  # serialization of message content when `content: :attributes` is on.
  # Keys are atoms, like the ones ReqLLM's bridge hands to adapters.

  alias ReqLLM.Message.ContentPart

  @truncated "…[truncated]"

  @doc "The `gen_ai.agent.name` of an agent module."
  def agent_name(agent), do: inspect(agent)

  @doc "Attributes every Legion span carries, so Datadog keeps it."
  def agent(agent, agent_id) do
    drop_nils(%{
      "gen_ai.agent.name": agent_name(agent),
      "gen_ai.conversation.id": agent_id
    })
  end

  def conversation(meta) do
    meta.agent
    |> agent(meta[:agent_id])
    |> Map.put(:"gen_ai.agent.id", meta[:agent_id])
    |> drop_nils()
  end

  def invoke_agent_start(meta, config) do
    meta.agent
    |> agent(meta[:agent_id])
    |> Map.merge(%{
      "gen_ai.operation.name": "invoke_agent",
      "gen_ai.agent.id": meta[:agent_id],
      "legion.parent_agent_id": meta[:parent_agent_id]
    })
    |> put_content(config, :"gen_ai.input.messages", fn max ->
      input_messages(meta[:message], max)
    end)
    |> drop_nils()
  end

  def invoke_agent_stop(meta, model, config) do
    status = if meta[:status] == :ok, do: "ok", else: "cancelled"

    base =
      drop_nils(%{
        "legion.iterations": meta[:iterations],
        "legion.status": status,
        "gen_ai.request.model": model_name(model),
        "gen_ai.provider.name": provider_name(model)
      })

    case meta[:status] do
      :ok ->
        put_content(base, config, :"gen_ai.output.messages", fn max ->
          output_messages(meta[:result], max)
        end)

      _cancel ->
        reason = cancel_reason(meta[:result])
        Map.merge(base, %{"legion.cancel.reason": reason, "error.type": reason})
    end
  end

  def execute_tool_start(meta, iteration, config) do
    meta.agent
    |> agent(meta[:agent_id])
    |> Map.merge(%{
      "gen_ai.operation.name": "execute_tool",
      "gen_ai.tool.name": "sandbox",
      "gen_ai.tool.type": "extension",
      "legion.iteration": iteration
    })
    |> put_content(config, :"gen_ai.tool.call.arguments", &truncate(meta[:code], &1))
    |> drop_nils()
  end

  def execute_tool_stop(%{success: true} = meta, config) do
    put_content(%{"legion.eval.success": true}, config, :"gen_ai.tool.call.result", fn max ->
      truncate(term_text(meta[:result]), max)
    end)
  end

  def execute_tool_stop(_meta, _config), do: %{"legion.eval.success": false}

  def iteration(agent, agent_id, iteration) do
    agent
    |> agent(agent_id)
    |> Map.put(:"legion.iteration", iteration)
  end

  @doc """
  Classifies a failed eval for `legion.eval.errors` and `error.type`.
  """
  def eval_error_kind(_error, true = _guard_denied?), do: "guard_denied"
  def eval_error_kind(:timeout, _), do: "timeout"
  def eval_error_kind({:process_crashed, _}, _), do: "crash"
  def eval_error_kind("refused by " <> _, _), do: "guard_denied"
  def eval_error_kind("evaluation exceeded " <> _, _), do: "limit"
  def eval_error_kind(_error, _), do: "runtime"

  @doc "The status message of a failed eval span."
  def error_message(message, max) when is_binary(message), do: truncate(message, max)

  def error_message(error, max) when is_exception(error),
    do: truncate(Exception.message(error), max)

  def error_message(error, max), do: truncate(inspect(error, limit: 50), max)

  @doc "`error.type` for an exception event's `kind`/`reason`."
  def exception_type(_kind, %{__exception__: true} = exception), do: inspect(exception.__struct__)
  def exception_type(kind, _reason), do: Atom.to_string(kind)

  def cancel_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  def cancel_reason({reason, _detail}) when is_atom(reason), do: Atom.to_string(reason)
  def cancel_reason(reason), do: inspect(reason)

  @doc "`gen_ai.provider.name` from a ReqLLM model spec, e.g. `\"openai:gpt-5.4\"`."
  def provider_name(model) when is_binary(model) do
    case String.split(model, ":", parts: 2) do
      [provider, _model] -> provider
      _ -> nil
    end
  end

  def provider_name({provider, _model_id, _opts}) when is_atom(provider),
    do: Atom.to_string(provider)

  def provider_name({provider, _opts}) when is_atom(provider), do: Atom.to_string(provider)
  def provider_name(%{provider: provider}) when is_atom(provider), do: Atom.to_string(provider)
  def provider_name(_model), do: nil

  @doc "`gen_ai.request.model` from a ReqLLM model spec."
  def model_name(model) when is_binary(model) do
    case String.split(model, ":", parts: 2) do
      [_provider, name] -> name
      [name] -> name
    end
  end

  def model_name({_provider, model_id, _opts}) when is_binary(model_id), do: model_id
  def model_name({_provider, opts}) when is_list(opts), do: stringify(opts[:id] || opts[:model])
  def model_name(%{id: id}) when is_binary(id), do: id
  def model_name(_model), do: nil

  @doc """
  Truncates `string` to at most `max` bytes on a UTF-8 boundary, marking the cut.
  """
  def truncate(nil, _max), do: nil
  def truncate(string, max) when byte_size(string) <= max, do: string

  def truncate(string, max) do
    keep = max(max - byte_size(@truncated), 0)
    utf8_prefix(string, keep) <> @truncated
  end

  defp utf8_prefix(string, bytes) do
    case :unicode.characters_to_binary(binary_part(string, 0, bytes)) do
      prefix when is_binary(prefix) -> prefix
      {_incomplete_or_error, prefix, _rest} -> prefix
    end
  end

  # Semconv input messages: one JSON string holding
  # `[{"role": ..., "parts": [{"type": "text", "content": ...}]}]`.
  defp input_messages(content, max) do
    Jason.encode!([%{"role" => "user", "parts" => parts(content, max)}])
  end

  defp output_messages(result, max) do
    parts = if result == nil, do: [], else: [text_part(term_text(result), max)]
    Jason.encode!([%{"role" => "assistant", "parts" => parts, "finish_reason" => "stop"}])
  end

  defp parts(content, max) when is_binary(content), do: [text_part(content, max)]
  defp parts(content, max) when is_list(content), do: Enum.map(content, &part(&1, max))
  defp parts(nil, _max), do: []
  defp parts(content, max), do: [text_part(inspect(content), max)]

  defp part(%ContentPart{type: :text, text: text}, max), do: text_part(text, max)

  defp part(%ContentPart{type: type} = part, _max) do
    drop_nils(%{"type" => Atom.to_string(type), "bytes" => bytes(part.data)})
  end

  defp part(other, max), do: text_part(term_text(other), max)

  defp text_part(text, max), do: %{"type" => "text", "content" => truncate(text || "", max)}

  defp bytes(data) when is_binary(data), do: byte_size(data)
  defp bytes(_data), do: nil

  defp term_text(text) when is_binary(text), do: text

  defp term_text(term) do
    case Jason.encode(term) do
      {:ok, json} -> json
      {:error, _} -> inspect(term, limit: :infinity, printable_limit: :infinity)
    end
  end

  defp put_content(attributes, config, key, fun) do
    case config[:content] do
      :attributes -> Map.put(attributes, key, fun.(config[:max_attribute_bytes]))
      _none -> attributes
    end
  end

  defp stringify(nil), do: nil
  defp stringify(value) when is_binary(value), do: value
  defp stringify(value), do: to_string(value)

  defp drop_nils(map), do: map |> Enum.reject(fn {_k, v} -> is_nil(v) end) |> Map.new()
end
