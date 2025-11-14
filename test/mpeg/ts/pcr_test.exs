defmodule MPEG.TS.PCRTest do
  use ExUnit.Case, async: true

  alias MPEG.TS.{Marshaler, Muxer, Packet}

  describe "PCR encoding and decoding" do
    test "PCR round-trip with 1 second timestamp" do
      # 1 second in nanoseconds
      pcr_ns = 1_000_000_000
      payload = <<1, 2, 3>>

      packet =
        Packet.new(payload,
          pid: 0x100,
          continuity_counter: 0,
          pcr: pcr_ns
        )

      # Serialize and parse back
      binary = Marshaler.marshal(packet) |> IO.iodata_to_binary()
      assert {:ok, parsed} = Packet.parse(binary)

      # PCR should match original value
      assert parsed.pcr == pcr_ns
    end

    test "PCR round-trip with various timestamps" do
      test_cases = [
        # nanoseconds, description
        {0, "zero"},
        {1_000_000, "1 millisecond"},
        {11_111_111, "11.111111 ms (~1000 @ 90kHz)"},
        {1_000_000_000, "1 second"},
        {5_500_000_000, "5.5 seconds"},
        {60_000_000_000, "1 minute"},
        {3_600_000_000_000, "1 hour"}
      ]

      for {pcr_ns, description} <- test_cases do
        payload = :binary.copy(<<0x01>>, 176)

        packet =
          Packet.new(payload,
            pid: 0x100,
            continuity_counter: 5,
            random_access_indicator: true,
            pusi: true,
            pcr: pcr_ns
          )

        binary = Marshaler.marshal(packet) |> IO.iodata_to_binary()
        assert {:ok, parsed} = Packet.parse(binary)

        assert parsed.pcr == pcr_ns,
               "PCR mismatch for #{description}: expected #{pcr_ns}, got #{parsed.pcr}"
      end
    end

    test "PCR base and extension values are correct" do
      # Test a timestamp that should have both base and extension
      # 1 second = 1,000,000,000 ns = 27,000,000 ticks @ 27MHz
      # 27,000,000 / 300 = 90,000 base, 0 extension
      pcr_ns = 1_000_000_000

      packet =
        Packet.new(<<>>,
          pid: 0x100,
          continuity_counter: 0,
          pcr: pcr_ns
        )

      binary = Marshaler.marshal(packet) |> IO.iodata_to_binary()

      # Extract the PCR bytes from the adaptation field
      # Packet structure: sync(1) + header(3) + adaptation_length(1) + adaptation_flags(1) + PCR(6)
      <<_sync::8, _header::24, _adapt_len::8, _flags::8, base::33, reserved::6, extension::9,
        _rest::binary>> = binary

      # Verify reserved bits are all 1s
      assert reserved == 0b111111

      # Verify the combined PCR value in 27MHz units
      pcr_27mhz = base * 300 + extension
      expected_27mhz = round(pcr_ns * 27_000_000 / 1.0e9)
      assert pcr_27mhz == expected_27mhz
    end

    test "PCR with fractional 27MHz ticks" do
      # Choose a timestamp that will have a non-zero extension
      # Example: 11.111111111 ms = 11,111,111.111 ns
      # At 27MHz: 300,000 ticks exactly
      # base = 1000, extension = 0
      #
      # Let's use 11,111,148 ns which should give us a non-zero extension
      # 11,111,148 * 27,000,000 / 1e9 ≈ 300,001.0 ticks
      # base = 1000, extension = 1
      pcr_ns = 11_111_148

      packet = Packet.new(<<>>, pid: 0x100, continuity_counter: 0, pcr: pcr_ns)

      binary = Marshaler.marshal(packet) |> IO.iodata_to_binary()
      # Skip: sync(1) + header(3) + adapt_len(1) + adapt_flags(1) = 6 bytes = 48 bits
      <<_::48, base::33, _reserved::6, extension::9, _::binary>> = binary

      # Should have non-zero extension for this timestamp
      pcr_27mhz_expected = round(pcr_ns * 27_000_000 / 1.0e9)
      pcr_27mhz_actual = base * 300 + extension

      assert pcr_27mhz_actual == pcr_27mhz_expected

      # Parse back and verify
      {:ok, parsed} = Packet.parse(binary)
      # Allow for small rounding error (within 1 nanosecond per extension tick ≈ 37ns)
      assert abs(parsed.pcr - pcr_ns) <= 37
    end
  end

  describe "Muxer PCR behavior" do
    test "mux_pcr creates packet with correct PCR" do
      muxer = Muxer.new()
      {_pid, muxer} = Muxer.add_elementary_stream(muxer, :H264_AVC, pcr?: true)

      pcr_ns = 1_234_567_890
      {packet, _muxer} = Muxer.mux_pcr(muxer, pcr_ns)

      # PCR should match input
      assert packet.pcr == pcr_ns

      # Verify round-trip (allow for small rounding error due to clock conversions)
      binary = Marshaler.marshal(packet) |> IO.iodata_to_binary()
      {:ok, parsed} = Packet.parse(binary)
      # PCR at 27MHz has precision of ~37ns, allow ±1ns for rounding
      assert abs(parsed.pcr - pcr_ns) <= 1
    end

    test "mux_sample with send_pcr? uses PTS as PCR" do
      muxer = Muxer.new()
      {pid, muxer} = Muxer.add_elementary_stream(muxer, :H264_AVC, pcr?: true)

      pts_ns = 2_000_000_000
      payload = <<1, 2, 3>>

      {packets, _muxer} = Muxer.mux_sample(muxer, pid, payload, pts_ns, send_pcr?: true)

      first_packet = hd(packets)

      # PCR should equal PTS
      assert first_packet.pcr == pts_ns

      # Verify round-trip
      binary = Marshaler.marshal(first_packet) |> IO.iodata_to_binary()
      {:ok, parsed} = Packet.parse(binary)
      assert parsed.pcr == pts_ns
    end

    test "mux_sample with send_pcr? uses DTS when available" do
      muxer = Muxer.new()
      {pid, muxer} = Muxer.add_elementary_stream(muxer, :H264_AVC, pcr?: true)

      pts_ns = 3_000_000_000
      dts_ns = 2_500_000_000
      payload = <<1, 2, 3>>

      {packets, _muxer} =
        Muxer.mux_sample(muxer, pid, payload, pts_ns, dts: dts_ns, send_pcr?: true)

      first_packet = hd(packets)

      # PCR should equal DTS (not PTS)
      assert first_packet.pcr == dts_ns

      # Verify round-trip
      binary = Marshaler.marshal(first_packet) |> IO.iodata_to_binary()
      {:ok, parsed} = Packet.parse(binary)
      assert parsed.pcr == dts_ns
    end

    test "mux_sample without send_pcr? has no PCR" do
      muxer = Muxer.new()
      {pid, muxer} = Muxer.add_elementary_stream(muxer, :H264_AVC, pcr?: true)

      pts_ns = 1_000_000_000
      payload = <<1, 2, 3>>

      {packets, _muxer} = Muxer.mux_sample(muxer, pid, payload, pts_ns, send_pcr?: false)

      first_packet = hd(packets)

      # PCR should be nil
      assert first_packet.pcr == nil
    end

    test "PCR values are consistent with PTS/DTS in real mux/demux" do
      alias MPEG.TS.{Demuxer, PES}

      muxer = Muxer.new()
      {video_pid, muxer} = Muxer.add_elementary_stream(muxer, :H264_AVC, pcr?: true)

      {pat, muxer} = Muxer.mux_pat(muxer)
      {pmt, muxer} = Muxer.mux_pmt(muxer)

      video_sample = :binary.copy(<<1>>, 100)
      pts_ns = 1_500_000_000

      {video_packets, _muxer} =
        Muxer.mux_sample(muxer, video_pid, video_sample, pts_ns, sync?: true, send_pcr?: true)

      packets = [pat, pmt] ++ video_packets
      data = Marshaler.marshal(packets)

      # Verify the first video packet has correct PCR
      first_video_packet = hd(video_packets)
      assert first_video_packet.pcr == pts_ns

      # Demux and verify timestamps match
      units =
        data
        |> Stream.map(&IO.iodata_to_binary/1)
        |> Demuxer.stream!(strict?: true)
        |> Enum.into([])

      video_samples = Demuxer.filter(units, video_pid)
      assert [%PES{pts: ^pts_ns}] = video_samples
    end
  end
end
