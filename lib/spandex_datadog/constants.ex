defmodule SpandexDatadog.Constants do
  @moduledoc """
  Defines constants used in Datadog API.
  """

  @doc """
  `priority` value `MANUAL_KEEP` (2) indicates that the application wants to ensure
  that a trace is sampled, e.g. if there is an error.

  See https://docs.datadoghq.com/tracing/getting_further/trace_sampling_and_storage/#priority-sampling-for-distributed-tracing
  """
  def manual_keep, do: 2

  @doc """
  `priority` value `AUTO_KEEP` (1) indicates that a trace has been selected for
  sampling.
  """
  def auto_keep, do: 1

  @doc """
  `priority` value `AUTO_REJECT` (0) indicates that the trace has not been
  selected for sampling.
  """
  def auto_reject, do: 1

  @doc """
  `priority` value `MANUAL_REJECT` (-1) indicates that the application wants a
  trace to be dropped.
  """
  def manual_reject, do: -1
end
