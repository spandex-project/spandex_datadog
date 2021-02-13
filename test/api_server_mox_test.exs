defmodule SpandexDatadog.ApiServerMoxTest do
  use ExUnit.Case

  import Mox

  alias Spandex.Trace
  alias SpandexDatadog.ApiServer

  # Make sure mocks are verified when the test exits
  setup :verify_on_exit!

  # use global mox for simplicity, otherwise we have to configure allowances
  setup :set_mox_from_context
  setup :set_mox_global

  test "configured batch_size works properly" do
    # start our ApiServer GenServer
    opts = [
      name: __MODULE__,
      http: HTTPoisonMock,
      batch_size: 5
    ]

    server = ExUnit.Callbacks.start_supervised!({ApiServer, opts}, restart: :temporary)

    # use a send call to async wait for the genserver to send a trace
    test_pid = self()

    trace = %Trace{id: "123"}

    # put 4 traces into the batch
    Enum.each(1..4, fn _ ->
      assert :ok = GenServer.call(server, {:send_trace, trace})
    end)

    # expect a put request to send the traces out
    HTTPoisonMock
    |> expect(:put, fn "localhost:8126/v0.3/traces", _body, _options ->
      send(test_pid, :http_put_finished)
      {:ok, %HTTPoison.Response{}}
    end)

    # put the final trace that should trigger us to send the traces out
    assert :ok = GenServer.call(server, {:send_trace, trace})

    assert_receive :http_put_finished, 100, "Failed to receive confirmation that our traces were sent."
  end

  test "remaining batched traces are flushed on GenServer.stop/3" do
    # start our ApiServer GenServer
    opts = [
      name: __MODULE__,
      http: HTTPoisonMock,
      batch_size: 10
    ]

    server = ExUnit.Callbacks.start_supervised!({ApiServer, opts}, restart: :temporary)

    # use a send call to async wait for the genserver to send a trace
    test_pid = self()

    # put 1 trace in the batch
    trace = %Trace{id: "123"}
    assert :ok = GenServer.call(server, {:send_trace, trace})

    # shut our ApiServer down and expect a final http_put to flush any traces left in the batch
    HTTPoisonMock
    |> expect(:put, fn "localhost:8126/v0.3/traces", _body, _options ->
      send(test_pid, :http_put_finished)
      {:ok, %HTTPoison.Response{}}
    end)

    assert :ok = GenServer.stop(server)
    assert_receive :http_put_finished, 100, "Failed to receive confirmation that our traces were sent."
  end

  test "remaining batched traces are sent on Process.exit because we are trapping exits" do
    # start our ApiServer GenServer
    opts = [
      name: __MODULE__,
      http: HTTPoisonMock,
      batch_size: 10
    ]

    # need to start this genserver unlinked to the test process since we'll be killing it
    # otherwise this test process will crash
    # {:ok, server} = GenServer.start(ApiServer, opts, name: __MODULE__)
    server = ExUnit.Callbacks.start_supervised!({ApiServer, opts}, restart: :temporary)

    # use a send call to async wait for the genserver to send a trace
    test_pid = self()

    # put 1 trace in the batch
    trace = %Trace{id: "123"}
    assert :ok = GenServer.call(server, {:send_trace, trace})

    # shut our ApiServer down and expect a final http_put to flush any traces left in the batch
    HTTPoisonMock
    |> expect(:put, fn "localhost:8126/v0.3/traces", _body, _options ->
      send(test_pid, :http_put_finished)
      {:ok, %HTTPoison.Response{}}
    end)

    assert Process.exit(server, :shutdown)
    assert_receive :http_put_finished, 100, "Failed to receive confirmation that our traces were sent."
  end
end
