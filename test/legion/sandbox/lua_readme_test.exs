defmodule Legion.Sandbox.LuaReadmeTest.OrdersTool do
  use Legion.Tool

  @doc "The signed-in customer's orders, newest first"
  def my_orders, do: Vault.get(:orders)

  @doc "Carrier tracking status of one of the customer's orders"
  def track(order_id), do: "order #{order_id} ships tomorrow"
end

defmodule Legion.Sandbox.LuaReadmeTest do
  @moduledoc """
  Runs the generated-code snippet shown in README.md through the Lua sandbox,
  read from the README itself. If a test here fails, the README needs a fix.
  """
  use ExUnit.Case, async: true

  alias Legion.Sandbox.Lua
  alias Legion.Sandbox.LuaReadmeTest.OrdersTool

  setup do
    readme = File.read!(Path.expand("../../../README.md", __DIR__))
    [snippet] = Regex.run(~r/```lua\n(.*?)```/s, readme, capture: :all_but_first)

    %{snippet: snippet}
  end

  test "the README snippet tracks the order holding a hoodie", %{snippet: snippet} do
    Vault.init(
      orders: [
        %{id: 7, items: ["Mug"]},
        %{id: 5, items: ["Socks", "Grey Hoodie"]}
      ]
    )

    assert Lua.execute(snippet, 15_000, [OrdersTool]) == {:ok, {"order 5 ships tomorrow", []}}
  end

  test "the README snippet says so when no order holds a hoodie", %{snippet: snippet} do
    Vault.init(orders: [%{id: 7, items: ["Mug"]}])

    assert Lua.execute(snippet, 15_000, [OrdersTool]) ==
             {:ok, {"no hoodie in recent orders", []}}
  end
end
