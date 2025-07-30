defmodule OtelTelemetryMetricsTest do
  use ExUnit.Case
  doctest OtelTelemetryMetrics

  test "greets the world" do
    assert OtelTelemetryMetrics.hello() == :world
  end
end
