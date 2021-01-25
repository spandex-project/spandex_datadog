defmodule SpandexDatadog.ApiServer.Reporter do
  @moduledoc false
  # This client module periodically grabs the information from the various buffers
  # and sends it to datadog.
  use GenServer

  alias SpandexDatadog.ApiServer.Buffer
  alias SpandexDatadog.ApiServer.Client

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc false
  def flush do
    GenServer.call(__MODULE__, :flush)
  end

  @doc false
  def enable_verbose_logging do
    GenServer.call(__MODULE__, {:verbose_logging, true})
  end

  @doc false
  def disable_verbose_logging do
    GenServer.call(__MODULE__, {:verbose_logging, false})
  end

  @doc false
  def set_http_client(mod) do
    GenServer.call(__MODULE__, {:set_http, mod})
  end

  def init(opts) do
    host  = opts[:host]
    port  = opts[:port]
    collector_url = "#{host}:#{port}/v0.3/traces"
    state =
      opts
      |> update_in([:flush_period], & &1 || 1_000)
      |> put_in([:collector_url], collector_url)

    schedule(state.flush_period)

    {:ok, state}
  end

  # Only used for development and testing purposes
  def handle_call(:flush, _, state) do
    # this little dance is hella weird, but it ensures that we can call this
    # with backpressure in tests and we don't need to duplicate code in lots of
    # places.
    handle_info(:flush, state)
    {:reply, :ok, state}
  end

  def handle_call({:verbose_logging, bool}, _, state) do
    {:reply, :ok, %{state | verbose?: bool}}
  end

  def handle_call({:set_http, mod}, _, state) do
    {:reply, :ok, %{state | http: mod}}
  end

  def handle_info(:flush, state) do
    # Run this function in a task to avoid bloating this processes binary memory
    # and generally optimize GC. We're not really protecting ourselves from failure
    # here because if the task exits, we're going to exit as well. But that's OK
    # and is probably what we want.
    state.task_sup
    |> Task.Supervisor.async(fn -> flush(state) end)
    |> Task.await()

    schedule(state.flush_period)

    {:noreply, state}
  end

  defp flush(state) do
    :telemetry.span([:spandex_datadog, :client, :flush], %{}, fn ->
      Buffer.flush_latest(state.buffer, fn
        [] ->
          :ok

        buffer ->
          buffer
          |> Enum.chunk_every(state.batch_size)
          |> Enum.each(fn batch ->
            Client.send(state.http, state.collector_url, batch, verbose?: state.verbose?)
          end)
      end)

      {:ok, %{}}
    end)
  end

  defp schedule(timeout) do
    # next time = min(max(min_time * 2, 1_000), 1_000)
    # If our minimum requests are taking way longer than 1 second than don't try
    # schedule another
    Process.send_after(self(), :flush, timeout)
  end
end
