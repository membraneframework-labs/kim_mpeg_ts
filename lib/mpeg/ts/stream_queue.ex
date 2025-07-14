defmodule MPEG.TS.StreamQueue do
  @moduledoc """
  This module's responsibility is to reduce a stream of TS packets packets into
  an ordered queue of PES ones. Accepts only packets belonging to the same
  elementary stream. This module is in support of the demuxer and acts as a
  PartialPES depayloader.
  """

  alias MPEG.TS.PartialPES
  alias MPEG.TS.PES

  require Logger

  @derive Inspect
  defstruct [:pid, :acc, :ready]

  @type t :: %__MODULE__{
          pid: pid(),
          acc: :queue.queue(),
          ready: :queue.queue()
        }

  def new(pid) do
    %__MODULE__{
      pid: pid,
      acc: :queue.new(),
      ready: :queue.new()
    }
  end

  def push_es_packets(state, packets) do
    {ready, acc} =
      Enum.reduce(packets, {state.ready, state.acc}, fn packet, {ready, acc} ->
        unit = unmarshal_partial_pes!(packet)

        cond do
          packet.pusi ->
            ready =
              acc
              |> :queue.to_list()
              |> depayload()
              |> Enum.reduce(ready, fn pes, ready ->
                :queue.in(pes, ready)
              end)

            {ready, :queue.from_list([unit])}

          not :queue.is_empty(acc) ->
            {ready, :queue.in(unit, acc)}

          true ->
            Logger.warning("Invalid PES, not a pusi. Skipping.")
            {ready, acc}
        end
      end)

    state
    |> put_in([Access.key!(:acc)], acc)
    |> put_in([Access.key!(:ready)], ready)
  end

  def end_of_stream(state = %__MODULE__{acc: acc, ready: ready}) do
    ready =
      acc
      |> :queue.to_list()
      |> depayload()
      |> Enum.reduce(ready, fn pes, ready ->
        :queue.in(pes, ready)
      end)

    %__MODULE__{state | acc: :queue.new(), ready: ready}
  end

  def take(state = %__MODULE__{ready: queue}, amount) do
    {items, queue} = take_from_queue(queue, amount, [])
    {items, %__MODULE__{state | ready: queue}}
  end

  defp take_from_queue(queue, 0, items) do
    {Enum.reverse(items), queue}
  end

  defp take_from_queue(queue, n, items) do
    case :queue.out(queue) do
      {:empty, queue} ->
        take_from_queue(queue, 0, items)

      {{:value, item}, queue} ->
        take_from_queue(queue, n - 1, [item | items])
    end
  end

  defp depayload([]) do
    []
  end

  defp depayload(packets = [leader | _]) do
    stream_ids =
      packets
      |> Enum.map(fn x -> x.stream_id end)
      |> Enum.uniq()
      |> Enum.reject(&is_nil/1)

    payload =
      packets
      |> Enum.map(fn x -> x.data end)
      |> Enum.join(<<>>)

    payload_size = byte_size(payload)

    payload =
      cond do
        length(stream_ids) != 1 ->
          Logger.warning(
            "The collected partial PES contains an invalid set of stream_ids (#{inspect(stream_ids)}). Skipping"
          )

          nil

        leader.length == 0 ->
          # TODO: trim trailing stuffing bits? Seems to make no difference and its a
          # quite expensive process.
          payload

        payload_size > leader.length ->
          <<payload::binary-size(leader.length)-unit(8), _rest::binary>> = payload
          payload

        payload_size == leader.length ->
          payload

        true ->
          Logger.warning(
            "Invalid PES, size mismatch (have=#{payload_size}, want=#{leader.length}). Skipping."
          )

          nil
      end

    if is_nil(payload) do
      []
    else
      List.wrap(%PES{
        data: payload,
        stream_id: leader.stream_id,
        pts: leader.pts,
        dts: leader.dts,
        is_aligned: leader.is_aligned,
        discontinuity: leader.discontinuity
      })
    end
  end

  defp unmarshal_partial_pes!(packet) do
    case PartialPES.unmarshal(packet.payload, packet.pusi) do
      {:ok, pes} ->
        %{pes | discontinuity: packet.discontinuity}

      {:error, reason} ->
        raise ArgumentError,
              "MPEG-TS could not parse Partial PES packet: #{inspect(reason)}"
    end
  end
end
