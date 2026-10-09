defmodule Legion.SourceRegistryTest do
  use ExUnit.Case, async: true

  alias Legion.SourceRegistry

  test "returns the source of a module configured in extra_source_modules" do
    assert {:ok, source} = SourceRegistry.source(Jason)
    assert source =~ "defmodule Jason"
    assert SourceRegistry.source!(Jason) == source
  end

  test "rejects a module that is not registered" do
    assert {:error, :not_registered} = SourceRegistry.source(Enum)

    assert_raise RuntimeError, ~r/not registered/, fn ->
      SourceRegistry.source!(Enum)
    end
  end
end
