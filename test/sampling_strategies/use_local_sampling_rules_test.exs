defmodule SpandexDatadog.SamplingStrategies.UseLocalSamplingRulesTest do
  use ExUnit.Case
  use ExUnitProperties

  alias SpandexDatadog.SamplingStrategies.UseLocalSamplingRules

  property "when sampling rate is 0.04 return priority 1 for roughly 4% of traces and 0 for others" do
    priority_generator =
      gen all(trace_id <- integer(0..100_000_000)) do
        UseLocalSamplingRules.calculate_sampling(
          trace_id,
          datadog_api_server: ApiServerWithSamplingRates,
          service: "important_service",
          env: "prod",
          sampling_options: [local_sampling_rate: 0.04]
        )
        |> Map.get(:priority)
      end

    priority_distribution = priority_generator |> Stream.take(10000) |> Enum.frequencies()

    assert int_equal_with_percentage_margin?(priority_distribution[0], 10000 * 0.96, 0.3)
    assert int_equal_with_percentage_margin?(priority_distribution[1], 10000 * 0.04, 0.3)
  end

  def int_equal_with_percentage_margin?(a, b, percentage_margin) do
    abs(a - b) <= round(a * percentage_margin)
  end
end
