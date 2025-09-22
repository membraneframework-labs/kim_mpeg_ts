defmodule MPEG.TS.Demuxer do
  @moduledoc """
  Responsible for demultiplexing a stream of MPEG.TS.Packet into the elemetary
  streams listed in the stream's Program Map Table. Does not yet handle PAT.
  """
  alias MPEG.TS.Packet
  alias MPEG.TS.PMT
  alias MPEG.TS.PAT
  alias MPEG.TS.PES
  alias MPEG.TS.PSI
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

  require Logger

  @type t :: %__MODULE__{
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

  defstruct pending: <<>>, pids_with_pmt: %{}, stream_aggregators: %{}, streams: %{}

  @spec new() :: t()
  def new(), do: %__MODULE__{}

  @type unit :: PES.t() | PMT.t() | PAT.t() | PSI.t()
  @spec demux(t(), iodata()) :: {[unit()], t()}
  def demux(state, data) do
    {packets, state} =
      get_and_update_in(state, [:pending], fn pending ->
        parse_packets(pending <> data)
      end)

    demux_packets(state, packets, [])
  end

  defp demux_packets(state, [], acc) do
    {Enum.reverse(acc), state}
  end

  defp demux_packets(state = %{pat: nil}, packets, acc) do
    # Until we find a PAT table we don't know which PID's contain what.
    {pat_pkt, rest} =
      packets
      |> Enum.drop_while(fn x -> x.pid_class == :pat and x.pusi end)
      |> List.first()

    {pat, state} = handle_pat(pat_pkt, state)
    demux_packets(state, rest, [pat | acc])
  end

  defp demux_packets(state, [pkt | pkts], acc) when is_map_key(state.pids_with_pmt, pkt.pid) do
    # This packet carries a PMT table.
    with {:ok, pmt} <- PMT.unmarshal(pkt.payload, pkt.pusi) do
      state =
        state
        |> update_in([Access.key!(:streams)], &Map.merge(&1, pmt.streams))
        |> then(fn state ->
          # Ensure that each PMT stream that we have has a stream queue associated with it.
          state.streams
          |> Enum.reduce(state, fn {_pid, stream}, state ->
            update_in(state, [Access.key!(:stream_aggregators)], fn
              nil ->
                if PMT.get_stream_category(stream.stream_type) in [:audio, :video] do
                  StreamAggregator.new()
                end

              queue ->
                queue
            end)
          end)
        end)

      demux_packets(state, pkts, [pmt | acc])
    else
      {:error, reason} -> raise Error, %{reason: reason, data: pkt.payload}
    end
  end

  defp demux_packets(state, [pkt | pkts], acc) when is_map_key(state.streams, pkt.pid) do
    # This is a PES packet.
    {pes, state} =
      get_and_update_in(state, [:stream_aggregators, pkt.pid], fn queue ->
        StreamAggregator.put_and_get(queue, pkt)
      end)

    acc = Enum.reduce(pes, acc, fn x, acc -> [x | acc] end)
    demux_packets(state, pkts, acc)
  end

  defp demux_packets(_state, [pkt | _pkts], _acc) do
    # This packet does not belong to any PES stream we know
    IO.inspect(pkt, label: "UNIMPLEMNTED")
    raise ArgumentError, "not implemented"
  end

  defp handle_pat(pkt, state) do
    with {:ok, pat} <- PAT.unmarshal(pkt.payload, pkt.pusi) do
      state =
        state
        |> put_in([Access.key!(:pat)], pat)
        |> update_in([Access.key!(:pids_with_pmt)], fn old ->
          pat.programs
          |> Enum.map(fn {k, v} -> {v, k} end)
          |> Map.new()
          |> then(fn x -> Map.merge(old, x) end)
        end)

      {pat, state}
    else
      {:error, reason} -> raise Error, %{reason: reason, data: pkt.payload}
    end
  end

  def flush(state) do
    pkts =
      state.stream_aggregators
      |> Enum.flat_map(fn aggregator ->
        {pes, _} = StreamAggregator.flush(aggregator)
        pes
      end)

    {pkts, new()}
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
