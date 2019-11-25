defmodule SpandexDatadog.ApiServerTest do
  use ExUnit.Case

  import ExUnit.CaptureLog

  alias Spandex.{
    Span,
    Trace
  }

  alias SpandexDatadog.ApiServer

  defmodule TestOkApiServer do
    def put(url, body, headers) do
      send(self(), {:put_datadog_spans, body |> Msgpax.unpack!() |> hd(), url, headers})
      {:ok, %HTTPoison.Response{status_code: 200}}
    end
  end

  defmodule TestErrorApiServer do
    def put(url, body, headers) do
      send(self(), {:put_datadog_spans, body |> Msgpax.unpack!() |> hd(), url, headers})
      {:error, %HTTPoison.Error{id: :foo, reason: :bar}}
    end
  end

  setup_all do
    {:ok, agent_pid} = Agent.start_link(fn -> 0 end, name: :spandex_currently_send_count)
    trace_id = 4_743_028_846_331_200_905

    {:ok, span_1} =
      Span.new(
        id: 4_743_028_846_331_200_906,
        start: 1_527_752_052_216_478_000,
        service: :foo,
        env: "local",
        name: "foo",
        trace_id: trace_id,
        completion_time: 1_527_752_052_216_578_000,
        tags: [foo: "123", bar: 321, buz: :blitz, baz: {1, 2}, zyx: [xyz: {1, 2}]]
      )

    {:ok, span_2} =
      Span.new(
        id: 4_743_029_846_331_200_906,
        start: 1_527_752_052_216_578_001,
        completion_time: 1_527_752_052_316_578_001,
        service: :bar,
        env: "local",
        name: "bar",
        trace_id: trace_id
      )

    trace = %Trace{spans: [span_1, span_2]}

    {
      :ok,
      [
        trace: trace,
        url: "localhost:8126/v0.3/traces",
        state: %ApiServer.State{
          asynchronous_send?: false,
          host: "localhost",
          port: "8126",
          http: TestOkApiServer,
          verbose?: false,
          waiting_traces: [],
          batch_size: 1,
          agent_pid: agent_pid
        }
      ]
    }
  end

  describe "ApiServer.handle_call/3 - :send_trace" do
    test "doesn't log anything when verbose?: false", %{trace: trace, state: state, url: url} do
      log =
        capture_log(fn ->
          ApiServer.handle_call({:send_trace, trace}, self(), state)
        end)

      assert log == ""

      formatted = [
        %{
          "duration" => 100_000,
          "error" => 0,
          "meta" => %{
            "env" => "local",
            "foo" => "123",
            "bar" => "321",
            "buz" => "blitz",
            "baz" => "{1, 2}",
            "zyx" => "[xyz: {1, 2}]"
          },
          "name" => "foo",
          "service" => "foo",
          "resource" => "foo",
          "span_id" => 4_743_028_846_331_200_906,
          "start" => 1_527_752_052_216_478_000,
          "trace_id" => 4_743_028_846_331_200_905,
          "metrics" => %{
            "_sampling_priority_v1" => 1
          }
        },
        %{
          "duration" => 100_000_000,
          "error" => 0,
          "meta" => %{"env" => "local"},
          "name" => "bar",
          "service" => "bar",
          "resource" => "bar",
          "span_id" => 4_743_029_846_331_200_906,
          "start" => 1_527_752_052_216_578_001,
          "trace_id" => 4_743_028_846_331_200_905,
          "metrics" => %{
            "_sampling_priority_v1" => 1
          }
        }
      ]

      headers = [
        {"Content-Type", "application/msgpack"},
        {"X-Datadog-Trace-Count", 1}
      ]

      assert_received {:put_datadog_spans, ^formatted, ^url, ^headers}
    end

    test "doesn't care about the response result", %{trace: trace, state: state, url: url} do
      state =
        state
        |> Map.put(:verbose?, true)
        |> Map.put(:http, TestErrorApiServer)

      [processing, received_spans, response] =
        capture_log(fn ->
          {:reply, :ok, _} = ApiServer.handle_call({:send_trace, trace}, self(), state)
        end)
        |> String.split("\n")
        |> Enum.reject(fn s -> s == "" end)

      assert processing =~ ~r/Sending 1 traces, 2 spans/

      assert received_spans =~ ~r/Trace: \[%Spandex.Trace{/

      formatted = [
        %{
          "duration" => 100_000,
          "error" => 0,
          "meta" => %{
            "env" => "local",
            "foo" => "123",
            "bar" => "321",
            "buz" => "blitz",
            "baz" => "{1, 2}",
            "zyx" => "[xyz: {1, 2}]"
          },
          "name" => "foo",
          "service" => "foo",
          "resource" => "foo",
          "span_id" => 4_743_028_846_331_200_906,
          "start" => 1_527_752_052_216_478_000,
          "trace_id" => 4_743_028_846_331_200_905,
          "metrics" => %{
            "_sampling_priority_v1" => 1
          }
        },
        %{
          "duration" => 100_000_000,
          "error" => 0,
          "meta" => %{"env" => "local"},
          "name" => "bar",
          "service" => "bar",
          "resource" => "bar",
          "span_id" => 4_743_029_846_331_200_906,
          "start" => 1_527_752_052_216_578_001,
          "trace_id" => 4_743_028_846_331_200_905,
          "metrics" => %{
            "_sampling_priority_v1" => 1
          }
        }
      ]

      assert response =~ ~r/Trace response: {:error, %HTTPoison.Error{id: :foo, reason: :bar}}/
      assert_received {:put_datadog_spans, ^formatted, ^url, _}
    end
  end
end
