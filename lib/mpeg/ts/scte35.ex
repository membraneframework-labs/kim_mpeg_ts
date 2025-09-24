defmodule MPEG.TS.SCTE35 do
  @behaviour MPEG.TS.Unmarshaler

  @moduledoc """
  SCTE-35 Digital Program Insertion Cueing Message.

  Handles parsing of SCTE-35 splice information tables used for
  ad insertion and program signaling in MPEG-TS streams.
  """

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
    :splice_command_length,
    :splice_command_type,

    # Splice Insert Command fields
    :splice_event_id,
    :splice_event_cancel_indicator,
    :out_of_network_indicator,
    :program_splice_flag,
    :duration_flag,
    :splice_immediate_flag,
    :splice_time,
    :component_count,
    :component_tags,

    # Break Duration fields
    :auto_return,
    :duration,

    # Additional fields
    :unique_program_id,
    :avail_num,
    :avails_expected,
    :descriptor_loop_length,
    :splice_descriptors
  ]

  @type t :: %__MODULE__{
          protocol_version: 0..255,
          encrypted_packet: boolean(),
          encryption_algorithm: 0..63,
          pts_adjustment: 0..0x1FFFFFFFF,
          cw_index: 0..255,
          tier: 0..0xFFF,
          splice_command_length: 0..0xFFF,
          splice_command_type: splice_command_type_t(),
          splice_event_id: 0..0xFFFFFFFF | nil,
          splice_event_cancel_indicator: boolean() | nil,
          out_of_network_indicator: boolean() | nil,
          program_splice_flag: boolean() | nil,
          duration_flag: boolean() | nil,
          splice_immediate_flag: boolean() | nil,
          splice_time: non_neg_integer() | nil,
          component_count: 0..255 | nil,
          component_tags: list() | nil,
          auto_return: boolean() | nil,
          duration: non_neg_integer() | nil,
          unique_program_id: 0..0xFFFF | nil,
          avail_num: 0..255 | nil,
          avails_expected: 0..255 | nil,
          descriptor_loop_length: 0..0xFFFF,
          splice_descriptors: list()
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
        rest::binary
      >>) do
    case unmarshal_splice_command(rest, splice_command_length) do
      {:ok, {command_type, command_data, rest}} ->
        case unmarshal_descriptors(rest) do
          {:ok, {descriptor_loop_length, splice_descriptors}} ->
            scte35 = %__MODULE__{
              protocol_version: protocol_version,
              encrypted_packet: encrypted_packet_flag == 1,
              encryption_algorithm: encryption_algorithm,
              pts_adjustment: pts_adjustment,
              cw_index: cw_index,
              tier: tier,
              splice_command_length: splice_command_length,
              splice_command_type: command_type,
              descriptor_loop_length: descriptor_loop_length,
              splice_descriptors: splice_descriptors
            }

            {:ok, Map.merge(scte35, command_data)}

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  def unmarshal_table(_), do: {:error, :invalid_data}

  # Parse splice command based on length and type
  defp unmarshal_splice_command(<<splice_command_type::8, rest::binary>>, command_length)
       when command_length > 0 do
    # Subtract 1 for command type byte
    command_data_length = command_length - 1

    case rest do
      <<command_data::binary-size(command_data_length), remaining::binary>> ->
        case parse_splice_command(splice_command_type, command_data) do
          {:ok, {command_type_atom, parsed_data}} ->
            {:ok, {command_type_atom, parsed_data, remaining}}

          {:error, reason} ->
            {:error, reason}
        end

      _ ->
        {:error, :invalid_data}
    end
  end

  defp unmarshal_splice_command(rest, 0) do
    {:ok, {:splice_null, %{}, rest}}
  end

  # Parse specific splice command types
  defp parse_splice_command(0x05, data) do
    # Splice Insert Command
    parse_splice_insert(data)
  end

  defp parse_splice_command(0x06, data) do
    # Time Signal Command
    {:ok, {:time_signal, parse_time_signal(data)}}
  end

  defp parse_splice_command(type, _data) do
    {:ok, {parse_command_type(type), %{}}}
  end

  # Parse Splice Insert command structure
  defp parse_splice_insert(<<
         splice_event_id::32,
         splice_event_cancel_indicator::1,
         _reserved::7,
         rest::binary
       >>) do
    if splice_event_cancel_indicator == 1 do
      {:ok,
       {:splice_insert,
        %{
          splice_event_id: splice_event_id,
          splice_event_cancel_indicator: true
        }}}
    else
      parse_splice_insert_details(rest, splice_event_id)
    end
  end

  defp parse_splice_insert_details(
         <<
           out_of_network_indicator::1,
           program_splice_flag::1,
           duration_flag::1,
           splice_immediate_flag::1,
           _reserved::4,
           rest::binary
         >>,
         splice_event_id
       ) do
    # Parse splice time if not immediate
    {splice_time, rest} =
      if splice_immediate_flag == 0 and program_splice_flag == 1 do
        parse_splice_time(rest)
      else
        {nil, rest}
      end

    # Parse component data if program_splice_flag is 0
    {component_count, component_tags, rest} =
      if program_splice_flag == 0 do
        parse_components(rest)
      else
        {0, nil, rest}
      end

    # Parse break duration if duration_flag is set
    {auto_return, duration, rest} =
      if duration_flag == 1 do
        parse_break_duration(rest)
      else
        {nil, nil, rest}
      end

    # Parse remaining fields
    case rest do
      <<unique_program_id::16, avail_num::8, avails_expected::8, _remaining::binary>> ->
        {:ok,
         {:splice_insert,
          %{
            splice_event_id: splice_event_id,
            splice_event_cancel_indicator: false,
            out_of_network_indicator: out_of_network_indicator == 1,
            program_splice_flag: program_splice_flag == 1,
            duration_flag: duration_flag == 1,
            splice_immediate_flag: splice_immediate_flag == 1,
            splice_time: splice_time,
            component_count: component_count,
            component_tags: component_tags,
            auto_return: auto_return,
            duration: duration,
            unique_program_id: unique_program_id,
            avail_num: avail_num,
            avails_expected: avails_expected
          }}}

      _ ->
        {:error, :invalid_data}
    end
  end

  # Parse splice time - simplified for now
  defp parse_splice_time(data), do: {nil, data}

  # Parse component data - simplified for now
  defp parse_components(data), do: {0, nil, data}

  # Parse break duration
  defp parse_break_duration(<<
         auto_return::1,
         _reserved::6,
         duration::33,
         rest::binary
       >>) do
    {auto_return == 1, duration, rest}
  end

  # Parse time signal - simplified for now
  defp parse_time_signal(_data), do: %{}

  # Parse descriptors
  defp unmarshal_descriptors(<<descriptor_loop_length::16, rest::binary>>) do
    if descriptor_loop_length == 0 do
      {:ok, {descriptor_loop_length, []}}
    else
      # For now, just skip descriptor parsing and return empty list
      case rest do
        <<_descriptors::binary-size(descriptor_loop_length), _remaining::binary>> ->
          {:ok, {descriptor_loop_length, []}}

        _ ->
          {:error, :invalid_data}
      end
    end
  end

  defp unmarshal_descriptors(_), do: {:error, :invalid_data}

  # Map command type numbers to atoms
  defp parse_command_type(0x00), do: :splice_null
  defp parse_command_type(0x04), do: :splice_schedule
  defp parse_command_type(0x05), do: :splice_insert
  defp parse_command_type(0x06), do: :time_signal
  defp parse_command_type(0x07), do: :bandwidth_reservation
  defp parse_command_type(_), do: :private_command
end
