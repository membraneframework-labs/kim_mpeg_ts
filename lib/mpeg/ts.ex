defmodule MPEG.TS do
  @clock 90_000

  @type timestamp_ns :: non_neg_integer()
  @type timestamp_90khz :: non_neg_integer()

  @doc "Converts nanoseconds to MPEG's clock"
  @spec convert_ts_to_ns(timestamp_90khz()) :: timestamp_ns()
  def convert_ts_to_ns(ts), do: round(ts * 1.0e9 / @clock)

  @doc "Converts MPEG's timestamp to nanoseconds"
  @spec convert_ns_to_ts(timestamp_ns()) :: timestamp_90khz()
  def convert_ns_to_ts(ns), do: round(ns * @clock / 1.0e9)
end
