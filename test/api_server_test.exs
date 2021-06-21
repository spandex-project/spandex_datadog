defmodule SpandexDatadog.ApiServerTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Spandex.{
    Span,
    Trace
  }

  alias SpandexDatadog.ApiServer
  alias SpandexDatadog.ApiServer.Reporter

  @pid_key {:test_module, :test_pid}

  defmodule TestOkApiServer do
    def put(url, body, headers) do
      test_pid = :persistent_term.get({:test_module, :test_pid})
      send(test_pid, {:put_datadog_spans, body |> Msgpax.unpack!() |> hd(), url, headers})
      {:ok, %HTTPoison.Response{status_code: 200}}
    end
  end

  defmodule TestErrorApiServer do
    def put(url, body, headers) do
      test_pid = :persistent_term.get({:test_module, :test_pid})
      send(test_pid, {:put_datadog_spans, body |> Msgpax.unpack!() |> hd(), url, headers})
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

    start_supervised({ApiServer, [
      host: "localhost",
      port: "8126",
      http: TestOkApiServer,
      verbose?: false
    ]})

    {
      :ok,
      [
        trace: trace,
        url: "localhost:8126/v0.3/traces"
      ]
    }
  end

  setup do
    :persistent_term.put(@pid_key, self())
    Reporter.set_http_client(TestOkApiServer)
    Reporter.disable_verbose_logging()
    Reporter.flush()

    :ok
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

      ApiServer.start_link(http: TestOkApiServer)

      ApiServer.send_trace(trace)

      {start_measurements, start_metadata} = Process.get([:spandex_datadog, :send_trace, :start])
      assert start_measurements[:system_time]
      assert trace == start_metadata[:trace]

      {stop_measurements, stop_metadata} = Process.get([:spandex_datadog, :send_trace, :stop])
      assert stop_measurements[:duration]
      assert trace == stop_metadata[:trace]

      refute Process.get([:spandex_datadog, :send_trace, :exception])
    end
  end

  describe "flushing traces" do
    test "doesn't log anything when verbose?: false", %{trace: trace, url: url} do
      log =
        capture_log(fn ->
          ApiServer.send_trace(trace)
          Reporter.flush()
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
            "zyx" => "[xyz: {1, 2}]"
          },
          "metrics" => %{
            "_sampling_priority_v1" => 1
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
            "_sampling_priority_v1" => 1
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

      headers = [
        {"Content-Type", "application/msgpack"},
        {"X-Datadog-Trace-Count", 1}
      ]

      assert_received {:put_datadog_spans, ^formatted, ^url, ^headers}
    end

    test "doesn't care about the response result", %{trace: trace, url: url} do
      Reporter.set_http_client(TestErrorApiServer)
      Reporter.enable_verbose_logging()

      [response] =
        capture_log(fn ->
          ApiServer.send_trace(trace)
          Reporter.flush()
        end)
        |> String.split("\n")
        |> Enum.reject(fn s -> s == "" end)

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
            "zyx" => "[xyz: {1, 2}]"
          },
          "metrics" => %{
            "_sampling_priority_v1" => 1
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
            "_sampling_priority_v1" => 1
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
