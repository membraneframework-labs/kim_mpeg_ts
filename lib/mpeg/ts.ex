defmodule MPEG.TS do
  @clock 90_000

  @doc "Converts nanoseconds to MPEG's clock"
  def convert_ts_to_ns(ts), do: round(ts * 1.0e9 / @clock)

  @doc "Converts MPEG's timestamp to nanoseconds"
  def convert_ns_to_ts(ns), do: round(ns * @clock / 1.0e9)
end
