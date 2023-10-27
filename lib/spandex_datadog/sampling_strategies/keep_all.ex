defmodule SpandexDatadog.SamplingStrategies.KeepAll do
  @moduledoc "This sampling strategy simply sets the priority to 1 for all traces."

  @behaviour Spandex.SamplingStrategy

  @impl true
  def calculate_priority(_trace_id, _opts \\ []), do: 1
end
