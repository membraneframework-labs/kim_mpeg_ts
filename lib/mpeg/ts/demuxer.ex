defmodule MPEG.TS.Demuxer do
  @moduledoc """
  Responsible for demultiplexing a stream of MPEG.TS.Packet into the elemetary
  streams listed in the stream's Program Map Table. Does not yet handle PAT.
  """
  alias MPEG.TS.Packet
  alias MPEG.TS.{PMT, PAT, PES, PSI}
  alias MPEG.TS.StreamAggregator

  defmodule Error do
    defexception [:message]

    defp format_data(nil), do: "<N/A>"

    defp format_data(data) do
      data
      |> :binary.bin_to_list()
      |> Enum.take(4)
      |> :binary.list_to_bin()
      |> :binary.encode_hex()
    end

    @impl true
    def exception(%{reason: reason, data: data}) do
      message = "Unrecoverable parse error: #{inspect(reason)} (#{format_data(data)})"
      %__MODULE__{message: message}
    end
  end

  defmodule Container do
    alias MPEG.TS.{PES, PSI}

    @type payload_t :: PES.t() | PSI.t()
    @type t :: %__MODULE__{pid: MPEG.TS.Packet.pid_t(), payload: payload_t}
    defstruct [:pid, :payload]
    def new(payload, pid) when is_struct(payload), do: %__MODULE__{pid: pid, payload: payload}
  end

  require Logger

  @type t :: %__MODULE__{
          # When enabled, raises on invalid packets.
          strict?: boolean(),
          pending: binary(),
          # Each PID that requires ES re-assemblement get's a queue here,
          # from which we extrac complete buffers.
          stream_aggregators: %{Packet.pid_t() => StreamAggregator.t()},
          # Each stream that appears in any PMT is added here as they are the
          # streams that have been recognised. Each of these streams has its own
          # stream_aggregators, if needed (i.e. they'r category is either audio or video).
          streams: %{Packet.pid_t() => PMT.stream_t()},
          # Reverse map of the PAT table, used for fast lookup
          pids_with_pmt: %{Packet.pid_t() => PAT.program_id_t()}
        }

  defstruct pending: <<>>,
            pids_with_pmt: %{},
            stream_aggregators: %{},
            streams: %{},
            strict?: false

  @spec new() :: t()
  def new(opts \\ []) do
    opts = Keyword.validate!(opts, strict?: false)
    %__MODULE__{strict?: opts[:strict?]}
  end

  def filter(units, pid) do
    units
    |> Stream.filter(fn x -> x.pid == pid end)
    |> Enum.map(fn x -> x.payload end)
  end

  def available_streams(state), do: state.streams

  def stream!(stream, opts \\ []) do
    Stream.transform(
      stream,
      fn -> new(opts) end,
      fn data, d -> demux(d, data) end,
      fn d -> flush(d) end,
      fn _ -> :ok end
    )
  end

  def stream_file!(path, opts \\ []) do
    path
    |> File.stream!(188, [:binary])
    |> stream!(opts)
  end

  @spec demux(t(), binary()) :: {[Container.t()], t()}
  def demux(state, data) do
    {packets, state} =
      get_and_update_in(state, [Access.key!(:pending)], fn pending ->
        try do
          parse_packets(pending <> data)
        rescue
          e in Error ->
            unless state.strict? do
              Logger.warning("Parse error: #{inspect(e.message)}")
              {[], state}
            else
              reraise e, __STACKTRACE__
            end
        end
      end)

    demux_packets(state, packets, [])
  end

  @spec flush(t()) :: {[Container.t()], t()}
  def flush(state) do
    state
    |> put_in([Access.key!(:pending)], <<>>)
    |> get_and_update_in([Access.key!(:stream_aggregators)], fn map ->
      map
      |> Enum.flat_map_reduce(map, fn {pid, aggregator}, map ->
        {pes, aggregator} =
          try do
            StreamAggregator.flush(aggregator)
          rescue
            e in StreamAggregator.Error ->
              unless state.strict? do
                Logger.warning("PID #{pid} error: #{e.message}")
                {[], StreamAggregator.new()}
              else
                reraise e, __STACKTRACE__
              end
          end

        pes = Enum.map(pes, fn x -> Container.new(x, pid) end)
        {pes, put_in(map, [pid], aggregator)}
      end)
    end)
  end

  defp demux_packets(state, [], acc) do
    {Enum.reverse(acc), state}
  end

  defp demux_packets(state, [pkt | pkts], acc) when pkt.pid_class == :null_packet do
    # We're completely ignoring stuffing bytes.
    demux_packets(state, pkts, acc)
  end

  defp demux_packets(state, [pkt | pkts], acc)
       when is_map_key(state.stream_aggregators, pkt.pid) do
    # This is a PES packet.
    {pes, state} =
      get_and_update_in(state, [Access.key!(:stream_aggregators), pkt.pid], fn queue ->
        try do
          StreamAggregator.put_and_get(queue, pkt)
        rescue
          e in StreamAggregator.Error ->
            unless state.strict? do
              Logger.warning("PID #{pkt.pid} error: #{e.message}")
              {[], StreamAggregator.new()}
            else
              reraise e, __STACKTRACE__
            end
        end
      end)

    acc = Enum.reduce(pes, acc, fn x, acc -> [Container.new(x, pkt.pid) | acc] end)
    demux_packets(state, pkts, acc)
  end

  defp demux_packets(state, [pkt | pkts], acc)
       when pkt.pid_class in [:psi, :pat] or is_map_key(state.pids_with_pmt, pkt.pid) do
    with {:ok, psi} <- PSI.unmarshal(pkt.payload, pkt.pusi) do
      state =
        cond do
          is_map_key(state.pids_with_pmt, pkt.pid) and psi.table_type == :pmt ->
            handle_pmt(psi.table, state)

          pkt.pid_class == :pat and psi.table_type == :pat ->
            handle_pat(psi.table, state)

          true ->
            # We just forward the PSI packet as is.
            state
        end

      demux_packets(state, pkts, [Container.new(psi, pkt.pid) | acc])
    else
      {:error, reason} ->
        if state.strict? do
          raise Error, %{reason: reason, data: pkt.payload}
        else
          # Logger.warning("PID #{pkt.pid}: error: #{inspect(reason)}")
          demux_packets(state, pkts, acc)
        end
    end
  end

  defp demux_packets(state, [pkt | pkts], acc) do
    # This packet does not belong to any PES stream we know -- it might be
    # an unknown stream (we did not receive PMTs yet) or a PSI stream. 
    Logger.warning("Unexpected packet received: #{inspect(pkt)}")
    demux_packets(state, pkts, acc)
  end

  defp handle_pat(pat, state) do
    state
    |> update_in([Access.key!(:pids_with_pmt)], fn old ->
      pat.programs
      |> Enum.map(fn {k, v} -> {v, k} end)
      |> Map.new()
      |> then(fn x -> Map.merge(old, x) end)
    end)
  end

  defp handle_pmt(pmt, state) do
    state
    |> update_in([Access.key!(:streams)], &Map.merge(&1, pmt.streams))
    |> then(fn state ->
      # Each stream that contains a PES stream should have its aggregator.
      state.streams
      |> Enum.filter(fn {_pid, stream} ->
        PMT.get_stream_category(stream.stream_type) in [:audio, :video]
      end)
      |> Enum.reduce(state, fn {pid, _stream}, state ->
        update_in(state, [Access.key!(:stream_aggregators), pid], fn
          nil -> StreamAggregator.new()
          queue -> queue
        end)
      end)
    end)
  end

  defp parse_packets(buffer) do
    {ok, err} =
      buffer
      |> Packet.parse_many()
      |> Enum.split_with(fn tuple -> elem(tuple, 0) == :ok end)

    # fail fast in case a critical error is encountered. If data becomes
    # mis-aligned this module should be responsible for fixing it.
    critical_err =
      Enum.find(err, fn
        {:error, :invalid_packet, _} -> true
        {:error, :invalid_data, _} -> true
        _ -> false
      end)

    if critical_err != nil do
      {:error, reason, data} = critical_err
      raise Error, %{reason: reason, data: data}
    end

    to_buffer =
      err
      |> Enum.filter(fn
        {:error, :not_enough_data, _} -> true
        _ -> false
      end)
      |> Enum.map(fn {_, _, data} -> data end)
      |> Enum.reduce(<<>>, fn x, acc -> acc <> x end)

    ok = Enum.map(ok, fn {:ok, x} -> x end)

    {ok, to_buffer}
  end
end
