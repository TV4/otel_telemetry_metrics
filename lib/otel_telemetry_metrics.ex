# otel_telemetry_metrics.ex
# Based on https://github.com/tsloughter/opentelemetry-erlang-contrib/blob/5f8627989c7ea69c0a02f008673ff9fc8fe7f950/utilities/opentelemetry_telemetry_metrics/lib/otel_telemetry_metrics.ex
# From this pull request: https://github.com/open-telemetry/opentelemetry-erlang-contrib/pull/303
# Licensed under the Apache License, Version 2.0
#
# Modifications Copyright (c) 2025, TV4 Media AB
#
# Changes:
#  * Handling of instruments so that it works in my app
#  * Some refactoring

# Ignoring this file because it should be extracted to opentelemetry-erlang-contrib
# Code is in this repo while we get it working
#
# coveralls-ignore-start
defmodule OtelTelemetryMetrics do
  @moduledoc """
  BASED ON THIS PR:
  https://github.com/open-telemetry/opentelemetry-erlang-contrib/pull/303

  If we can get this generally working, it would be nice to contribute the changes back.

  `OtelTelemetryMetrics.start_link/1` creates OpenTelemetry Instruments for
  `Telemetry.Metric` metrics and records to them when their corresponding
  events are triggered.

      metrics = [
        last_value("vm.memory.binary", unit: :byte),
        counter("vm.memory.total"),
        counter("db.query.duration", tags: [:table, :operation]),
        summary("http.request.response_time",
          tag_values: fn
            %{foo: :bar} -> %{bar: :baz}
          end,
          tags: [:bar],
          drop: fn metadata ->
            metadata[:boom] == :pow
          end
        ),
        sum("telemetry.event_size.metadata",
          measurement: &__MODULE__.metadata_measurement/2
        ),
        distribution("phoenix.endpoint.stop.duration",
          measurement: &__MODULE__.measurement/1
        )
      ]

      {:ok, _} = OtelTelemetryMetrics.start_link([metrics: metrics])

  Then either in your Application code or a dependency execute `telemetry`
  events conataining the measurements. For example, an event that will result
  in the metrics `vm.memory.total` and `vm.memory.binary` being recorded to:

      :telemetry.execute([:vm, :memory], %{binary: 100, total: 200}, %{})

  OpenTelemetry does not support a `summary` type metric, the `summary`
  `http.request.response_time` is recorded as a single bucket histogram.

  In `Telemetry.Metrics` the `counter` type refers to counting the number of
  times an event is triggered, this is represented as a `sum` in OpenTelemetry
  and when recording the value is sent as a `1` every time.

  Metrics of type `last_value` are ignored because `last_value` is not yet an
  aggregation supported on synchronous instruments in Erlang/Elixir
  OpenTelemetry. When it is added to the SDK this library will be updated to
  no longer ignore metrics of this type.
  """

  require Logger
  use GenServer

  @doc """
  """
  def start_link(options) do
    GenServer.start_link(__MODULE__, options, name: __MODULE__)
  end

  @impl true
  def init(options) do
    Process.flag(:trap_exit, true)

    meter = options[:meter] || get_meter()

    metrics = options[:metrics] || []

    handler_ids = create_instruments_and_attach(meter, metrics)

    {:ok, %{handler_ids: handler_ids}}
  end

  @impl true
  def terminate(_, %{handler_ids: handler_ids}) do
    Enum.each(handler_ids, fn id -> :telemetry.detach(id) end)
  end

  defp create_instruments_and_attach(meter, metrics) do
    metrics
    |> Enum.group_by(& &1.event_name)
    |> Enum.map(fn {event_name, metrics} ->
      for metric <- metrics do
        create_instrument(
          metric,
          meter,
          Map.merge(
            %{
              unit: unit(metric.unit),
              description: format_description(metric)
            },
            Keyword.get(metric.reporter_options, :otel, %{})
          )
        )
      end

      handler_id = {__MODULE__, event_name, self()}

      metrics_by_event_name = Enum.group_by(metrics, & &1.event_name)

      :ok =
        :telemetry.attach(
          handler_id,
          event_name,
          &__MODULE__.handle_event/4,
          %{metrics_by_event_name: metrics_by_event_name}
        )

      handler_id
    end)
  end

  defp create_instrument(%Telemetry.Metrics.Counter{} = metric, meter, opts) do
    :otel_counter.create(meter, format_name(metric), opts)
  end

  # a summary is represented as an explicit histogram with a single bucket
  defp create_instrument(%Telemetry.Metrics.Summary{} = metric, meter, opts) do
    :otel_histogram.create(meter, format_name(metric), opts)
  end

  defp create_instrument(%Telemetry.Metrics.Distribution{} = metric, meter, opts) do
    :otel_histogram.create(meter, format_name(metric), opts)
  end

  defp create_instrument(%Telemetry.Metrics.Sum{} = metric, meter, opts) do
    :otel_counter.create(meter, format_name(metric), opts)
  end

  defp create_instrument(%Telemetry.Metrics.LastValue{} = _metric, _meter, _opts) do
    raise "Last value isn't supported with OpenTelemetry when this integration was made!"
  end

  defp unit(:unit), do: "1"
  defp unit(unit), do: "#{unit}"

  defp format_description(metric) do
    metric.description || "#{format_name(metric)}"
  end

  defp format_name(metric) do
    metric.name
    |> Enum.join(".")
    |> String.to_atom()
  end

  def handle_event(event_name, measurements, metadata, %{
        metrics_by_event_name: metrics_by_event_name
      }) do
    metrics = Map.get(metrics_by_event_name, event_name)

    for metric <- metrics do
      if value = keep?(metric, metadata) && extract_measurement(metric, measurements, metadata) do
        ctx = OpenTelemetry.Ctx.get_current()
        tags = extract_tags(metric, metadata)

        meter = get_meter()

        name =
          metric.name
          |> Enum.map_join(".", &to_string/1)
          |> String.to_atom()

        :ok = :otel_meter.record(ctx, meter, name, value, tags)
      end
    end
  end

  defp get_meter do
    :opentelemetry_experimental.get_meter(:opentelemetry.get_application_scope(__MODULE__))
  end

  defp keep?(%{keep: nil}, _metadata), do: true
  defp keep?(%{keep: keep}, metadata), do: keep.(metadata)

  defp extract_measurement(%Telemetry.Metrics.Counter{}, _measurements, _metadata) do
    1
  end

  defp extract_measurement(metric, measurements, metadata) do
    case metric.measurement do
      nil ->
        nil

      fun when is_function(fun, 1) ->
        fun.(measurements)

      fun when is_function(fun, 2) ->
        fun.(measurements, metadata)

      key ->
        measurements[key] || 1
    end
  end

  defp extract_tags(metric, metadata) do
    tag_values = metric.tag_values.(metadata)
    Map.take(tag_values, metric.tags)
  end
end

# coveralls-ignore-stop
