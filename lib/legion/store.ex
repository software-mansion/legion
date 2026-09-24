defmodule Legion.Store do
  @moduledoc """
  Behaviour for persisting agent conversations across restarts.

  Legion decides *when* to persist; your store decides *where*. Pass a store
  module and an agent id when starting an agent:

      {:ok, pid} = Legion.start_link(AssistantAgent, store: MyApp.AgentStore, agent_id: "user_42")

  On start, the agent calls `get/1` and resumes from the returned
  `Legion.Store.Payload` when it has a `:conversation_state`. The system prompt
  is regenerated for every start, so prompt and tool changes apply to restored
  conversations.

  By default, Legion saves after appending the external user message and again
  after completing the turn. The final save happens before replying to the
  caller, so a reply is a commit receipt: any observed turn survives a crash,
  restart, or deploy.

  A store can opt into step persistence by implementing
  `persistence_frequency/0` and returning `:step`. Legion then also saves
  after intermediate user-role messages, including eval results and recoverable
  errors. Each step save contains the complete conversation and executor state
  at that checkpoint.

  For Postgres users there is a built-in adapter - see `Legion.Store.Postgres`:

      defmodule MyApp.AgentStore do
        use Legion.Store.Postgres, repo: MyApp.Repo
      end

  ## Configuring the store

  Pass `:store` per agent, or set one globally so every agent persists by default:

      config :legion, :store, MyApp.AgentStore

  Stores default to `:turn` persistence. To persist intermediate executor
  steps, return `:step`:

      defmodule MyApp.AgentStore do
        @behaviour Legion.Store

        def persistence_frequency, do: :step

        # Implement get/1, list/1, and save/1...
      end

  A `:store` given to `start_link/2` overrides the global one. Sub-agents
  spawned from a running agent (e.g. via `Legion.Tools.AgentTool`) inherit
  the parent's store automatically. The inheritance is ambient: *any* agent
  started from within an agent's process tree picks up that store unless
  given an explicit `:store` of its own.

  ## Usage tracking

  Legion persists a string-keyed copy of `ReqLLM.Response.usage` for every LLM
  request in a conversation, ordered by request. Each map includes an `"at"`
  Unix timestamp in milliseconds for when Legion received the response, and a
  `"message_index"`, the position in `:messages` of the message it produced.
  Tracking is enabled by default. Disable it globally before starting an agent:

      config :legion, :track_usage, false

  The setting is read when an agent starts. Disabled agents neither restore nor
  update usage; existing usage in a store is preserved.

  ## Identifying a conversation

  `:agent_id` is the key a conversation is saved under - it names one
  conversation, not one user. A chat app with many chats per user keys by the
  chat. Agent ids must be valid UTF-8 strings, but Legion otherwise treats their
  contents as opaque, so compose them however you like:

      Legion.start_link(ChatAgent, agent_id: "user_42:chat_7")

  Omitting `:agent_id` makes Legion generate one. That suits a brand-new conversation:
  read it back with `Legion.get_agent_id/1` and persist the mapping if you want to resume
  the chat later.

  ## Required callbacks

  Stores must implement `get/1`, `list/1`, and `save/1`.

  `save/1` receives a `Legion.Store.Payload`. Its `:conversation_state` is a
  map containing the conversation's `:messages` (without the system prompt),
  `:bindings` from evaluated code, and `:executor_state`. `:executor_state` is
  `:nonexistent` for ordinary snapshots and is a map with `:phase`, `:iteration`,
  and `:retries` for step checkpoints. `:status` records whether the agent is
  mid-turn. The payload also carries the agent module, parent conversation,
  and start time when those values are known. Its `:usage` field is the ordered
  list of string-keyed LLM usage maps when tracking is enabled; see "Usage
  tracking" for the `"at"` and `"message_index"` keys each map carries.

  With `binding_scope: :turn`, active bindings are included in step snapshots
  while the turn is running and cleared from the final snapshot. Bindings with
  `binding_scope: :conversation` remain in the final snapshot, while
  iteration-scoped bindings are cleared before a step is saved.

  Each message carries a `:type` (`:user`, `:assistant`, `:eval_result`, or
  `:error`) and an `:at` timestamp in milliseconds, so consumers can classify
  and order messages without parsing content. Bindings are arbitrary Elixir
  terms - a pid or reference stops meaning anything after a restart, and a
  captured function raises when called after its defining module has been
  recompiled - so keep conversation-scoped variables to plain data if you
  persist agents.

  Payload fields other than `:agent_id` may be nil. A store can therefore
  persist identity or status before a conversation state exists. Stores must
  treat nil fields as omitted partial updates so later state-only saves preserve
  metadata and the running status.

  Step persistence accepts a replay window between an LLM selecting an eval
  action and the following result or error checkpoint. A crash in that window
  can replay the action and any external side effects. Configure
  `:recovery` with stores, a store scan limit, and a concurrent request limit
  to recover interrupted root turns once when the Legion application starts;
  see `Legion.Recovery` and `Legion.recover/2`.

  ## Reading conversations

  `get/1` receives a valid UTF-8 `agent_id` and returns its persisted
  conversation, or `:error` when the store has no row for that id.

  `list/1` returns persisted conversations newest first for consumers that
  rebuild a view of past conversations from the store alone.
  """

  alias Legion.Store.Payload

  @type agent_id :: String.t()
  @type status :: Payload.status()
  @type payload :: Payload.t()
  @type persistence_frequency :: :turn | :step

  @doc "Returns the persisted conversation for `agent_id`, or `:error` if none exists."
  @callback get(agent_id()) :: {:ok, payload()} | :error

  @doc "Returns the newest `limit` persisted conversations, newest first."
  @callback list(limit :: pos_integer()) :: [payload()]

  @doc "Saves a conversation payload."
  @callback save(payload()) :: :ok | :error

  @doc "Returns how frequently Legion persists conversation state for this store."
  @callback persistence_frequency() :: persistence_frequency()

  @optional_callbacks persistence_frequency: 0

  @doc false
  def persistence_frequency(nil), do: :turn

  def persistence_frequency(store) do
    frequency =
      if Code.ensure_loaded?(store) and function_exported?(store, :persistence_frequency, 0) do
        store.persistence_frequency()
      else
        :turn
      end

    if frequency in [:turn, :step] do
      frequency
    else
      raise ArgumentError,
            "#{inspect(store)}.persistence_frequency/0 must return " <>
              ":turn or :step, got: #{inspect(frequency)}"
    end
  end
end
