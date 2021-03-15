# SpandexDatadog

[![CircleCI](https://circleci.com/gh/spandex-project/spandex_datadog.svg?style=svg)](https://circleci.com/gh/spandex-project/spandex_datadog)
[![Inline docs](http://inch-ci.org/github/spandex-project/spandex_datadog.svg)](http://inch-ci.org/github/spandex-project/spandex_datadog)
[![Coverage Status](https://coveralls.io/repos/github/spandex-project/spandex_datadog/badge.svg)](https://coveralls.io/github/spandex-project/spandex_datadog)
[![Module Version](https://img.shields.io/hexpm/v/spandex_datadog.svg)](https://hex.pm/packages/spandex_datadog)
[![Hex Docs](https://img.shields.io/badge/hex-docs-lightgreen.svg)](https://hexdocs.pm/spandex_datadog/)
[![Total Download](https://img.shields.io/hexpm/dt/spandex_datadog.svg)](https://hex.pm/packages/spandex_datadog)
[![License](https://img.shields.io/hexpm/l/spandex_datadog.svg)](https://github.com/spandex-project/spandex_datadog/blob/master/LICENSE)
[![Last Updated](https://img.shields.io/github/last-commit/spandex-project/spandex_datadog.svg)](https://github.com/spandex-project/spandex_datadog/commits/master)

A datadog adapter for the `:spandex` library.

## Installation

The package can be installed by adding `:spandex_datadog` to your list of
dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:spandex_datadog, "~> 1.1"}
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

## Telemetry

This library includes [telemetry] events that can be used to inspect the
performance and operations involved in sending trace data to Datadog. Please
refer to the [telemetry] documentation to see how to attach to these events
using the standard conventions. The following events are currently exposed:

[telemetry]: https://github.com/beam-telemetry/telemetry

### `[:spandex_datadog, :send_trace, :start]`

This event is executed when the `SpandexDatadog.ApiServer.send_trace/2` API
function is called, typically as a result of the `finish_trace/1` function
being called on your `Tracer` implementation module.

**NOTE:** This event is executed in the same process that is calling this API
function, but at this point, the `Spandex.Trace` data has already been passed
into the `send_trace` function, and thus the active trace can no longer be
modified (for example, it is not possible to use this event to add a span to
represent this API itself having been called).

#### Measurements

* `:system_time`: The time (in native units) this event executed.

#### Metadata

* `trace`: The current `Spandex.Trace` that is being sent to the `ApiServer`.

### `[:spandex_datadog, :send_trace, :stop]`

This event is executed when the `SpandexDatadog.ApiServer.send_trace/2` API
function completes normally.

**NOTE:** This event is executed in the same process that is calling this API
function, but at this point, the `Spandex.Trace` data has already been passed
into the `send_trace` function, and thus the active trace can no longer be
modified (for example, it is not possible to use this event to add a span to
represent this API itself having been called).

#### Measurements

* `:duration`: The time (in native units) spent servicing the API call.

#### Metadata

* `trace`: The `Spandex.Trace` that was sent to the `ApiServer`.

### `[:spandex_datadog, :send_trace, :exception]`

This event is executed when the `SpandexDatadog.ApiServer.send_trace/2` API
function ends prematurely due to an error or exit.

**NOTE:** This event is executed in the same process that is calling this API
function, but at this point, the `Spandex.Trace` data has already been passed
into the `send_trace` function, and thus the active trace can no longer be
modified (for example, it is not possible to use this event to add a span to
represent this API itself having been called).

#### Measurements

* `:duration`: The time (in native units) spent servicing the API call.

#### Metadata

* `trace`: The current `Spandex.Trace` that is being sent to the `ApiServer`.
* `:kind`: The kind of exception raised.
* `:error`: Error data associated with the relevant kind of exception.
* `:stacktrace`: The stacktrace associated with the exception.

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


## Copyright and License

Copyright (c) 2018 Zachary Daniel & Greg Mefford

Released under the MIT License, which can be found in the repository in [`LICENSE`](https://github.com/spandex-project/spandex_datadog/blob/master/LICENSE).
