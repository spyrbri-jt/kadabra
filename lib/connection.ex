defmodule Kadabra.Connection do
  @moduledoc """
  Worker for maintaining an open HTTP/2 connection.
  """

  defstruct ref: nil,
            buffer: "",
            client: nil,
            uri: nil,
            scheme: :https,
            opts: [],
            socket: nil,
            stream_id: 1,
            reconnect: true,
            settings: nil,
            overflow: [],
            encoder_state: nil,
            decoder_state: nil,
            flow_control: nil

  use GenServer
  require Logger

  alias Kadabra.{ConnectionSettings, Encodable, Error, FlowControl, Frame, Hpack,
    Http2, Stream}
  alias Kadabra.Frame.{Continuation, Data, Goaway, Headers, Ping,
    PushPromise, RstStream, WindowUpdate}

  @data 0x0
  @headers 0x1
  @rst_stream 0x3
  @settings 0x4
  @push_promise 0x5
  @ping 0x6
  @goaway 0x7
  @window_update 0x8
  @continuation 0x9

  def start_link(uri, pid, opts \\ []) do
    GenServer.start_link(__MODULE__, {:ok, uri, pid, opts})
  end

  def init({:ok, uri, pid, opts}) do
    case do_connect(uri, opts) do
      {:ok, socket} ->
        state = initial_state(socket, uri, pid, opts)
        {:ok, state}
      {:error, error} ->
        Logger.error(inspect(error))
        {:error, error}
    end
  end

  defp initial_state(socket, uri, pid, opts) do
   {:ok, encoder} = Hpack.start_link
   {:ok, decoder} = Hpack.start_link
   {:ok, settings} = ConnectionSettings.start_link
   {:ok, flow} = FlowControl.start_link
   %__MODULE__{
      ref: :erlang.make_ref,
      client: pid,
      uri: uri,
      scheme: opts[:scheme] || :https,
      opts: opts,
      socket: socket,
      reconnect: opts[:reconnect],
      settings: settings,
      encoder_state: encoder,
      decoder_state: decoder,
      flow_control: flow
    }
  end

  def do_connect(uri, opts) do
    case opts[:scheme] do
      :http -> {:error, :not_implemented}
      :https -> do_connect_ssl(uri, opts)
      _ -> {:error, :bad_scheme}
    end
  end

  def do_connect_ssl(uri, opts) do
    :ssl.start()
    ssl_opts = ssl_options(opts[:ssl])
    case :ssl.connect(uri, opts[:port], ssl_opts) do
      {:ok, ssl} ->
        :ssl.send(ssl, Http2.connection_preface)
        bin = %Frame.Settings{} |> Encodable.to_bin
        :ssl.send(ssl, bin)
        {:ok, ssl}
      {:error, reason} ->
        {:error, reason}
    end
  end

  defp ssl_options(nil), do: ssl_options([])
  defp ssl_options(opts) do
    opts ++ [
      {:active, :once},
      {:packet, :raw},
      {:reuseaddr, false},
      {:alpn_advertised_protocols, [<<"h2">>]},
      :binary
    ]
  end

  def handle_call(:get_info, _from, state) do
    {:reply, {:ok, state}, state}
  end

  def handle_cast({:send, :headers, headers}, state) do
    new_state = do_send_headers(headers, nil, state)
    {:noreply, new_state}
  end

  def handle_cast({:send, :headers, headers, payload}, state) do
    new_state = do_send_headers(headers, payload, state)
    {:noreply, new_state}
  end

  def handle_cast({:recv, frame}, state) do
    recv(frame, state)
  end

  def handle_cast({:send, type}, state) do
    sendf(type, state)
  end

  def handle_cast(msg, state) do
    IO.inspect msg
    {:noreply, state}
  end

  # sendf

  def sendf(:ping, %{socket: socket} = state) do
    bin = Ping.new |> Encodable.to_bin
    :ssl.send(socket, bin)
    {:noreply, state}
  end

  def sendf(:goaway, %{socket: socket, stream_id: stream_id} = state) do
    bin = stream_id |> Goaway.new |> Encodable.to_bin
    :ssl.send(socket, bin)
    {:noreply, increment_stream_id(state)}
  end

  # recv

  def recv(%Frame.Data{} = frame, state) do
    case pid_for_stream(state.ref, frame.stream_id) do
      nil -> nil
      pid -> Stream.cast_recv(pid, frame)
    end
    {:noreply, state}
  end

  def recv(%Frame.Headers{} = frame, state) do
    case pid_for_stream(state.ref, frame.stream_id) do
      nil -> nil
      pid -> Stream.cast_recv(pid, frame)
    end
    {:noreply, state}
  end

  def recv(%Frame.RstStream{}, state) do
    Logger.error("recv unstarted stream rst")
    {:noreply, state}
  end

  def recv(%Frame.Ping{ack: ack}, %{client: pid} = state) do
    resp = if ack, do: :pong, else: :ping
    send(pid, {resp, self()})
    {:noreply, state}
  end

  def recv(%Frame.PushPromise{} = frame, state) do
    {:ok, frame, new_dec} = Frame.Headers.decode(frame, state.decoder_state)
    case pid_for_stream(state.ref, frame.stream_id) do
      nil -> nil
      pid -> Stream.cast_recv(pid, frame)
    end
    {:noreply, %{state | decoder_state: new_dec}}
  end

  def recv(%Frame.Settings{ack: true}, state) do
    # Do nothing on ACK. Might change in the future.
    {:noreply, state}
  end
  def recv(%Frame.Settings{ack: false, settings: settings}, %{socket: socket,
                                                              settings: pid,
                                                              flow_control: flow,
                                                              decoder_state: decoder} = state) do

    ConnectionSettings.update(pid, settings)
    FlowControl.set_max_stream_count(flow, settings.max_concurrent_streams)
    Hpack.update_max_table_size(decoder, settings.max_header_list_size)

    settings_ack = Http2.build_frame(@settings, 0x1, 0x0, <<>>)
    :ssl.send(socket, settings_ack)

    {:noreply, state}
  end

  def recv(%Goaway{last_stream_id: id,
                   error_code: error,
                   debug_data: debug}, %{client: pid} = state) do
    log_goaway(error, id, debug)
    send pid, {:closed, self()}
    {:noreply, state}
  end

  def recv(%Frame.WindowUpdate{stream_id: _id, window_size_increment: inc}, state) do
    # IO.puts("--> Window Update, Stream ID: #{id}, Increment: #{inc} bytes")
    FlowControl.add_bytes(state.flow_control, inc)
    {:noreply, state}
  end

  def recv(%Frame.Continuation{} = frame, state) do
    {:ok, frame, new_dec} = Frame.Headers.decode(frame, state.decoder_state)
    case pid_for_stream(state.ref, frame.stream_id) do
      nil -> nil
      pid -> Stream.cast_recv(pid, frame)
    end
    {:noreply, %{state | decoder_state: new_dec}}
  end

  defp increment_stream_id(%{stream_id: stream_id} = state) do
    %{state | stream_id: stream_id + 2}
  end

  defp do_send_headers(headers, payload, %{ref: ref,
                                           overflow: overflow,
                                           flow_control: flow,
                                           settings: settings_pid} = state) do

    {:ok, settings} = Kadabra.ConnectionSettings.fetch(settings_pid)

    # TODO: Refactor this somewhere else
    if FlowControl.can_send?(flow) do
      stream = Stream.new(state)
      {:ok, pid} = Stream.start_link(stream)
      Registry.register(Registry.Kadabra, {ref, stream.id}, pid)

      :gen_statem.cast(pid, {:send_headers, headers, payload})

      headers = Stream.add_headers(headers, stream)

      {:ok, encoded} = Hpack.encode(stream.encoder, headers)
      headers_payload = :erlang.iolist_to_binary(encoded)

      h = Http2.build_frame(@headers, 0x4, stream.id, headers_payload)
      :ssl.send(stream.socket, h)
      # IO.puts("Sending, Stream ID: #{stream.id}")

      if payload do
        {:ok, settings} = Kadabra.ConnectionSettings.fetch(stream.settings)
        chunks = Stream.chunk(settings.max_frame_size, payload)
        Stream.send_chunks(stream.socket, stream.id, chunks)
      end

      FlowControl.increment_active_stream_count(flow)

      state
      |> increment_stream_id()
    else
      overflow = overflow ++ [{:send, headers, payload}]
      %{state | overflow: overflow}
    end
  end

  def log_goaway(code, id, bin) do
    error = Error.string(code)
    Logger.error "Got GOAWAY, #{error}, Last Stream: #{id}, Rest: #{bin}"
  end

  defp process_queue(%{overflow: []} = state), do: state
  defp process_queue(%{overflow: [{:send, headers, payload} | rest]} = state) do
    state = %{state | overflow: rest}
    state = do_send_headers(headers, payload, state)

    if FlowControl.can_send?(state.flow_control) do
      process_queue(state)
    else
      state
    end
  end

  def handle_info({:finished, response}, %{client: pid, flow_control: flow} = state) do
    send(pid, {:end_stream, response})
    # IO.puts(":: Finished stream_id: #{response.id} ::")

    FlowControl.decrement_active_stream_count(flow)

    state =
      state
      |> process_queue()
    {:noreply, state}
  end

  def handle_info({:push_promise, stream}, %{client: pid} = state) do
    send(pid, {:push_promise, stream})
    {:noreply, state}
  end

  def handle_info({:registered, stream_id, pid}, state) do
    Registry.register(Registry.Kadabra, {state.ref, stream_id}, pid)
    {:noreply, state}
  end

  def handle_info({:tcp, _socket, _bin}, state) do
    {:noreply, state}
  end

  def handle_info({:tcp_closed, _socket}, state) do
    maybe_reconnect(state)
  end

  def handle_info({:ssl, _socket, bin}, state) do
    do_recv_ssl(bin, state)
  end

  def handle_info({:ssl_closed, _socket}, state) do
    maybe_reconnect(state)
  end

  defp do_recv_ssl(bin, %{socket: socket} = state) do
    bin = state.buffer <> bin
    case parse_ssl(socket, bin, state) do
      {:error, bin} ->
        :ssl.setopts(socket, [{:active, :once}])
        {:noreply, %{state | buffer: bin}}
    end
  end

  def parse_ssl(socket, bin, state) do
    case Kadabra.Frame.new(bin) do
      {:ok, frame, rest} ->
        handle_response(frame, state)
        parse_ssl(socket, rest, state)
      {:error, bin} ->
        {:error, bin}
    end
  end

  def handle_response(frame, _state) when is_binary(frame) do
    Logger.info "Got binary: #{inspect(frame)}"
  end
  def handle_response(frame, state) do
    pid = pid_for_stream(state.ref, frame.stream_id) || self()

    case frame.type do
      @data ->
        data = Data.new(frame)
        if byte_size(data.data) > 0 do
          # IO.puts("<-- Window Update, #{byte_size(data.data)} bytes")
          window_update = Http2.build_frame(0x8, 0x0, 0x0, <<byte_size(data.data)::32>>)
          :ssl.send(state.socket, window_update)
        end
        Stream.cast_recv(pid, data)
      @headers ->
        Stream.cast_recv(pid, Headers.new(frame))
      @rst_stream ->
        rst = RstStream.new(frame)
        Stream.cast_recv(pid, rst)
      @settings ->
        handle_settings(frame, state)
      @push_promise ->
        open_promise_stream(frame, state)
      @ping ->
        GenServer.cast(self(), {:recv, Ping.new(frame)})
      @goaway ->
        GenServer.cast(self(), {:recv, Goaway.new(frame)})
      @window_update ->
        GenServer.cast(self(), {:recv, WindowUpdate.new(frame)})
      @continuation ->
        Stream.cast_recv(pid, Continuation.new(frame))
      _ ->
        Logger.info("Unknown frame: #{inspect(frame)}")
    end
  end

  def pid_for_stream(ref, stream_id) do
    case Registry.lookup(Registry.Kadabra, {ref, stream_id}) do
      [{_self, pid}] -> pid
      [] -> nil
    end
  end

  def handle_settings(frame, state) do
    case Frame.Settings.new(frame) do
      {:ok, settings_frame} ->
        recv(settings_frame, state)
      _else ->
        # TODO: handle bad settings
        :error
    end
  end

  def open_promise_stream(frame, state) do
    pp_frame = PushPromise.new(frame)

    {:ok, pid} =
      state
      |> Stream.new(pp_frame.stream_id)
      |> Stream.start_link

    Registry.register(Registry.Kadabra, {state.uri, pp_frame.stream_id}, pid)
    Stream.cast_recv(pid, pp_frame)
  end

  def maybe_reconnect(%{reconnect: false, client: pid} = state) do
    Logger.debug "Socket closed, not reopening, informing client"
    send(pid, {:closed, self()})
    {:noreply, reset_state(state, nil)}
  end

  def maybe_reconnect(%{reconnect: true, uri: uri, opts: opts, client: pid} = state) do
    case do_connect(uri, opts) do
      {:ok, socket} ->
        Logger.debug "Socket closed, reopened automatically"
        {:noreply, reset_state(state, socket)}
      {:error, error} ->
        Logger.error "Socket closed, reopening failed with #{error}"
        send(pid, :closed)
        {:stop, :normal, state}
    end
  end

  defp reset_state(state, socket) do
    {:ok, enc} = Hpack.start_link
    {:ok, dec} = Hpack.start_link
    %{state | encoder_state: enc, decoder_state: dec, socket: socket}
  end
end
