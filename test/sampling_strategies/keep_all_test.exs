defmodule SpandexDatadog.SamplingStrategies.KeepAllTest do
  use ExUnit.Case

  alias SpandexDatadog.DatadogConstants
  alias SpandexDatadog.SamplingStrategies.KeepAll

  test "returns correct 'auto_keep' priority" do
    assert KeepAll.calculate_sampling("123") == %{
             priority: DatadogConstants.sampling_priority()[:AUTO_KEEP],
             sampling_rate_used: 1.0,
             sampling_mechanism_used: DatadogConstants.sampling_mechanism_used()[:DEFAULT]
           }
  end
end
