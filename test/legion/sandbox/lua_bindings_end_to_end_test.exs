defmodule Legion.Sandbox.LuaBindingsEndToEndTest.CatalogTool do
  use Legion.Tool

  def description, do: "CatalogTool - a catalog of talks."

  @doc "Every talk in the catalog, with nested tags and speaker."
  def talks do
    for id <- 1..300 do
      %{id: id, title: "Talk #{id}", tags: ["lua", "elixir"], speaker: %{name: "Speaker #{id}"}}
    end
  end

  @doc "Reports how a value passed from Lua arrives in Elixir."
  def describe(value), do: %{module: is_atom(value), inspected: inspect(value)}
end

defmodule Legion.Sandbox.LuaBindingsEndToEndTest.AdminTool do
  use Legion.Tool

  def description, do: "AdminTool - privileged operations, reports every call to the test."

  def wipe(marker) do
    send(:lua_bindings_end_to_end_test, {:admin_reached, marker})
    "wiped #{marker}"
  end
end

defmodule Legion.Sandbox.LuaBindingsEndToEndTest do
  @moduledoc """
  Drives a conversation-scoped Lua agent through the whole stack - scripted
  LLM, bridged tools, the Postgres store, restarts - and checks what the
  persisted bindings carry across each boundary.
  """
  use ExUnit.Case, async: false
  use Mimic

  alias Legion.Sandbox.LuaBindingsEndToEndTest.AdminTool
  alias Legion.Sandbox.LuaBindingsEndToEndTest.CatalogTool
  alias Legion.Store.Payload
  alias Legion.Test.Support.PostgresRepo, as: Repo

  @moduletag capture_log: true

  defmodule CuratorAgent do
    @moduledoc "Curates the talk catalog and may run privileged admin operations."
    use Legion.Agent

    def tools, do: [CatalogTool, AdminTool]
    def config, do: %{binding_scope: :conversation}
  end

  defmodule RestrictedCuratorAgent do
    @moduledoc "The same agent after AdminTool was taken away."
    use Legion.Agent

    def tools, do: [CatalogTool]
    def config, do: %{binding_scope: :conversation}
  end

  defmodule Store do
    use Legion.Store.Postgres, repo: Legion.Test.Support.PostgresRepo
  end

  setup :set_mimic_global

  setup do
    Repo.query!("TRUNCATE legion_agents", [])
    Process.register(self(), :lua_bindings_end_to_end_test)
    :ok
  end

  test "globals survive a restart as plain data; dead tool results and functions do not" do
    {:ok, pid} = Legion.start_link(CuratorAgent, store: Store, agent_id: "curator-restart")

    assert {:ok, 100} =
             evaluate(pid, """
             local talks = CatalogTool.talks()
             favorites = {}
             for _, talk in ipairs(talks) do
               if talk.id % 3 == 0 then table.insert(favorites, talk) end
             end
             count = #favorites
             function summarize() return count end
             return count
             """)

    # The model is told which variables it can rely on next time.
    %{content: content} =
      pid |> Legion.get_messages() |> Enum.filter(&(&1.type == :eval_result)) |> List.last()

    assert content =~ "Available variables:"
    assert content =~ "`count`"
    assert content =~ "`favorites`"
    refute content =~ "`summarize`"
    refute content =~ "`talks`"

    # The store holds exactly the two user globals - none of the 300 talks the
    # model dropped, no Lua function, and nothing that references host code.
    assert {:ok, %Payload{conversation_state: state}} = Store.get("curator-restart")
    assert [{"count", 100}, {"favorites", favorites}] = Enum.sort(state.bindings)
    assert length(favorites) == 100

    assert hd(favorites) == %{
             "id" => 3,
             "title" => "Talk 3",
             "tags" => ["lua", "elixir"],
             "speaker" => %{"name" => "Speaker 3"}
           }

    refute holds_function?(state)

    GenServer.stop(pid)
    {:ok, revived} = Legion.start_link(CuratorAgent, store: Store, agent_id: "curator-restart")

    assert {:ok, %{"count" => 100, "first" => "Talk 3", "summarize" => "nil"}} =
             evaluate(revived, """
             return {count = count, first = favorites[1].title, summarize = type(summarize)}
             """)
  end

  test "a tool removed between restarts is unreachable, even when the model stashed it" do
    {:ok, pid} = Legion.start_link(CuratorAgent, store: Store, agent_id: "curator-revoked")

    assert {:ok, "wiped before"} =
             evaluate(pid, """
             admin = AdminTool.wipe
             admin_ref = AdminTool
             catalog = CatalogTool
             return admin("before")
             """)

    assert_receive {:admin_reached, "before"}

    # Tool references persist as their marker table; the stashed bridge does not.
    assert {:ok, %Payload{conversation_state: %{bindings: bindings}}} =
             Store.get("curator-revoked")

    assert Enum.sort(bindings) == [
             {"admin_ref", %{"__module" => Atom.to_string(AdminTool)}},
             {"catalog", %{"__module" => Atom.to_string(CatalogTool)}}
           ]

    GenServer.stop(pid)

    {:ok, restricted} =
      Legion.start_link(RestrictedCuratorAgent, store: Store, agent_id: "curator-revoked")

    # A reference to a tool the agent still has resolves to the module; one to
    # the revoked tool stays an inert table.
    catalog_name = inspect(CatalogTool)

    assert {:ok,
            %{
              "admin" => "nil",
              "admin_tool" => "nil",
              "admin_ref" => %{"module" => false},
              "catalog" => %{"module" => true, "inspected" => ^catalog_name}
            }} =
             evaluate(restricted, """
             return {
               admin = type(admin),
               admin_tool = type(AdminTool),
               admin_ref = CatalogTool.describe(admin_ref),
               catalog = CatalogTool.describe(catalog),
             }
             """)

    refute_received {:admin_reached, _marker}
  end

  test "a global shadowing a tool name does not break later evaluations or restarts" do
    {:ok, pid} = Legion.start_link(CuratorAgent, store: Store, agent_id: "curator-shadow")

    assert {:ok, 1} = evaluate(pid, "CatalogTool = 1\nreturn CatalogTool")
    assert {:ok, %Payload{conversation_state: %{bindings: []}}} = Store.get("curator-shadow")
    assert {:ok, 300} = evaluate(pid, "return #CatalogTool.talks()")

    GenServer.stop(pid)
    {:ok, revived} = Legion.start_link(CuratorAgent, store: Store, agent_id: "curator-shadow")

    assert {:ok, 300} = evaluate(revived, "return #CatalogTool.talks()")
  end

  test "functions do not persist between evaluations within a turn, data does" do
    {:ok, pid} = Legion.start_link(CuratorAgent, store: Store, agent_id: "curator-turn")

    assert {:ok, %{"helper" => "nil", "count" => 1}} =
             evaluate(pid, [
               "function helper() return 1 end\ncount = 1",
               "return {helper = type(helper), count = count}"
             ])
  end

  # One turn: the scripted LLM answers the n-th request with the n-th chunk -
  # `eval_and_continue` for all but the last, which is `eval_and_complete`.
  defp evaluate(pid, code) when is_binary(code), do: evaluate(pid, [code])

  defp evaluate(pid, chunks) do
    requests = :counters.new(1, [:atomics])

    stub(ReqLLM, :generate_object, fn _model, _messages, _schema, _opts ->
      :counters.add(requests, 1, 1)
      index = :counters.get(requests, 1)
      action = if index == length(chunks), do: "eval_and_complete", else: "eval_and_continue"

      {:ok,
       %ReqLLM.Response{
         id: "test",
         model: "test",
         context: nil,
         object: %{"action" => action, "code" => Enum.at(chunks, index - 1), "result" => ""},
         usage: %{turn_usage: 0}
       }}
    end)

    Legion.call(pid, Enum.join(chunks, "\n"))
  end

  defp holds_function?(term) when is_function(term), do: true
  defp holds_function?(%_{} = struct), do: struct |> Map.from_struct() |> holds_function?()
  defp holds_function?(map) when is_map(map), do: map |> Map.to_list() |> holds_function?()
  defp holds_function?(list) when is_list(list), do: Enum.any?(list, &holds_function?/1)

  defp holds_function?(tuple) when is_tuple(tuple),
    do: tuple |> Tuple.to_list() |> holds_function?()

  defp holds_function?(_other), do: false
end
