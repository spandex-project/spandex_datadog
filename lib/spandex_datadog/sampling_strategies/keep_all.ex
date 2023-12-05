defmodule SpandexDatadog.SamplingStrategies.KeepAll do
  @moduledoc """
  A Sampling strategy that keeps all traces.
  """

  alias SpandexDatadog.DatadogConstants

  @behaviour Spandex.SamplingStrategy

  @impl true
  def calculate_sampling(_span, _opts \\ []) do
    %{
      priority: DatadogConstants.sampling_priority()[:AUTO_KEEP],
      sampling_rate_used: 1.0,
      sampling_mechanism_used: DatadogConstants.sampling_mechanism_used()[:DEFAULT]
    }
  end
end
