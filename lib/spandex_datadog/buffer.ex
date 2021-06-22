defmodule SpandexDatadog.Buffer do
  @behaviour :gen_statem

  require Logger

  defstruct scheduled_delay_ms: nil,
            exporting_timeout_ms: nil,
            runner_pid: nil,
            handed_off_table: nil,
            max_queue_size: nil,
            check_table_size_ms: nil

  @current_table_key {__MODULE__, :current_table}
  @table_1 :"#{__MODULE__}-1"
  @table_2 :"#{__MODULE__}-2"

  @enabled_key {__MODULE__, :enabled}

  @default_max_queue_size 2048
  @default_scheduled_delay_ms :timer.seconds(5)
  @default_export_timeout_ms :timer.minutes(5)
  @default_check_table_size_ms :timer.seconds(1)

  def child_spec(opts) do
    %{
      id: __MODULE__,
      type: :worker,
      start: {__MODULE__, :start_link, [opts]}
    }
  end

  def start_link(opts) do
    case Map.get(opts, :name) do
      nil ->
        :gen_statem.start_link({:local, __MODULE__}, __MODULE__, opts, [])

      name ->
        :gen_statem.start_link({:local, name}, __MODULE__, opts, [])
    end
  end

  def callback_mode do
    [:state_functions, :state_enter]
  end

  def init(opts) do
    Process.flag(:trap_exit, true)

    size_limit = Map.get(:max_queue_size, opts, @default_max_queue_size)
    exporting_timeout = Map.get(:exporting_timeout_ms, opts, @default_export_timeout_ms)
    scheduled_delay = Map.get(:scheduled_delay_ms, opts, @default_scheduled_delay_ms)
    check_table_size = Map.get(:check_table_size_ms, opts, @default_check_table_size_ms)

    _tid1 = new_export_table(@table_1)
    _tid2 = new_export_table(@table_2)
    :persistent_term.put(@current_table_key, @table_1)

    enable()

    max_queue_size =
      case size_limit do
        :infinity -> :infinity
        _ -> div(size_limit, :erlang.system_info(:wordsize))
      end

    {:ok, :idle,
     %__MODULE__{
       handed_off_table: :undefined,
       max_queue_size: max_queue_size,
       exporting_timeout_ms: exporting_timeout,
       check_table_size_ms: check_table_size,
       scheduled_delay_ms: scheduled_delay
     }}
  end

  def idle(:enter, _old_state, %__MODULE__{scheduled_delay_ms: send_interval}) do
    {:keep_state_and_data, [{{:timeout, :export_spans}, send_interval, :export_spans}]}
  end

  def idle(_, :export_spans, data) do
    {:next_state, :exporting, data}
  end

  def idle(event_type, event, data) do
    handle_event_(:idle, event_type, event, data)
  end

  def exporting({:timeout, :export_spans}, :export_spans, _) do
    {:keep_state_and_data, [:postpone]}
  end

  def exporting(
        :enter,
        _old_state,
        %__MODULE__{exporting_timeout_ms: exporting_timeout, scheduled_delay_ms: send_interval} = data
      ) do
    {old_table_name, runner_pid} = export_spans(data)

    {:keep_state, %__MODULE__{data | runner_pid: runner_pid, handed_off_table: old_table_name},
     [
       {:state_timeout, exporting_timeout, :exporting_timeout},
       {{:timeout, :export_spans}, send_interval, :export_spans}
     ]}
  end

  def exporting(:state_timeout, :exporting_timeout, %__MODULE__{handed_off_table: exporting_table} = data) do
    # kill current exporting process because it is taking too long
    # which deletes the exporting table, so create a new one and
    # repeat the state to force another span exporting immediately
    data = kill_runner(data)
    new_export_table(exporting_table)
    {:repeat_state, data}
  end

  # important to verify runner_pid and from_pid are the same in case it was sent
  # after kill_runner was called but before it had done the unlink
  def exporting(:info, {'EXIT', from_pid, _}, %__MODULE__{runner_pid: from_pid} = data) do
    complete_exporting(data)
  end

  # important to verify runner_pid and from_pid are the same in case it was sent
  # after kill_runner was called but before it had done the unlink
  def exporting(:info, {:completed, from_pid}, %__MODULE__{runner_pid: from_pid} = data) do
    complete_exporting(data)
  end

  def exporting(event_type, event, data) do
    handle_event_(:exporting, event_type, event, data)
  end

  def handle_event_(_state, {:timeout, :check_table_size}, :check_table_size, %__MODULE__{max_queue_size: :infinity}) do
    :keep_state_and_data
  end

  def handle_event_(_state, {:timeout, :check_table_size}, :check_table_size, %__MODULE__{
        max_queue_size: max_queue_size
      }) do
    case :ets.info(current_table(), :size) do
      m when m >= max_queue_size ->
        disable()
        :keep_state_and_data

      _ ->
        enable()
        :keep_state_and_data
    end
  end

  def handle_event_(_, _, _, _) do
    :keep_state_and_data
  end

  def terminate(_, _, _data) do
    # TODO: flush buffers to export
    :ok
  end

  def enable do
    :persistent_term.put(@enabled_key, true)
  end

  def disable do
    :persistent_term.put(@enabled_key, false)
  end

  def is_enabled do
    :persistent_term.get(@enabled_key, true)
  end

  def do_insert(span) do
    try do
      case is_enabled() do
        true ->
          :ets.insert(current_table(), span)

        _ ->
          :dropped
      end
    catch
      :error, :badarg ->
        {:error, :no_batch_span_processor}

      _, _ ->
        {:error, :other}
    end
  end

  def complete_exporting(%__MODULE__{handed_off_table: exporting_table} = data) when exporting_table != :undefined do
    new_export_table(exporting_table)
    {:next_state, :idle, %__MODULE__{data | runner_pid: :undefined, handed_off_table: :undefined}}
  end

  def kill_runner(%__MODULE__{runner_pid: runner_pid} = data) do
    :erlang.unlink(runner_pid)
    :erlang.exit(:runner_pid, :kill)
    %__MODULE__{data | runner_pid: :undefined, handed_off_table: :undefined}
  end

  def new_export_table(name) do
    :ets.new(name, [:public, :named_table, {:write_concurrency, true}, :duplicate_bag])
  end

  def current_table do
    :persistent_term.get(@current_table_key)
  end

  def export_spans(%__MODULE__{}) do
    current_table = current_table()

    new_current_table =
      case current_table do
        @table_1 -> @table_2
        @table_2 -> @table_1
      end

    # an atom is a single word so this does not trigger a global GC
    :persistent_term.put(@current_table_key, new_current_table)
    # set the table to accept inserts
    enable()

    self = self()
    runner_pid = :erlang.spawn_link(fn -> send_spans(self) end)
    :ets.give_away(current_table, runner_pid, :export)
    {current_table, runner_pid}
  end

  # Additional benefit of using a separate process is calls to `register` won't
  # timeout if the actual exporting takes longer than the call timeout
  def send_spans(from_pid) do
    receive do
      {'ETS-TRANSFER', table, ^from_pid, :export} ->
        table_name = :ets.rename(table, :current_send_table)
        export(table_name)
        :ets.delete(table_name)
        completed(from_pid)
    end
  end

  def completed(from_pid) do
    send(from_pid, {:completed, self()})
  end

  def export(_spans_tid) do
    # don't let a export exception crash us
    # and return true if export failed
    try do
      # export
      true
    catch
      e ->
        Logger.error("export threw exception: #{inspect(e)}")
        true
    end
  end
end
