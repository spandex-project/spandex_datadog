defmodule SpandexDatadog.Test.RateSamplerTest do
  use ExUnit.Case, async: true

  alias SpandexDatadog.RateSampler

  describe "sampled?/2" do
    test "sample rate of 0.0 returns false" do
      refute RateSampler.sampled?(1, 0.0)
    end

    test "sample rate of 1.0 returns true" do
      assert RateSampler.sampled?(1, 1.0)
    end

    test "nil trace_id returns false" do
      refute RateSampler.sampled?(nil, 1.0)
    end

    test "trace is sampled" do
      trace_id = trunc(Bitwise.bsl(1, 64) / 2)
      refute RateSampler.sampled?(trace_id, 0.25)
      assert RateSampler.sampled?(trace_id, 0.75)
    end
  end
end
