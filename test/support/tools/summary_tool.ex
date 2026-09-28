defmodule Legion.Test.Support.SummaryTool do
  @moduledoc """
  Sums numbers. Also multiplies them when asked.
  """
  use Legion.Tool

  def summary, do: "Custom summary."

  def sum(list), do: Enum.sum(list)
end
