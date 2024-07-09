defmodule Kadabra.Connection do
  @moduledoc false

  defstruct buffer: "",
            config: nil,
            flow_control: nil,
            remote_window: 65_535,
            remote_settings: nil,
            requested_streams: 0,
            local_settings: nil,
            queue: nil

  use GenServer

  require Logger

  import Kernel, except: [send: 2]

  alias Kadabra.{
    Config,
    Connection,
    Hpack,
    Socket
  }

  alias Kadabra.Connection.{Egress, FlowControl, Processor}

  @type t :: %__MODULE__{
          buffer: binary,
          config: term,
          flow_control: term,
          local_settings: Connection.Settings.t(),
          queue: pid
        }

  @type sock :: {:sslsocket, any, pid | {any, any}}

  def start_link(%Config{} = config) do
    GenServer.start_link(__MODULE__, config)
  end

  def init(%Config{} = config) do
    {:ok, encoder} = Hpack.start_link()
    {:ok, decoder} = Hpack.start_link()
    {:ok, socket} = Socket.start_link(config.uri, config.opts)

    Logger.info("[KADABRA] Socket: #{inspect(socket)}")

    config =
      config
      |> Map.put(:encoder, encoder)
      |> Map.put(:decoder, decoder)
      |> Map.put(:socket, socket)

    state = initial_state(config)

    Kernel.send(self(), :start)
    Process.flag(:trap_exit, true)

    {:ok, state}
  end

  defp initial_state(%Config{opts: opts, queue: queue} = config) do
    settings = Keyword.get(opts, :settings, Connection.Settings.fastest())

    %__MODULE__{
      config: config,
      queue: queue,
      local_settings: settings,
      flow_control: %FlowControl{}
    }
  end

  def close(pid) do
    GenServer.call(pid, :close)
  end

  def ping(pid) do
    GenServer.cast(pid, {:send, :ping})
  end

  # handle_cast

  def handle_cast({:send, type}, state) do
    sendf(type, state)
  end

  def handle_cast({:request, events}, state) do
    Logger.info "[KADABRA] Connection request"
    state = do_send_headers(events, state)
    Logger.info "[KADABRA] Connection request"
    {:noreply, state}
  end

  def handle_cast(_msg, state) do
    {:noreply, state}
  end

  # handle_call

  def handle_call(:close, _from, %Connection{} = state) do
    Logger.info "[KADABRA] Connection close"
    %Connection{
      flow_control: flow,
      config: config
    } = state

    Egress.send_goaway(config.socket, flow.stream_set.stream_id)

    {:stop, :shutdown, :ok, state}
  end

  # sendf

  @spec sendf(:goaway | :ping, t) :: {:noreply, t}
  def sendf(:ping, %Connection{config: config} = state) do
    Logger.info "[KADABRA] ping"
    Egress.send_ping(config.socket)
    {:noreply, state}
  end

  def sendf(elses, state) do
    Logger.info "[KADABRA] else #{elses}"
    {:noreply, state}
  end

  defp do_send_headers(request, %{flow_control: flow} = state) do
    flow =
      flow
      |> FlowControl.add(request)
      |> FlowControl.process(state.config)

    Logger.info "[KADABRA] do send headers #{inspect(flow)}"

    %{state | flow_control: flow}
  end

  def handle_info(:start, %{config: %{socket: socket}} = state) do
    Logger.info "[KADABRA] Connection start #{inspect(socket)}"
    Socket.set_active(socket)
    Egress.send_local_settings(socket, state.local_settings)

    {:noreply, state}
  end

  def handle_info({:closed, _pid}, state) do
    Logger.info "[KADABRA] Connection close"
    {:stop, :shutdown, state}
  end

  def handle_info({:EXIT, _pid, {:shutdown, {:finished, sid}}}, state) do
    Logger.info "[KADABRA] exit"
    GenServer.cast(state.queue, {:ask, 1})

    flow =
      state.flow_control
      |> FlowControl.finish_stream(sid)
      |> FlowControl.process(state.config)

    {:noreply, %{state | flow_control: flow}}
  end

  def handle_info({:push_promise, stream}, %{config: config} = state) do
    Logger.info "[KADABRA] push promise #{inspect(state)}"
    Kernel.send(config.client, {:push_promise, stream})
    {:noreply, state}
  end

  def handle_info({:recv, frame}, state) do
    Logger.info "[KADABRA] outside recv"
    case Processor.process(frame, state) do
      {:ok, state} ->
        Logger.info "[KADABRA] recv"
        {:noreply, state}

      {:connection_error, error, reason, state} ->
        Logger.error "[KADABRA] Connection error #{inspect(error)} #{inspect(reason)}"
        Egress.send_goaway(
          state.config.socket,
          state.flow_control.stream_set.stream_id,
          error,
          reason
        )

        {:stop, {:shutdown, :connection_error}, state}
    end
  end

  def terminate(_reason, %{config: config}) do
    Logger.error "[KADABRA] terminate"
    Kernel.send(config.client, {:closed, config.queue})
    :ok
  end
end
