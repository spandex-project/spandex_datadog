defmodule SpandexDatadog.SamplingStrategies.UseLocalSamplingRules do
  @moduledoc """
  This is a minimal version of the rule based datadog sampling.
  It only supports setting a specific rate.
  """

  alias SpandexDatadog.DatadogConstants

  @behaviour Spandex.SamplingStrategy

  @max_uint64 18_446_744_073_709_551_615
  @knuth_factor 111_111_111_111_111_1111

  @impl true
  def calculate_sampling(trace_id, opts \\ []) do
    sampling_rate = get_in(opts, [:sampling_options, :local_sampling_rate]) || 1.0

    threshold = trunc(sampling_rate * @max_uint64)

    priority =
      if rem(trace_id * @knuth_factor, @max_uint64) <= threshold,
        do: DatadogConstants.sampling_priority()[:AUTO_KEEP],
        else: DatadogConstants.sampling_priority()[:AUTO_REJECT]

    %{
      priority: priority,
      sampling_rate_used: sampling_rate,
      sampling_mechanism_used: DatadogConstants.sampling_mechanism_used()[:RULE]
    }
  end
end
