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
    state = %{
      buffer: opts[:buffer],
      collector_url: "#{host}:#{port}/v0.3/traces",
      verbose?: opts[:verbose?],
      http: opts[:http],
      flush_period: opts[:flush_period] || 1_000,
    }

    schedule(state.flush_period)

    {:ok, state}
  end

  # Only used for development and testing purposes
  def handle_call(:flush, _, state) do
    flush(state)
    {:reply, :ok, state}
  end

  def handle_call({:verbose_logging, bool}, _, state) do
    {:reply, :ok, %{state | verbose?: bool}}
  end

  def handle_call({:set_http, mod}, _, state) do
    {:reply, :ok, %{state | http: mod}}
  end

  def handle_info(:flush, state) do
    flush(state)
    schedule(state.flush_period)

    {:noreply, state}
  end

  defp flush(state) do
    :telemetry.span([:spandex_datadog, :client, :flush], %{}, fn ->
      Buffer.flush_latest(state.buffer, fn buffer ->
        if buffer == [] do
          :ok
        else
          Client.send(state.http, state.collector_url, buffer, verbose?: state.verbose?)
        end
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
