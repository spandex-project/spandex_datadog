# SpandexDatadog

[![CircleCI](https://circleci.com/gh/spandex-project/spandex_datadog.svg?style=svg)](https://circleci.com/gh/spandex-project/spandex_datadog)
[![Inline docs](http://inch-ci.org/github/spandex-project/spandex_datadog.svg)](http://inch-ci.org/github/spandex-project/spandex_datadog)
[![Coverage Status](https://coveralls.io/repos/github/spandex-project/spandex_datadog/badge.svg)](https://coveralls.io/github/spandex-project/spandex_datadog)
[![Hex pm](http://img.shields.io/hexpm/v/spandex_datadog.svg?style=flat)](https://hex.pm/packages/spandex_datadog)
[![SourceLevel](https://sourcelevel.io/github/spandex-project/spandex_datadog.svg)](https://sourcelevel.io/github/spandex-project/spandex_datadog)

A datadog adapter for the `spandex` library.

## Installation

The package can be installed by adding `spandex_datadog` to your list of
dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:spandex_datadog, "~> 0.6.0"}
  ]
end
```

To start the datadog adapter, add a worker to your application's supervisor

```elixir
# Example configuration
opts =
  [
    host: System.get_env("DATADOG_HOST") || "localhost",
    port: System.get_env("DATADOG_PORT") || 8126,
    batch_size: System.get_env("SPANDEX_BATCH_SIZE") || 10,
    sync_threshold: System.get_env("SPANDEX_SYNC_THRESHOLD") || 100,
    http: HTTPoison
  ]

# in your supervision tree

worker(SpandexDatadog.ApiServer, [opts])
```

## Distributed Tracing

Distributed tracing is supported via headers `x-datadog-trace-id`,
`x-datadog-parent-id`, and `x-datadog-sampling-priority`. If they are set, the
`Spandex.Plug.StartTrace` plug will act accordingly, continuing that trace and
span instead of starting a new one.  *Both* `x-datadog-trace-id` and
`x-datadog-parent-id` must be set for distributed tracing to work. You can
learn more about the behavior of `x-datadog-sampling-priority` in the [Datadog
priority sampling documentation].

[Datadog priority sampling documentation]: https://docs.datadoghq.com/tracing/getting_further/trace_sampling_and_storage/#priority-sampling-for-distributed-tracing

## API Sender Performance

Originally, the library had an API server and spans were sent via
`GenServer.cast`, but we've seen the need to introduce backpressure, and limit
the overall amount of requests made. As such, the Datadog API sender accepts
`batch_size` and `sync_threshold` options.

Batch size refers to *traces*, not spans, so if you send a large amount of spans
per trace, then you probably want to keep that number low. If you send only a
few spans, then you could set it significantly higher.

Sync threshold is how many _simultaneous_ HTTP pushes will be going to Datadog
before it blocks/throttles your application by making the tracing call synchronous instead of async.

Ideally, the sync threshold would be set to a point that you wouldn't reasonably reach often, but
that is low enough to not cause systemic performance issues if you don't apply
backpressure.

A simple way to think about it is that if you are seeing 1000
request per second and `batch_size` is 10, then you'll be making 100
requests per second to Datadog (probably a bad config).
With `sync_threshold` set to 10, only 10 of those requests can be
processed concurrently before trace calls become synchronous.

This concept of backpressure is very important, and strategies
for switching to synchronous operation are often surprisingly far more
performant than purely asynchronous strategies (and much more predictable).
