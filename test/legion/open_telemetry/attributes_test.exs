defmodule Legion.OpenTelemetry.AttributesTest do
  @moduledoc """
  Serializing content into span attributes, within `max_attribute_bytes`.
  """

  use ExUnit.Case, async: true

  alias Legion.OpenTelemetry.Attributes

  @config [content: :attributes, max_attribute_bytes: 20_000]

  describe "execute_tool_stop/2" do
    test "a small result JSON cannot encode is recorded whole" do
      result = for i <- 1..60, do: {i, "name#{i}"}

      attributes = Attributes.execute_tool_stop(%{success: true, result: result}, @config)

      assert attributes[:"gen_ai.tool.call.result"] == inspect(result, limit: :infinity)
    end

    test "a large result JSON cannot encode is cut to the cap" do
      result = for i <- 1..2_500, do: {i, String.duplicate("x", 20_000)}

      attributes = Attributes.execute_tool_stop(%{success: true, result: result}, @config)
      text = attributes[:"gen_ai.tool.call.result"]

      assert byte_size(text) == 20_000
      assert text =~ ~r/^\[\{1, "x+/
      assert String.ends_with?(text, "…[truncated]")
    end
  end

  describe "truncate/2" do
    test "stays within a cap smaller than the truncation marker" do
      assert Attributes.truncate("abcdefghijklmnopqrstuvwxyz", 5) == "abcde"
    end
  end
end
