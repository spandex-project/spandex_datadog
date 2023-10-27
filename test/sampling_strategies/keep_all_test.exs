defmodule SpandexDatadog.SamplingStrategies.KeepAllTest do
  use ExUnit.Case

  alias SpandexDatadog.SamplingStrategies.KeepAll

  test "returns correct 'auto_keep' priority" do
    assert KeepAll.calculate_priority("123") == 1
  end
end
