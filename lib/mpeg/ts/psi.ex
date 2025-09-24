defmodule MPEG.TS.PSI do
  @behaviour MPEG.TS.Unmarshaler

  @moduledoc """
  Program Specific Information payload. Supported tables are PMT and PAT.
  """

  @type header_t :: %{
          table_id: 0..255,
          section_syntax_indicator: boolean,
          section_length: 0..4095,
          transport_stream_id: 0..65_535 | nil,
          version_number: 0..31 | nil,
          current_next_indicator: boolean | nil,
          section_number: 0..255 | nil,
          last_section_number: 0..255 | nil
        }
  @type t :: %__MODULE__{header: header_t(), table: bitstring(), crc: binary()}
  defstruct [:header, :table, :crc]

  @crc_length 4
  @remaining_header_length 5

  @impl true
  def is_unmarshable?(data, is_start_unit) do
    case unmarshal_header(data, is_start_unit) do
      {:ok, _} -> true
      _ -> false
    end
  end

  @impl true
  def unmarshal(data, is_start_unit) do
    with {:ok, {header, data}} <- unmarshal_header(data, is_start_unit) do
      header_overhead = if header.section_syntax_indicator, do: @remaining_header_length, else: 0
      content_length = header.section_length - @crc_length - header_overhead

      case data do
        <<raw_data::binary-size(content_length), crc::@crc_length-binary, _::binary>> ->
          {:ok, %__MODULE__{header: header, table: raw_data, crc: crc}}

        _ ->
          {:error, :invalid_data}
      end
    end
  end

  def unmarshal_header(<<0::8, data::bitstring>>, true), do: unmarshal_header(data)

  def unmarshal_header(data, true) do
    # For short form sections (like SCTE-35), there may be no pointer field
    case unmarshal_header(data) do
      {:ok, {%{section_syntax_indicator: false} = header, rest}} -> {:ok, {header, rest}}
      _ -> {:error, :invalid_header}
    end
  end

  def unmarshal_header(data, false), do: unmarshal_header(data)

  def unmarshal_header(<<
        table_id::8,
        section_syntax_indicator::1,
        0::1,
        _r1::2,
        # section length starts with 00
        0::2,
        section_length::10,
        rest::binary
      >>) do
    case section_syntax_indicator do
      1 -> unmarshal_long_header(table_id, section_length, rest)
      0 -> unmarshal_short_header(table_id, section_length, rest)
    end
  end

  def unmarshal_header(_), do: {:error, :invalid_header}

  defp unmarshal_long_header(table_id, section_length, <<
         transport_stream_id::16,
         _r2::2,
         version_number::5,
         current_next_indicator::1,
         section_number::8,
         last_section_number::8,
         rest::binary
       >>) do
    header = %{
      table_id: table_id,
      section_syntax_indicator: true,
      section_length: section_length,
      transport_stream_id: transport_stream_id,
      version_number: version_number,
      current_next_indicator: current_next_indicator == 1,
      section_number: section_number,
      last_section_number: last_section_number
    }

    {:ok, {header, rest}}
  end

  defp unmarshal_short_header(table_id, section_length, rest) do
    header = %{
      table_id: table_id,
      section_syntax_indicator: false,
      section_length: section_length,
      transport_stream_id: nil,
      version_number: nil,
      current_next_indicator: nil,
      section_number: nil,
      last_section_number: nil
    }

    {:ok, {header, rest}}
  end

  @doc """
  Extracts the complete SCTE-35 section as base64 for validation.

  For SCTE-35 sections (table_id 0xFC), this reconstructs the full section
  including the table_id, section_length, payload, and CRC for use with
  external SCTE-35 validation tools.

  ## Examples

      iex> psi = %PSI{header: %{table_id: 0xFC, section_syntax_indicator: false, section_length: 20}, table: <<...>>, crc: <<...>>}
      iex> to_scte35_base64(psi)
      "/DA0AAA..."
  """
  @spec to_scte35_base64(t()) :: String.t() | {:error, :not_scte35}
  def to_scte35_base64(%__MODULE__{header: %{table_id: 0xFC} = header, table: table, crc: crc}) do
    # Reconstruct the complete SCTE-35 section
    syntax_indicator_bit = if header.section_syntax_indicator, do: 1, else: 0

    section_header = <<
      header.table_id::8,
      syntax_indicator_bit::1,
      # private_bit
      0::1,
      # reserved bits
      0b11::2,
      # section_length upper 2 bits
      0::2,
      header.section_length::10
    >>

    complete_section = section_header <> table <> crc
    Base.encode64(complete_section)
  end

  def to_scte35_base64(_), do: {:error, :not_scte35}

  defimpl MPEG.TS.Marshaler do
    import Bitwise

    @crc_length 4
    @remaining_header_length 5

    def marshal(%{header: header, table: table}) do
      section_length =
        if header.section_syntax_indicator,
          do: byte_size(table) + @remaining_header_length + @crc_length,
          else: byte_size(table) + @crc_length

      psi_header =
        <<header.table_id::8, bool_to_int(header.section_syntax_indicator)::1,
          _private_bit = 0::1, _reserved = 0b11::2, 0::2, section_length::10>>

      long_header =
        if header.section_syntax_indicator do
          <<header.transport_stream_id::16, 0b11::2, header.version_number::5,
            bool_to_int(header.current_next_indicator)::1, header.section_number::8,
            header.last_section_number::8>>
        else
          <<>>
        end

      payload = psi_header <> long_header <> table
      <<0, payload::binary, crc32(payload)::32>>
    end

    defp bool_to_int(true), do: 1
    defp bool_to_int(_), do: 0

    defp crc32(data) do
      data
      |> :binary.bin_to_list()
      |> Enum.reduce(0xFFFFFFFF, fn byte, crc ->
        crc = bxor(crc, byte <<< 24)

        Enum.reduce(0..7, crc, fn _i, crc ->
          if (crc &&& 0x80000000) == 0, do: crc <<< 1, else: bxor(crc <<< 1, 0x104C11DB7)
        end)
      end)
    end
  end
end
