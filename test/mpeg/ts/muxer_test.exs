defmodule MPEG.TS.MuxerTest do
  use ExUnit.Case, async: true

  alias MPEG.TS.{Demuxer, Marshaler, Muxer, Packet, PAT, PMT, PSI}

  setup do
    {:ok, muxer: Muxer.new()}
  end

  test "Mux PAT table", %{muxer: muxer} do
    {%Packet{pid: 0, pusi: true, continuity_counter: 0, payload: raw_psi}, _muxer} =
      Muxer.mux_pat(muxer)

    assert {:ok, %PSI{table: %PAT{programs: %{1 => 0x1000}}}} = PSI.unmarshal(raw_psi, true)
  end

  test "Mux PMT table", %{muxer: muxer} do
    {%Packet{pid: 0x1000, pusi: true, continuity_counter: 0, payload: raw_psi}, muxer} =
      Muxer.mux_pmt(muxer)

    assert {:ok, %PSI{table: %PMT{pcr_pid: 0x1FFF, program_info: [], streams: %{}}}} =
             PSI.unmarshal(raw_psi, true)

    {pid1, muxer} = Muxer.add_elementary_stream(muxer, :H264_AVC, pcr?: true)
    {pid2, muxer} = Muxer.add_elementary_stream(muxer, :AAC_ADTS)

    assert pid1 == 0x100
    assert pid2 == 0x101

    {%Packet{pid: 0x1000, pusi: true, continuity_counter: 1, payload: raw_psi}, _muxer} =
      Muxer.mux_pmt(muxer)

    assert {:ok,
            %PSI{
              table: %PMT{
                pcr_pid: 0x100,
                program_info: [],
                streams: %{
                  0x100 => %{stream_type: :H264_AVC, stream_type_id: 27},
                  0x101 => %{stream_type: :AAC_ADTS, stream_type_id: 15}
                }
              }
            }} = PSI.unmarshal(raw_psi, true)
  end

  test "Mux PCR", %{muxer: muxer} do
    {pid, muxer} = Muxer.add_elementary_stream(muxer, :H264_AVC, pcr?: true)
    {%Packet{payload: <<>>, pcr: 100, pid: ^pid}, _muxer} = Muxer.mux_pcr(muxer, 100)
  end

  test "Mux sample", %{muxer: muxer} do
    {pid, muxer} = Muxer.add_elementary_stream(muxer, :H264_AVC, pcr?: true)

    sample_payload = :binary.copy(<<1>>, 1000)
    pts = 90000
    dts = 90000

    {packets, _muxer} = Muxer.mux_sample(muxer, pid, sample_payload, pts, dts: dts, sync?: true)

    assert length(packets) == 6
    assert %Packet{pusi: true, random_access_indicator: true, pid: ^pid} = hd(packets)

    for packet <- tl(packets) do
      assert packet.pid == pid
      refute packet.pusi
      refute packet.random_access_indicator
    end

    for {packet, idx} <- Enum.with_index(packets, 0) do
      assert packet.continuity_counter == rem(idx, 16)
    end
  end

  test "mux SCTE35", %{muxer: muxer} do
    {pid, muxer} =
      Muxer.add_elementary_stream(muxer, :SCTE_35_SPLICE, [
        program_info: [%{tag: 5, data: "CUEI"}],
        pid: 500
      ])

    table = Support.Factory.scte35()

    psi = %MPEG.TS.PSI{
      header: %{
        table_id: 0xFC,
        section_syntax_indicator: false
      },
      table: table
    }

    {packet, muxer} = Muxer.mux_psi(muxer, pid, psi)

    assert muxer.pmt == %MPEG.TS.PMT{
             pcr_pid: nil,
             program_info: [%{data: "CUEI", tag: 5}],
             streams: %{500 => %{stream_type: :SCTE_35_SPLICE, stream_type_id: 134}}
           }

    assert packet.payload != ""
  end

  test "Mux and demux", %{muxer: muxer} do
    {video_pid, muxer} =
      Muxer.add_elementary_stream(muxer, :H264_AVC, pcr?: true)

    {audio_pid, muxer} = Muxer.add_elementary_stream(muxer, :AAC_ADTS)

    {pat, muxer} = Muxer.mux_pat(muxer)
    {pmt, muxer} = Muxer.mux_pmt(muxer)

    video_sample = :binary.copy(<<1>>, 1000)
    audio_sample = :binary.copy(<<2>>, 500)

    {video_packets, muxer} =
      Muxer.mux_sample(muxer, video_pid, video_sample, 0, sync?: true, send_pcr?: true)

    {audio_packets, muxer} = Muxer.mux_sample(muxer, audio_pid, audio_sample, 0, sync?: true)

    packets = [pat, pmt] ++ video_packets ++ audio_packets
    {video_packets, muxer} = Muxer.mux_sample(muxer, video_pid, video_sample, 18000)
    {audio_packets, _muxer} = Muxer.mux_sample(muxer, audio_pid, audio_sample, 9000, sync?: true)

    packets = packets ++ video_packets ++ audio_packets
    data = Marshaler.marshal(packets)

    units =
      data
      |> Stream.map(fn x -> IO.iodata_to_binary(x) end)
      |> Demuxer.stream!(strict?: true)
      |> Enum.into([])

    pmt =
      units
      |> Demuxer.filter(4096)
      |> List.first()

    assert %PMT{
             pcr_pid: ^video_pid,
             program_info: [],
             streams: %{
               ^video_pid => %{stream_type: :H264_AVC, stream_type_id: 27},
               ^audio_pid => %{stream_type: :AAC_ADTS, stream_type_id: 15}
             }
           } = pmt.table

    assert [video_sample1, video_sample2] = Demuxer.filter(units, video_pid)
    assert [audio_sample1, audio_sample2] = Demuxer.filter(units, audio_pid)

    for sample <- [video_sample1, video_sample2] do
      assert sample.data == video_sample
      assert sample.pts == sample.dts
      assert sample.stream_id == 0xE0
    end

    for sample <- [audio_sample1, audio_sample2] do
      assert sample.data == audio_sample
      assert sample.pts == sample.dts
      assert sample.stream_id == 0xC0
    end
  end
end
