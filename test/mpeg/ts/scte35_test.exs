defmodule MPEG.TS.SCTE35Test do
  use ExUnit.Case

  alias MPEG.TS.SCTE35
  alias Support.Factory

  describe "SCTE35 unmarshal" do
    test "unmarshals valid SCTE-35 splice insert command" do
      {:ok, scte35} = SCTE35.unmarshal(Factory.scte35(), true)

      # Verify basic SCTE-35 structure
      assert %SCTE35{
               protocol_version: 0x0,
               encrypted_packet: false,
               encryption_algorithm: 0x0,
               pts_adjustment: 0,
               cw_index: 0x0,
               tier: 0xFFF,
               splice_command_type: :splice_insert,
               splice_command: %MPEG.TS.SCTE35.SpliceInsert{
                 event_id: 1_073_743_242,
                 cancel_indicator: 0,
                 out_of_network_indicator: 1,
                 event_id_compliance_flag: 1,
                 splice_time: nil,
                 break_duration: %{auto_return: 0, duration: 1_547_665_413},
                 unique_program_id: 24064,
                 avail_num: 0,
                 avails_expected: 0
               },
               splice_descriptors: []
             } = scte35
    end

    test "returns error for malformed data" do
      malformed_data = <<0xFC, 0x80, 0x10, 0xFF, 0xFF>>
      assert {:error, _reason} = SCTE35.unmarshal(malformed_data, true)
    end
  end
end
