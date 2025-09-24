defmodule MPEG.TS.SCTE35 do
  @behaviour MPEG.TS.Unmarshaler

  @moduledoc """
  SCTE-35 Digital Program Insertion Cueing Message.

  Handles parsing of SCTE-35 splice information tables used for
  ad insertion and program signaling in MPEG-TS streams.
  """

  defmodule SpliceInsert do
    @behaviour MPEG.TS.Unmarshaler
    defstruct [
      :event_id,
      :cancel_indicator,
      :out_of_network_indicator,
      :event_id_compliance_flag,
      :splice_time,
      :break_duration,
      :unique_program_id,
      :avail_num,
      :avails_expected
    ]

    @impl true
    def unmarshal(<<event_id::32, cancel_indicator::1, _reserved::7, rest::binary>>, _start_unit) do
      cmd = %__MODULE__{
        event_id: event_id,
        cancel_indicator: cancel_indicator
      }

      cmd = parse_event_cancel_section(cmd, rest)
      {:ok, cmd}
    end

    def unmarshal(_, _), do: {:error, :invalid_splice_insert}

    defp parse_event_cancel_section(
           cmd = %{cancel_indicator: 0},
           <<
             out_of_network_indicator::1,
             1::1,
             break_duration_flag::1,
             splice_immediate_flag::1,
             event_id_compliance_flag::1,
             _reserved::3,
             rest::binary
           >>
         ) do
      {splice_time, rest} = parse_splice_time(splice_immediate_flag, rest)
      {break_duration, rest} = parse_break_duration(break_duration_flag, rest)
      <<unique_program_id::16, _rest::binary>> = rest

      cmd
      |> put_in([Access.key!(:out_of_network_indicator)], out_of_network_indicator)
      |> put_in([Access.key!(:event_id_compliance_flag)], event_id_compliance_flag)
      |> put_in([Access.key!(:splice_time)], splice_time)
      |> put_in([Access.key!(:break_duration)], break_duration)
      |> put_in([Access.key!(:unique_program_id)], unique_program_id)
      # TODO: notice that avails should appear in the 2 bytes of rest, but we found
      # markers w/o them. It does not seem critical, hence we're skipping them.
      |> put_in([Access.key!(:avail_num)], 0)
      |> put_in([Access.key!(:avails_expected)], 0)
    end

    defp parse_event_cancel_section(cmd, _), do: cmd

    defp parse_splice_time(0, <<1::1, _reserved::6, pts_time::33, rest::binary>>) do
      {%{pts: pts_time}, rest}
    end

    defp parse_splice_time(1, <<0::1, _reserved::7, rest::binary>>) do
      {nil, rest}
    end

    defp parse_break_duration(1, <<auto_return::1, _reserved::6, duration::33, rest::binary>>) do
      {%{auto_return: auto_return, duration: duration}, rest}
    end

    defp parse_break_duration(0, rest), do: {nil, rest}
  end

  @type splice_command_type_t ::
          :splice_null
          | :splice_schedule
          | :splice_insert
          | :time_signal
          | :bandwidth_reservation
          | :private_command

  defstruct [
    # SCTE-35 header fields
    :protocol_version,
    :encrypted_packet,
    :encryption_algorithm,
    :pts_adjustment,
    :cw_index,
    :tier,
    :splice_command_type,
    :splice_command,
    :splice_descriptors,
    :e_crc32
  ]

  @type t :: %__MODULE__{
          protocol_version: 0..255,
          encrypted_packet: boolean(),
          encryption_algorithm: 0..63,
          pts_adjustment: integer(),
          cw_index: 0..255,
          tier: 0..0xFFF,
          splice_command_type: splice_command_type_t(),
          splice_command: struct(),
          splice_descriptors: list(),
          e_crc32: binary()
        }

  @impl true
  def unmarshal(data, true) do
    unmarshal_table(data)
  end

  def unmarshal(_data, _is_unit_start) do
    {:error, :invalid_data}
  end

  @spec unmarshal_table(binary()) :: {:ok, t()} | {:error, :invalid_data}
  def unmarshal_table(<<
        protocol_version::8,
        encrypted_packet_flag::1,
        encryption_algorithm::6,
        pts_adjustment::33,
        cw_index::8,
        tier::12,
        splice_command_length::12,
        splice_info_section::binary-size(splice_command_length),
        descriptor_loop_length::16,
        _descriptor_loop::binary-size(descriptor_loop_length),
        _rest::binary
      >>) do
    with {:ok, {command_type, command}} <- unmarshal_splice_info_section(splice_info_section) do
      {:ok,
       %__MODULE__{
         protocol_version: protocol_version,
         encrypted_packet: encrypted_packet_flag == 1,
         encryption_algorithm: encryption_algorithm,
         pts_adjustment: parse_pts_adjustment(pts_adjustment),
         cw_index: cw_index,
         tier: tier,
         splice_command_type: command_type,
         splice_command: command,
         # TODO: we're not parsing the descriptors!
         splice_descriptors: [],
         e_crc32: <<>>
       }}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  def unmarshal_table(_), do: {:error, :invalid_data}

  defp parse_pts_adjustment(base), do: base * 300

  defp parse_splice_command_type(0x00), do: :splice_null
  defp parse_splice_command_type(0x04), do: :splice_schedule
  defp parse_splice_command_type(0x05), do: :splice_insert
  defp parse_splice_command_type(0x06), do: :time_signal
  defp parse_splice_command_type(0x07), do: :bandwidth_reservation
  defp parse_splice_command_type(_), do: :private_command

  defp unmarshal_splice_info_section(<<command_type::8, rest::binary>>) do
    command_type = parse_splice_command_type(command_type)

    with {:ok, command} <- parse_splice_command(command_type, rest) do
      {:ok, {command_type, command}}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp parse_splice_command(:splice_null, _data), do: {:ok, %{}}
  defp parse_splice_command(:splice_insert, data), do: SpliceInsert.unmarshal(data, true)
  defp parse_splice_command(_type, _data), do: {:error, :splice_command_not_implemented}
end
