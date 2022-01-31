defmodule SpandexDatadog.Test.AdapterTest do
  use ExUnit.Case, async: true

  alias Spandex.SpanContext

  alias SpandexDatadog.{
    Adapter,
    Test.TracedModule,
    Test.Util
  }

  test "a complete trace sends spans" do
    TracedModule.trace_one_thing()

    spans = Util.sent_spans()

    Enum.each(spans, fn span ->
      assert span.service == :spandex_test
      assert span.meta.env == "test"
    end)
  end

  test "a trace can specify additional attributes" do
    TracedModule.trace_with_special_name()

    assert(Util.find_span("special_name").service == :special_service)
  end

  test "a span can specify additional attributes" do
    TracedModule.trace_with_special_name()

    assert(Util.find_span("special_name_span").service == :special_span_service)
  end

  test "a complete trace sends a top level span" do
    TracedModule.trace_one_thing()
    span = Util.find_span("trace_one_thing/0")
    refute is_nil(span)
    assert span.service == :spandex_test
    assert span.meta.env == "test"
  end

  test "a complete trace sends the internal spans as well" do
    TracedModule.trace_one_thing()

    assert(Util.find_span("do_one_thing/0") != nil)
  end

  test "the parent_id for a child span is correct" do
    TracedModule.trace_one_thing()

    assert(Util.find_span("trace_one_thing/0").span_id == Util.find_span("do_one_thing/0").parent_id)
  end

  test "a span is correctly notated as an error if an excepton occurs" do
    Util.can_fail(fn -> TracedModule.trace_one_error() end)

    assert(Util.find_span("trace_one_error/0").error == 1)
  end

  test "spans all the way up are correctly notated as an error" do
    Util.can_fail(fn -> TracedModule.error_two_deep() end)

    assert(Util.find_span("error_two_deep/0").error == 1)
    assert(Util.find_span("error_one_deep/0").error == 1)
  end

  test "successful sibling spans are not marked as failures when sibling fails" do
    Util.can_fail(fn -> TracedModule.two_fail_one_succeeds() end)

    assert(Util.find_span("error_one_deep/0", 0).error == 1)
    assert(Util.find_span("do_one_thing/0").error == 0)
    assert(Util.find_span("error_one_deep/0", 1).error == 1)
  end

  describe "distributed_context/2 with Plug.Conn" do
    test "returns a SpanContext struct" do
      conn =
        :get
        |> Plug.Test.conn("/")
        |> Plug.Conn.put_req_header("x-datadog-trace-id", "123")
        |> Plug.Conn.put_req_header("x-datadog-parent-id", "456")
        |> Plug.Conn.put_req_header("x-datadog-sampling-priority", "2")

      assert {:ok, %SpanContext{} = span_context} = Adapter.distributed_context(conn, [])
      assert span_context.trace_id == 123
      assert span_context.parent_id == 456
      assert span_context.priority == 2
    end

    test "priority defaults to 1 (i.e. we currently assume all distributed traces should be kept)" do
      conn =
        :get
        |> Plug.Test.conn("/")
        |> Plug.Conn.put_req_header("x-datadog-trace-id", "123")
        |> Plug.Conn.put_req_header("x-datadog-parent-id", "456")

      assert {:ok, %SpanContext{priority: 1}} = Adapter.distributed_context(conn, [])
    end

    test "returns an error when it cannot detect both a Trace ID and a Span ID" do
      conn = Plug.Test.conn(:get, "/")
      assert {:error, :no_distributed_trace} = Adapter.distributed_context(conn, [])
    end
  end

  describe "distributed_context/2 with Spandex.headers()" do
    test "returns a SpanContext struct when headers is a list" do
      headers = [{"x-datadog-trace-id", "123"}, {"x-datadog-parent-id", "456"}, {"x-datadog-sampling-priority", "2"}]

      assert {:ok, %SpanContext{} = span_context} = Adapter.distributed_context(headers, [])
      assert span_context.trace_id == 123
      assert span_context.parent_id == 456
      assert span_context.priority == 2
    end

    test "returns a SpanContext struct when headers is a map" do
      headers = %{
        "x-datadog-trace-id" => "123",
        "x-datadog-parent-id" => "456",
        "x-datadog-sampling-priority" => "2"
      }

      assert {:ok, %SpanContext{} = span_context} = Adapter.distributed_context(headers, [])
      assert span_context.trace_id == 123
      assert span_context.parent_id == 456
      assert span_context.priority == 2
    end

    test "priority defaults to 1 (i.e. we currently assume all distributed traces should be kept)" do
      headers = %{
        "x-datadog-trace-id" => "123",
        "x-datadog-parent-id" => "456"
      }

      assert {:ok, %SpanContext{priority: 1}} = Adapter.distributed_context(headers, [])
    end

    test "returns an error when it cannot detect both a Trace ID and a Span ID" do
      headers = %{}
      assert {:error, :no_distributed_trace} = Adapter.distributed_context(headers, [])
    end
  end

  describe "inject_context/3" do
    test "Prepends distributed tracing headers to an existing list of headers" do
      span_context = %SpanContext{trace_id: 123, parent_id: 456, priority: 10}
      headers = [{"header1", "value1"}, {"header2", "value2"}]

      result = Adapter.inject_context(headers, span_context, [])

      assert result == [
               {"x-datadog-trace-id", "123"},
               {"x-datadog-parent-id", "456"},
               {"x-datadog-sampling-priority", "10"},
               {"header1", "value1"},
               {"header2", "value2"}
             ]
    end

    test "Merges distributed tracing headers with an existing map of headers" do
      span_context = %SpanContext{trace_id: 123, parent_id: 456, priority: 10}
      headers = %{"header1" => "value1", "header2" => "value2"}

      result = Adapter.inject_context(headers, span_context, [])

      assert result == %{
               "x-datadog-trace-id" => "123",
               "x-datadog-parent-id" => "456",
               "x-datadog-sampling-priority" => "10",
               "header1" => "value1",
               "header2" => "value2"
             }
    end
  end
end
