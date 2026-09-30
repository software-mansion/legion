defmodule Legion.Test.Support.DescribedTool do
  @moduledoc false
  use Legion.Tool

  def description, do: "DescribedTool - counts things. Nothing else."

  def count(list), do: length(list)
end
