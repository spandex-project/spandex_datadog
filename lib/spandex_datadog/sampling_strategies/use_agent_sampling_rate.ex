defmodule SpandexDatadog.SamplingStrategies.UseAgentSamplingRate do
  @moduledoc """
  This sampling strategy uses the sampling rate set in the Datadog Agent.

  The datadog agent responds to sending it traces with a sampling rate calculated
  Using an algorithm that takes into account it's configuration, rate limiting, service traffic etc.
  The tracing library is then able to use these rates to set the priority of the trace.

  We keep the current advised sampling rate in the process dictionary and use that to calculate the priority.
  """

  @behaviour Spandex.SamplingStrategy

  @keep_all_traces 1

  @max_uint64 18_446_744_073_709_551_615
  @knuth_factor 111_111_111_111_111_1111

  @impl true
  def calculate_priority(trace_id, opts \\ []) do
    sample_rate = get_sampling_rate(opts)

    threshold = trunc(sample_rate * @max_uint64)

    if rem(trace_id * @knuth_factor, @max_uint64) <= threshold,
      do: 1,
      else: 0
  end

  defp get_sampling_rate(opts) do
    Keyword.get(opts, :datadog_api_server, SpandexDatadog.ApiServer).get_sampling_rates()
    |> do_get_sampling_rate(opts)
  end

  defp do_get_sampling_rate(nil, _opts), do: @keep_all_traces

  defp do_get_sampling_rate(rates, opts) do
    service = Keyword.get(opts, :service)
    env = Keyword.get(opts, :env)

    with nil <- Map.get(rates, "service:#{service},env:#{env}"),
         nil <- Map.get(rates, "service:#{service},env:"),
         nil <- Map.get(rates, "service:,env:") do
      @keep_all_traces
    else
      sampling_rate -> sampling_rate
    end
  end
end
