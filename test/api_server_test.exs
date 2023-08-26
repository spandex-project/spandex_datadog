defmodule SpandexDatadog.ApiServerTest do
  use ExUnit.Case, async: false

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

  defmodule TestSlowApiServer do
    def put(_url, _body, _headers) do
      Process.sleep(500)
      {:error, :timeout}
    end
  end

  defmodule TelemetryRecorderPDict do
    def handle_event(event, measurements, metadata, _cfg) do
      Process.put(event, {measurements, metadata})
    end
  end

  setup_all do
    {:ok, agent_pid} = Agent.start_link(fn -> 0 end)
    trace_id = 4_743_028_846_331_200_905

    {:ok, span_1} =
      Span.new(
        id: 4_743_028_846_331_200_906,
        start: 1_527_752_052_216_478_000,
        service: :foo,
        service_version: "v1",
        env: "local",
        name: "foo",
        trace_id: trace_id,
        completion_time: 1_527_752_052_216_578_000,
        tags: [is_foo: true, foo: "123", bar: 321, buz: :blitz, baz: {1, 2}, zyx: [xyz: {1, 2}]]
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

    {:ok, span_3} =
      Span.new(
        id: 4_743_029_846_331_200_906,
        start: 1_527_752_052_216_578_001,
        completion_time: 1_527_752_052_316_578_001,
        service: :bar,
        env: "local",
        name: "bar",
        trace_id: trace_id,
        tags: [analytics_event: true]
      )

    trace = %Trace{spans: [span_1, span_2, span_3]}

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

  describe "ApiServer.send_trace/2" do
    test "executes telemetry on success", %{trace: trace} do
      :telemetry.attach_many(
        "log-response-handler",
        [
          [:spandex_datadog, :send_trace, :start],
          [:spandex_datadog, :send_trace, :stop],
          [:spandex_datadog, :send_trace, :exception]
        ],
        &TelemetryRecorderPDict.handle_event/4,
        nil
      )

      assert {:ok, _pid} = ApiServer.start_link(http: TestOkApiServer, name: __MODULE__)

      ApiServer.send_trace(trace, name: __MODULE__)

      {start_measurements, start_metadata} = Process.get([:spandex_datadog, :send_trace, :start])
      assert start_measurements[:system_time]
      assert trace == start_metadata[:trace]

      {stop_measurements, stop_metadata} = Process.get([:spandex_datadog, :send_trace, :stop])
      assert stop_measurements[:duration]
      assert trace == stop_metadata[:trace]

      refute Process.get([:spandex_datadog, :send_trace, :exception])
    end

    test "executes telemetry on exception", %{trace: trace} do
      :telemetry.attach_many(
        "log-response-handler",
        [
          [:spandex_datadog, :send_trace, :start],
          [:spandex_datadog, :send_trace, :stop],
          [:spandex_datadog, :send_trace, :exception]
        ],
        &TelemetryRecorderPDict.handle_event/4,
        nil
      )

      ApiServer.start_link(http: TestSlowApiServer, batch_size: 0, sync_threshold: 0)

      catch_exit(ApiServer.send_trace(trace, timeout: 1))

      {start_measurements, start_metadata} = Process.get([:spandex_datadog, :send_trace, :start])
      assert start_measurements[:system_time]
      assert trace == start_metadata[:trace]

      refute Process.get([:spandex_datadog, :send_trace, :stop])

      {exception_measurements, exception_metadata} = Process.get([:spandex_datadog, :send_trace, :exception])
      assert exception_measurements[:duration]
      assert trace == start_metadata[:trace]
      assert :exit == exception_metadata[:kind]
      assert nil == exception_metadata[:error]
      assert is_list(exception_metadata[:stacktrace])
    end
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
            "bar" => "321",
            "baz" => "{1, 2}",
            "buz" => "blitz",
            "env" => "local",
            "foo" => "123",
            "is_foo" => "true",
            "version" => "v1",
            "zyx" => "[xyz: {1, 2}]"
          },
          "metrics" => %{
            "_sampling_priority_v1" => 1,
            "_dd.rule_psr" => 1.0,
            "_dd.limit_psr" => 1.0
          },
          "name" => "foo",
          "resource" => "foo",
          "service" => "foo",
          "span_id" => 4_743_028_846_331_200_906,
          "start" => 1_527_752_052_216_478_000,
          "trace_id" => 4_743_028_846_331_200_905
        },
        %{
          "duration" => 100_000_000,
          "error" => 0,
          "meta" => %{
            "env" => "local"
          },
          "metrics" => %{
            "_sampling_priority_v1" => 1,
            "_dd.rule_psr" => 1.0,
            "_dd.limit_psr" => 1.0
          },
          "name" => "bar",
          "resource" => "bar",
          "service" => "bar",
          "span_id" => 4_743_029_846_331_200_906,
          "start" => 1_527_752_052_216_578_001,
          "trace_id" => 4_743_028_846_331_200_905
        },
        %{
          "duration" => 100_000_000,
          "error" => 0,
          "meta" => %{
            "env" => "local"
          },
          "metrics" => %{
            "_dd1.sr.eausr" => 1,
            "_sampling_priority_v1" => 1,
            "_dd.rule_psr" => 1.0,
            "_dd.limit_psr" => 1.0
          },
          "name" => "bar",
          "resource" => "bar",
          "service" => "bar",
          "span_id" => 4_743_029_846_331_200_906,
          "start" => 1_527_752_052_216_578_001,
          "trace_id" => 4_743_028_846_331_200_905
        }
      ]

      headers = [
        {"Content-Type", "application/msgpack"},
        {"Datadog-Meta-Lang", "elixir"},
        {"Datadog-Meta-Lang-Version", System.version()},
        {"Datadog-Meta-Tracer-Version", nil},
        {"X-Datadog-Trace-Count", 1}
      ]

      assert_received {:put_datadog_spans, ^formatted, ^url, ^headers}
    end

    test "doesn't care about the response result", %{trace: trace, state: state, url: url} do
      state =
        state
        |> Map.put(:verbose?, true)
        |> Map.put(:http, TestErrorApiServer)

      [enqueue, processing, received_spans, response] =
        capture_log(fn ->
          {:reply, :ok, _} = ApiServer.handle_call({:send_trace, trace}, self(), state)
        end)
        |> String.split("\n")
        |> Enum.reject(fn s -> s == "" end)

      assert enqueue =~ ~r/Adding trace to stack with 3 spans/

      assert processing =~ ~r/Sending 1 traces, 3 spans/

      assert received_spans =~ ~r/Trace: \[%Spandex.Trace{/

      formatted = [
        %{
          "duration" => 100_000,
          "error" => 0,
          "meta" => %{
            "bar" => "321",
            "baz" => "{1, 2}",
            "buz" => "blitz",
            "env" => "local",
            "foo" => "123",
            "is_foo" => "true",
            "version" => "v1",
            "zyx" => "[xyz: {1, 2}]"
          },
          "metrics" => %{
            "_sampling_priority_v1" => 1,
            "_dd.rule_psr" => 1.0,
            "_dd.limit_psr" => 1.0
          },
          "name" => "foo",
          "resource" => "foo",
          "service" => "foo",
          "span_id" => 4_743_028_846_331_200_906,
          "start" => 1_527_752_052_216_478_000,
          "trace_id" => 4_743_028_846_331_200_905
        },
        %{
          "duration" => 100_000_000,
          "error" => 0,
          "meta" => %{
            "env" => "local"
          },
          "metrics" => %{
            "_sampling_priority_v1" => 1,
            "_dd.rule_psr" => 1.0,
            "_dd.limit_psr" => 1.0
          },
          "name" => "bar",
          "resource" => "bar",
          "service" => "bar",
          "span_id" => 4_743_029_846_331_200_906,
          "start" => 1_527_752_052_216_578_001,
          "trace_id" => 4_743_028_846_331_200_905
        },
        %{
          "duration" => 100_000_000,
          "error" => 0,
          "meta" => %{
            "env" => "local"
          },
          "metrics" => %{
            "_dd.rule_psr" => 1.0,
            "_dd.limit_psr" => 1.0,
            "_dd1.sr.eausr" => 1,
            "_sampling_priority_v1" => 1
          },
          "name" => "bar",
          "resource" => "bar",
          "service" => "bar",
          "span_id" => 4_743_029_846_331_200_906,
          "start" => 1_527_752_052_216_578_001,
          "trace_id" => 4_743_028_846_331_200_905
        }
      ]

      assert response =~ ~r/Trace response: {:error, %HTTPoison.Error{id: :foo, reason: :bar}}/
      assert_received {:put_datadog_spans, ^formatted, ^url, _}
    end
  end
end
