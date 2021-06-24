defmodule SpandexDatadog.ApiServerTest do
  use ExUnit.Case, async: false

  alias Spandex.{
    Span,
    Trace
  }

  alias SpandexDatadog.ApiServer

  defmodule TestOkApiServer do
    def put(url, body, headers) do
      pid = :persistent_term.get(:test_pid)

      data =
        body
        |> Msgpax.unpack!()
        |> hd()

      send(pid, {:put_datadog_spans, data, url, headers})
      {:ok, %HTTPoison.Response{status_code: 200}}
    end
  end

  defmodule TestErrorApiServer do
    def put(url, body, headers) do
      pid = :persistent_term.get(:test_pid)

      data =
        body
        |> Msgpax.unpack!()
        |> hd()

      send(pid, {:put_datadog_spans, data, url, headers})
      {:error, %HTTPoison.Error{id: :foo, reason: :bar}}
    end
  end

  defmodule TestSlowApiServer do
    def put(_url, _body, _headers) do
      Process.sleep(500)
      {:error, :timeout}
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

    {
      :ok,
      [
        trace: trace,
        url: "localhost:8126/v0.3/traces",
        state: %ApiServer.State{
          host: "localhost",
          port: "8126",
          http: TestOkApiServer,
          verbose?: false
        }
      ]
    }
  end

  describe "ApiServer.send_trace/2" do
    test "executes telemetry on success", %{test: test, trace: trace} do
      self = self()

      :persistent_term.put(:test_pid, self)

      :telemetry.attach_many(
        "#{test}",
        [
          [:spandex_datadog, :insert_trace, :start],
          [:spandex_datadog, :insert_trace, :stop],
          [:spandex_datadog, :insert_trace, :exception]
        ],
        fn name, measurements, metadata, _ ->
          send(self, {:telemetry_event, name, measurements, metadata})
        end,
        nil
      )

      start_supervised!({ApiServer, http: TestOkApiServer})

      ApiServer.send_trace(trace)

      assert_receive {:telemetry_event, [:spandex_datadog, :insert_trace, :start], start_measurements, start_metadata},
                     5000

      assert start_measurements[:system_time]
      assert trace == start_metadata[:trace]

      assert_receive {:telemetry_event, [:spandex_datadog, :insert_trace, :stop], stop_measurements, stop_metadata},
                     5000

      assert stop_measurements[:duration]
      assert trace == stop_metadata[:trace]

      refute_receive {:telemetry_event, [:spandex_datadog, :insert_trace, :exception], _}
    end

    test "sends the trace", %{test: test, trace: trace, url: url} do
      self = self()
      :persistent_term.put(:test_pid, self())

      :telemetry.attach_many(
        "#{test}",
        [
          [:spandex_datadog, :send_traces, :start],
          [:spandex_datadog, :send_traces, :stop],
          [:spandex_datadog, :send_traces, :exception]
        ],
        fn name, measurements, metadata, _ ->
          send(self, {:telemetry_event, name, measurements, metadata})
        end,
        nil
      )

      start_supervised!({ApiServer, http: TestOkApiServer, verbose?: true, send_interval: 50})

      ApiServer.send_trace(trace)

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

      assert_receive {:put_datadog_spans, ^formatted, ^url, ^headers}

      assert_receive {:telemetry_event, [:spandex_datadog, :send_traces, :start], start_measurements, _metadata}
      assert start_measurements[:system_time]

      assert_receive {:telemetry_event, [:spandex_datadog, :send_traces, :stop], stop_measurements, _metadata}
      assert stop_measurements[:duration]

      refute_receive {:telemetry_event, [:spandex_datadog, :send_traces, :exception], _}
    end

    test "doesn't care about the response result", %{trace: trace, url: url} do
      :persistent_term.put(:test_pid, self())
      start_supervised!({ApiServer, http: TestErrorApiServer, verbose?: true, send_interval: 50})

      ApiServer.send_trace(trace)

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

      assert_receive {:put_datadog_spans, ^formatted, ^url, ^headers}
    end
  end
end
