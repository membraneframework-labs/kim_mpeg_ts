defmodule MPEG.TS.DemuxerTest do
  use ExUnit.Case

  alias MPEG.TS.Demuxer

  @broken "test/data/broken.ts"
  @avsync "test/data/avsync.ts"

  defp demux_file!(path, opts \\ []) do
    path
    |> Demuxer.stream_file!(opts)
    |> Enum.into([])
  end

  test "finds PMT table" do
    units = demux_file!(@avsync)
    pmt = Enum.find(units, fn %{payload: %mod{}} -> mod == MPEG.TS.PMT end)

    assert %MPEG.TS.PMT{
             pcr_pid: 256,
             program_info: [],
             streams: %{
               256 => %{stream_type: :H264_AVC, stream_type_id: 27},
               257 => %{stream_type: :AAC_ADTS, stream_type_id: 15}
             }
           } == pmt.payload
  end

  test "demuxes PES stream" do
    units = demux_file!(@avsync)

    count =
      units
      |> Enum.filter(fn %{payload: %mod{}} -> mod == MPEG.TS.PES end)
      |> length()

    assert count > 0
  end

  test "works with partial data" do
    one_shot = demux_file!(@avsync)

    chunked =
      @avsync
      |> File.open!([:binary])
      |> IO.binstream(512)
      |> Demuxer.stream!()
      |> Enum.into([])

    assert length(one_shot) > 0
    assert length(chunked) == length(List.flatten(one_shot))

    chunked
    |> Enum.zip(one_shot)
    |> Enum.with_index()
    |> Enum.each(fn {{left, right}, index} ->
      assert left == right,
             "packet #{index}/#{length(chunked) - 1}:\n\tone_shot=#{inspect(right, binaries: :as_strings)}\n\tchunked=#{inspect(left, binaries: :as_strings)}"
    end)
  end

  test "raises on corrupted packets" do
    assert_raise MPEG.TS.StreamAggregator.Error, fn ->
      _ = demux_file!(@broken, strict?: true)
    end
  end
end
