# OtelTelemetryMetrics

This is a library to send metrics defined by `telemetry_metrics` (a default library used by Elixir's Phoenix to define `telemetry` metrics which the application cares about) to an open telemetry collector via the open telemetry standard.  At the time of publishing this library, you'll still need to use the "experimental" releases of the open telemetry libraries for Erlang / Elixir because while tracing support is stable, metrics support isn't yet.  Additionally to get this working I needed to use a new version of the libraries which are in github but which haven't been published yet.  This can be done with the following dependency definitions (in Elixir):

```elixir
      {:opentelemetry_experimental,
       git: "https://github.com/TV4/opentelemetry-erlang.git",
       sparse: "apps/opentelemetry_experimental",
       override: true},
      {:opentelemetry_api_experimental,
       git: "https://github.com/TV4/opentelemetry-erlang.git",
       sparse: "apps/opentelemetry_api_experimental",
       override: true},
```

Note that you don't need to bring in the original `opentelemetry` and `opentelemetry_api` libraries because they are dependencies of the "experimental" versions.

This library should eventually go away when this PR has eventually been merged:

<https://github.com/open-telemetry/opentelemetry-erlang-contrib/pull/303>

In the meantime, I was using this code in three different apps and I didn't want to copy/paste it between all of them.

## `reporter_options`

If you need to customize your buckets, you can use the `reporter_options` key to pass options down to `erlang-opentelemetry`:

```elixir
      summary("phoenix.endpoint.stop.duration",
        unit: {:native, :millisecond},
        reporter_options: [
          otel: %{
            advisory_params: %{
              explicit_bucket_boundaries: [
                0.5,
                1.0,
                2.5,
                5.0,
                7.5,
                10.0,
                25.0,
                50.0,
                75.0,
                100.0,
                250.0,
                500.0,
                750.0,
                1000.0
              ]
            }
          }
        ]
      ),

```
