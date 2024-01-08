defmodule SpandexDatadog.SamplingStrategies.UseAgentSamplingRateTest do
  use ExUnit.Case
  use ExUnitProperties

  alias SpandexDatadog.DatadogConstants
  alias SpandexDatadog.SamplingStrategies.UseAgentSamplingRate

  defmodule TestOkApiServerAsync do
    def put(_url, _body, _headers) do
      {:ok, %HTTPoison.Response{status_code: 200, body: Jason.encode!(%{rate_by_service: %{"service:,env:": 0.5}})}}
    end
  end

  defmodule ApiServerWithoutSamplingRates do
    def get_sampling_rates() do
      nil
    end
  end

  defmodule ApiServerWithSamplingRates do
    def get_sampling_rates() do
      %{
        "service:important_service,env:prod" => 0.3,
        "service:important_service,env:" => 0.5,
        "service:,env:" => 0.9
      }
    end
  end

  property "always return 1 when no sampling_rates are available yet" do
    check all(trace_id <- integer()) do
      assert UseAgentSamplingRate.calculate_sampling(
               trace_id,
               datadog_api_server: ApiServerWithoutSamplingRates,
               service: "important_service",
               env: "prod"
             ) == %{
               priority: DatadogConstants.sampling_priority()[:AUTO_KEEP],
               sampling_rate_used: 1,
               sampling_mechanism_used: DatadogConstants.sampling_mechanism_used()[:AGENT]
             }
    end
  end

  property "when sampling rate is 0.3 return priority 1 for roughly 30% of traces and 0 for others" do
    priority_generator =
      gen all(trace_id <- integer(0..100_000_000)) do
        UseAgentSamplingRate.calculate_sampling(
          trace_id,
          datadog_api_server: ApiServerWithSamplingRates,
          service: "important_service",
          env: "prod"
        )
        |> Map.get(:priority)
      end

    priority_distribution = priority_generator |> Stream.take(10000) |> Enum.frequencies()

    assert int_equal_with_percentage_margin?(priority_distribution[0], 7000, 0.3)
    assert int_equal_with_percentage_margin?(priority_distribution[1], 3000, 0.3)
  end

  property "when env not provided fall back to service rate" do
    priority_generator =
      gen all(trace_id <- integer(0..1_000_000_000)) do
        UseAgentSamplingRate.calculate_sampling(
          trace_id,
          datadog_api_server: ApiServerWithSamplingRates,
          service: "important_service"
        )
        |> Map.get(:priority)
      end

    priority_distribution = priority_generator |> Stream.take(10000) |> Enum.frequencies()

    assert int_equal_with_percentage_margin?(priority_distribution[0], 5000, 0.3)
    assert int_equal_with_percentage_margin?(priority_distribution[1], 5000, 0.3)
  end

  property "when no context is provided fallback to the default agent value" do
    priority_generator =
      gen all(trace_id <- integer(0..100_000_000)) do
        UseAgentSamplingRate.calculate_sampling(
          trace_id,
          datadog_api_server: ApiServerWithSamplingRates
        )
        |> Map.get(:priority)
      end

    priority_distribution = priority_generator |> Stream.take(10000) |> Enum.frequencies()

    assert int_equal_with_percentage_margin?(priority_distribution[0], 1000, 0.3)
    assert int_equal_with_percentage_margin?(priority_distribution[1], 9000, 0.3)
  end

  # this is a higher level test using a real api_server process
  property "uses sampling rates given by the datadog agent" do
    SpandexDatadog.ApiServer.start_link(
      http: TestOkApiServerAsync,
      batch_size: 1,
      asynchronous_send?: false
    )

    trace_id = 4_743_028_846_331_200_905

    :ok =
      SpandexDatadog.ApiServer.send_trace(%Spandex.Trace{
        id: trace_id,
        spans: [
          %Spandex.Span{
            id: 4_743_028_846_331_200_906,
            start: 1_527_752_052_216_478_000,
            service: :foo,
            service_version: "v1",
            env: "local",
            name: "foo",
            trace_id: trace_id,
            completion_time: 1_527_752_052_216_578_000,
            tags: [is_foo: true, foo: "123", bar: 321, buz: :blitz, baz: {1, 2}, zyx: [xyz: {1, 2}]]
          }
        ]
      })

    priority_generator =
      gen all(trace_id <- integer(0..10_000_000_000)) do
        UseAgentSamplingRate.calculate_sampling(trace_id)
        |> Map.get(:priority)
      end

    priority_distribution = priority_generator |> Stream.take(10000) |> Enum.frequencies()

    assert int_equal_with_percentage_margin?(priority_distribution[0], 5000, 0.3)
    assert int_equal_with_percentage_margin?(priority_distribution[1], 5000, 0.3)
  end

  def int_equal_with_percentage_margin?(a, b, percentage_margin) do
    abs(a - b) <= round(a * percentage_margin)
  end
end
