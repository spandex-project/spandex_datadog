defmodule SpandexDatadog.DatadogConstants do
  @sampling_mechanism_used %{
    DEFAULT: 0,
    AGENT: 1,
    RULE: 3,
    MANUAL: 4
  }

  @sampling_priority %{
    USER_REJECT: -1,
    AUTO_REJECT: 0,
    AUTO_KEEP: 1,
    USER_KEEP: 2
  }

  def sampling_mechanism_used do
    @sampling_mechanism_used
  end

  def sampling_priority do
    @sampling_priority
  end
end
