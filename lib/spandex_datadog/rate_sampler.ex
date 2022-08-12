defmodule SpandexDatadog.RateSampler do
  @moduledoc """
  Randomly sample a proportion of traces based on the trace_id.
  """

  # We only generate 63-bit integers due to limitations in other languages, but
  # support parsing 64-bit integers for distributed tracing since an upstream
  # system may generate one.
  @external_max_id Bitwise.bsl(1, 64)

  @knuth_factor 1111111111111111111

  @doc """
  Determine whether a trace should be sampled.

  This uses the `trace_id` and specified sample rate.
  If the `trace_id` is a randomly generated integer, then it will
  deterministically select a percentage of traces at random.

  `sample_rate` is a float between 0.0 and 1.0. 0.0 means that no trace will
  be sampled, and 1.0 means that all traces will be sampled.
  """
  @spec sampled?(non_neg_integer() | nil | Spandex.Trace.t() | Spandex.Span.t(), float()) :: boolean()
  # trace_id may be nil when tracing is disabled
  def sampled?(nil, _), do: false

  # Shortcut processing for common cases
  def sampled?(_, 1.0), do: true

  def sampled?(_, 0.0), do: false

  def sampled?(trace_id, sample_rate) when is_integer(trace_id) do
    threshold = trunc(sample_rate * @external_max_id)
    rem(trace_id * @knuth_factor, @external_max_id) <= threshold
  end

  def sampled?(%Spandex.Trace{id: trace_id}, sample_rate) do
    sampled?(trace_id, sample_rate)
  end

  def sampled?(%Spandex.Span{trace_id: trace_id}, sample_rate) do
    sampled?(trace_id, sample_rate)
  end
end
