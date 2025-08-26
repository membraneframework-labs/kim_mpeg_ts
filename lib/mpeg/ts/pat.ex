defmodule MPEG.TS.PAT do
  @behaviour MPEG.TS.Unmarshaler

  alias MPEG.TS.PSI

  @moduledoc """
  Program Association Table.
  """

  @type program_id_t :: 0..65_535
  @type program_pid_t :: 0..8191
  @type t :: %__MODULE__{
          programs: %{required(program_id_t()) => program_pid_t()}
        }

  @entry_length 4

  defstruct programs: %{}

  @impl true
  def is_unmarshable?(_data, _is_start_unit), do: false

  @impl true
  def unmarshal(data, is_start_unit) do
    with {:ok, %PSI{table: table}} <- PSI.unmarshal(data, is_start_unit),
         {:ok, table} <- unmarshal_table(table) do
      {:ok, table}
    end
  end

  # Unmarshals Program Association Table data. Each entry should be 4 bytes
  # long. If provided data length is not divisible by entry length an error
  # shall be returned.
  @spec unmarshal_table(binary) :: {:ok, t()} | {:error, :invalid_data}
  def unmarshal_table(data) when rem(byte_size(data), @entry_length) == 0 do
    programs =
      for <<program_number::16, _reserved::3, pid::13 <- data>>,
        into: %{} do
        {program_number, pid}
      end

    {:ok, %__MODULE__{programs: programs}}
  end

  def unmarshal_table(_) do
    {:error, :invalid_data}
  end

  defimpl MPEG.TS.Marshaler do
    def marshal(%{programs: programs}) do
      Enum.map_join(programs, fn {program_number, pid} ->
        <<program_number::16, 0b111::3, pid::13>>
      end)
    end
  end
end
