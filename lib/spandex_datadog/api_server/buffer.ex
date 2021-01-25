defmodule SpandexDatadog.ApiServer.Buffer do
  @moduledoc false
  # The buffer is designed to efficiently gather traces and spans without blocking
  # the calling process.
  # It stores each "trace" in an ets table using the processes currect scheduler
  # id. This helps reduce contention on each ets table since, in theory, only one process should be writing to a table at a time.
  # We periodically flush all spans to datadog in the background.

  defstruct tabs: [], counters: nil

  @config_key {__MODULE__, :config}

  # Builds a bunch of ets tables, 1 per scheduler and returns them in a struct
  def new(opts) do
    schedulers = System.schedulers()
    counters = :atomics.new(schedulers, [signed: false])
    config = %{
      max_buffer_size: opts[:max_buffer_size] || 5_000,
      counters: counters,
    }
    :persistent_term.put(@config_key, config)

    # 1 index erlang ftw
    tabs = for s <- 1..schedulers do
      :ets.new(tab_name(s), [:named_table, :set, :public, {:write_concurrency, true}])
    end

    %__MODULE__{tabs: tabs, counters: counters}
  end

  def add_trace(trace) do
    config = :persistent_term.get(@config_key)
    id     = :erlang.system_info(:scheduler_id)
    buffer = :"#{__MODULE__}-#{id}"
    index  = :atomics.add_get(config.counters, id, 1)

    # If we're at the buffer size we drop the new trace on the ground.
    # TODO - This should really be first in last out since we care more about
    # the current data than about the old data.
    if index > config.max_buffer_size do
      # Remove the increment that we just made.
      :atomics.sub(config.counters, id, 1)
    else
      :ets.insert(buffer, {index, trace})
    end
  end

  # Returns the latest messages and then deletes them from the buffer
  def flush_latest(buffer, f) do
    for s <- 1..System.schedulers() do
      # Get current latest index for this table and reset the count to 0
      index = :atomics.exchange(buffer.counters, s, 0)
      # Its possible that we interleave with a different process that is adding
      # additional traces at this point. That means that we're going to possibly
      # allow the caller to overwrite old data (since the index is reset).
      # This is OK for our purposes.
      records = :ets.select(tab_name(s), select_spec(index))
      f.(records)
    end
  end

  defp delete_spec(index) do
    match_spec(index, true)
  end

  def select_spec(index) do
    # If we're selecting stuff we need to get the second element
    match_spec(index, :"$2")
  end

  defp match_spec(index, item) do
    # Get integers less than the current index
    [{{:"$1", :"$2"}, [{:andalso, {:is_integer, :"$1"}, {:"=<", :"$1", index}}], [item]}]
  end

  defp tab_name(index) do
    :"#{__MODULE__}-#{index}"
  end
end
