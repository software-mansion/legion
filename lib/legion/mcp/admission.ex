defmodule Legion.MCP.Admission do
  @moduledoc false

  # Counts the live MCP sessions and event streams of each server, overall and
  # per client, so `Legion.MCP.Plug` can refuse new ones over its caps. Anubis
  # starts a session for every `initialize` and holds a GET stream open for as
  # long as the client stays, with no limit on either.
  #
  # A session counts from the request that may start it until its process
  # exits. That request runs under an id issued here, and Anubis's
  # `[:anubis_mcp, :server, :init]` event, emitted from the new session's
  # process, names the process to watch. A stream counts while its request
  # runs. Anubis stops writing to a stream once a newer one takes its session,
  # or once the session ends, but leaves its request waiting with no timeout;
  # it is closed here instead.
  #
  # Restarting forgets every session: their requests are then answered as if
  # the sessions were gone, and hosts initialize new ones.

  use GenServer

  @table __MODULE__
  @handler_id {__MODULE__, :session_started}

  @limit_keys %{
    sessions: {:max_sessions, :max_sessions_per_client},
    streams: {:max_streams, :max_streams_per_client}
  }

  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc false
  # Whether `session_id` names a session of `server` started through the plug
  # and still running. Read without a call, since every request asks.
  def live_session?(_server, nil), do: false
  def live_session?(server, session_id), do: :ets.member(@table, {server, session_id})

  @doc false
  # Runs `fun` with the id of the session the request may start, unless
  # `server` or `client` is at its cap. Returns `{:ok, result}` or
  # `{:error, :server | :client}`.
  def with_session(server, client, limits, fun) do
    case GenServer.call(__MODULE__, {:reserve_session, server, client, limits, self()}) do
      {:ok, session_id} ->
        try do
          {:ok, fun.(session_id)}
        after
          GenServer.call(__MODULE__, {:request_done, session_id})
        end

      {:error, _scope} = refused ->
        refused
    end
  end

  @doc false
  # Runs `fun`, the request serving an event stream on `session_id`, unless the
  # session is not a live one of `server` or `server` or `client` is at its
  # cap. Returns `{:ok, result}` or `{:error, :unknown_session | :server |
  # :client}`.
  def with_stream(server, session_id, client, limits, fun) do
    case GenServer.call(__MODULE__, {:open_stream, server, session_id, client, limits, self()}) do
      :ok ->
        try do
          {:ok, fun.()}
        after
          GenServer.call(__MODULE__, {:close_stream, session_id, self()})

          # A close sent as the stream ended would reach the connection
          # process, which goes on to serve the next request on it.
          receive do
            :close_sse -> :ok
          after
            0 -> :ok
          end
        end

      {:error, _reason} = refused ->
        refused
    end
  end

  @doc false
  def session_started(_event, _measurements, %{module: server, session_id: session_id}, _config) do
    GenServer.call(__MODULE__, {:session_started, server, session_id, self()})
  catch
    # Telemetry detaches a handler that fails, and a session started while
    # this process is down is simply not counted.
    :exit, _reason -> :ok
  end

  @impl GenServer
  def init(nil) do
    :ets.new(@table, [:named_table, :protected, read_concurrency: true])

    # A handler outlives the process that attached it, so a restart replaces it.
    :telemetry.detach(@handler_id)

    :ok =
      :telemetry.attach(
        @handler_id,
        [:anubis_mcp, :server, :init],
        &__MODULE__.session_started/4,
        nil
      )

    {:ok, %{sessions: %{}, streams: %{}, monitors: %{}, counts: %{}}}
  end

  @impl GenServer
  def handle_call({:reserve_session, server, client, limits, request}, _from, state) do
    case room(state, :sessions, server, client, limits) do
      :ok ->
        session_id = Base.url_encode64(:crypto.strong_rand_bytes(24), padding: false)
        monitor = Process.monitor(request)
        session = %{server: server, client: client, pid: nil, request: monitor, monitor: nil}

        state =
          state
          |> put_in([:sessions, session_id], session)
          |> put_in([:monitors, monitor], {:request, session_id})
          |> tally(:sessions, server, client, 1)

        {:reply, {:ok, session_id}, state}

      {:error, _scope} = refused ->
        {:reply, refused, state}
    end
  end

  def handle_call({:session_started, server, session_id, pid}, _from, state) do
    state =
      case state.sessions[session_id] do
        %{server: ^server, pid: nil} = session ->
          monitor = Process.monitor(pid)
          :ets.insert(@table, {{server, session_id}})

          state
          |> put_in([:sessions, session_id], %{session | pid: pid, monitor: monitor})
          |> put_in([:monitors, monitor], {:session, session_id})

        _other ->
          state
      end

    {:reply, :ok, state}
  end

  def handle_call({:request_done, session_id}, _from, state),
    do: {:reply, :ok, request_done(state, session_id)}

  def handle_call({:open_stream, server, session_id, client, limits, pid}, _from, state) do
    case state.sessions[session_id] do
      %{server: ^server, pid: session} when is_pid(session) ->
        previous = state.streams[session_id]

        # The stream it replaces does not count against the new one.
        candidate =
          if previous,
            do: tally(state, :streams, previous.server, previous.client, -1),
            else: state

        case room(candidate, :streams, server, client, limits) do
          :ok ->
            {:reply, :ok,
             state |> replace_stream(session_id) |> add_stream(session_id, server, client, pid)}

          {:error, _scope} = refused ->
            {:reply, refused, state}
        end

      _other ->
        {:reply, {:error, :unknown_session}, state}
    end
  end

  def handle_call({:close_stream, session_id, pid}, _from, state) do
    state =
      case state.streams[session_id] do
        %{pid: ^pid} -> remove_stream(state, session_id)
        _other -> state
      end

    {:reply, :ok, state}
  end

  @impl GenServer
  def handle_info({:DOWN, monitor, :process, _pid, _reason}, state) do
    state =
      case state.monitors[monitor] do
        {:request, session_id} -> request_done(state, session_id)
        {:session, session_id} -> drop_session(state, session_id)
        {:stream, session_id} -> remove_stream(state, session_id)
        nil -> state
      end

    {:noreply, state}
  end

  # The request is over: a session it started stays counted, and a
  # reservation it started none under (any request but an `initialize`, or
  # one Anubis refused) is let go.
  defp request_done(state, session_id) do
    case state.sessions[session_id] do
      %{request: monitor, pid: pid} = session when is_reference(monitor) ->
        Process.demonitor(monitor, [:flush])
        state = %{state | monitors: Map.delete(state.monitors, monitor)}

        if pid,
          do: put_in(state, [:sessions, session_id], %{session | request: nil}),
          else: drop_session(state, session_id)

      _other ->
        state
    end
  end

  defp drop_session(state, session_id) do
    {session, sessions} = Map.pop(state.sessions, session_id)
    monitors = Enum.reject([session.request, session.monitor], &is_nil/1)

    for monitor <- monitors, do: Process.demonitor(monitor, [:flush])
    :ets.delete(@table, {session.server, session_id})

    # Anubis stops writing to the stream of an ended session but leaves it open.
    with %{pid: stream} <- state.streams[session_id], do: send(stream, :close_sse)

    %{state | sessions: sessions, monitors: Map.drop(state.monitors, monitors)}
    |> tally(:sessions, session.server, session.client, -1)
  end

  # Anubis writes only to the newest stream of a session and leaves the one it
  # replaced waiting for good.
  defp replace_stream(state, session_id) do
    case state.streams[session_id] do
      %{pid: previous} ->
        send(previous, :close_sse)
        remove_stream(state, session_id)

      nil ->
        state
    end
  end

  defp add_stream(state, session_id, server, client, pid) do
    monitor = Process.monitor(pid)
    stream = %{server: server, client: client, pid: pid, monitor: monitor}

    state
    |> put_in([:streams, session_id], stream)
    |> put_in([:monitors, monitor], {:stream, session_id})
    |> tally(:streams, server, client, 1)
  end

  defp remove_stream(state, session_id) do
    {stream, streams} = Map.pop(state.streams, session_id)
    Process.demonitor(stream.monitor, [:flush])

    %{state | streams: streams, monitors: Map.delete(state.monitors, stream.monitor)}
    |> tally(:streams, stream.server, stream.client, -1)
  end

  defp room(state, kind, server, client, limits) do
    {overall, per_client} = @limit_keys[kind]

    cond do
      full?(state.counts[{kind, server, client}], limits[per_client]) -> {:error, :client}
      full?(state.counts[{kind, server}], limits[overall]) -> {:error, :server}
      true -> :ok
    end
  end

  defp full?(_count, :infinity), do: false
  defp full?(count, limit), do: (count || 0) >= limit

  defp tally(state, kind, server, client, delta) do
    counts =
      for key <- [{kind, server}, {kind, server, client}], reduce: state.counts do
        counts ->
          case Map.get(counts, key, 0) + delta do
            0 -> Map.delete(counts, key)
            count -> Map.put(counts, key, count)
          end
      end

    %{state | counts: counts}
  end
end
