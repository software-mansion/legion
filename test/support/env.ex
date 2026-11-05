defmodule Legion.Test.Support.Env do
  @moduledoc """
  Application and system environment set for one test and restored after it.
  """

  def put_env(app, key, value) do
    previous = Application.fetch_env(app, key)
    Application.put_env(app, key, value)

    ExUnit.Callbacks.on_exit(fn ->
      case previous do
        {:ok, previous} -> Application.put_env(app, key, previous)
        :error -> Application.delete_env(app, key)
      end
    end)
  end

  def put_system_env(variable, value) do
    previous = System.get_env(variable)
    System.put_env(variable, value)

    ExUnit.Callbacks.on_exit(fn ->
      if previous, do: System.put_env(variable, previous), else: System.delete_env(variable)
    end)
  end
end
