defmodule Legion.Test.Support.SlowTool do
  @moduledoc "A tool that takes as long as it is told."
  use Legion.Tool

  def description, do: "SlowTool - waits."

  def wait(ms), do: Process.sleep(ms)
end
