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
               pts_adjustment: 0x0,
               cw_index: 0x0,
               tier: 0xFFF,
               splice_command_length: 0xF,
               splice_command_type: :splice_insert
             } = scte35

      # Verify splice insert command details
      assert scte35.splice_event_id == 0x4000058A
      assert scte35.splice_event_cancel_indicator == false
      assert scte35.out_of_network_indicator == true
      assert scte35.program_splice_flag == true
      assert scte35.duration_flag == true
      assert scte35.splice_immediate_flag == true
      assert scte35.splice_time == nil

      # Verify break duration
      assert scte35.auto_return == false
      assert scte35.duration == 0x25C3F80

      # Verify additional fields
      assert scte35.unique_program_id == 0x55E
      assert scte35.avail_num == 0x0
      assert scte35.avails_expected == 0x0
      assert scte35.descriptor_loop_length == 0x0
      assert scte35.splice_descriptors == []
    end

    test "returns error for malformed data" do
      malformed_data = <<0xFC, 0x80, 0x10, 0xFF, 0xFF>>
      assert {:error, _reason} = SCTE35.unmarshal(malformed_data, true)
    end
  end
end
