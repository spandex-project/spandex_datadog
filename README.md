# SpandexDatadog

[![Package Version](https://img.shields.io/hexpm/v/spandex_datadog.svg)](https://hex.pm/packages/spandex_datadog)
[![Hex Docs](https://img.shields.io/badge/hex-docs-lightgreen.svg)](https://hexdocs.pm/spandex_datadog/)
[![Downloads](https://img.shields.io/hexpm/dt/spandex_datadog.svg)](https://hex.pm/packages/spandex_datadog)
[![License](https://img.shields.io/hexpm/l/spandex_datadog.svg)](https://github.com/spandex-project/spandex_datadog/blob/master/LICENSE)
[![Last Updated](https://img.shields.io/github/last-commit/spandex-project/spandex_datadog.svg)](https://github.com/spandex-project/spandex_datadog/commits/master)

This is the Datadog adapter for the [Spandex](https://github.com/spandex-project/spandex) tracing library.

## Installation

Add `:spandex_datadog` to the list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:spandex_datadog, "~> 1.2"}
  ]
end
```

To start the Datadog adapter, add a worker to your application's supervisor.

```elixir
# Example configuration

# Note: Put ApiServer before other children that might try to send traces
# before ApiServer has started up, e.g. Ecto.Repo and Phoenix.Endpoint

spandex_opts =
  [
    host: System.get_env("DATADOG_HOST") || "localhost",
    port: System.get_env("DATADOG_PORT") || 8126,
    batch_size: System.get_env("SPANDEX_BATCH_SIZE") || 10,
    sync_threshold: System.get_env("SPANDEX_SYNC_THRESHOLD") || 100,
    http: HTTPoison
  ]

children = [
  # ...
  {SpandexDatadog.ApiServer, spandex_opts},
  MyApp.Repo,
  MyAppWeb.Endpoint,
  # ...
]

opts = [strategy: :one_for_one, name: MyApp.Supervisor]
Supvervisor.start_link(children, opts)
```

## Distributed Tracing

In distributed tracing, multiple processes contribute to the same trace.

That is handled in this adapter by `SpandexDatadog.Adapter.distributed_context/2` and
`SpandexDatadog.Adapter.inject_context/3`, which read and generate Datadog-specific
HTTP headers based on the state of the trace. If these headers are set, the
trace will be continued instead of starting a new one.
They are called by [spandex_phoenix](https://github.com/spandex-project/spandex_phoenix)
when receiving a request and by your own HTTP requests to downstream services.

## Sampling and Rate Limiting

When the load or cost from tracing increases, it is useful to use sampling or
rate limiting to reduce tracing. When many traces are the same, it's enough to
trace only e.g. 10% of them, reducing the bill by 90% while still preserving
the ability to troubleshoot the system.

With sampling, the tracing still happens, but Datadog may drop it or not
retain detailed information. This keeps metrics such as the number of requests
correct, even without detailed trace data.

This adapter supports distributed trace sampling according to the new Datadog
[ingestion controls](https://docs.datadoghq.com/tracing/trace_pipeline/ingestion_controls/).

Spandex stores the `priority` as an integer in the top level `Spandex.Trace`.

In Datadog, there are four values:
* `MANUAL_KEEP`(2) indicates that the application wants to ensure that a trace is
  sampled, e.g. if there is an error
* `AUTO_KEEP` (1) indicates that a trace has been selected for sampling
* `AUTO_REJECT` (0) indicates that the trace has not been selected for sampling
* `MANUAL_REJECT` (-1) indicates that the application wants a trace to be dropped

Datadog uses the `x-datadog-sampling-priority` header to determine whether a
trace should be sampled. See the [Datadog documentation]:
https://docs.datadoghq.com/tracing/getting_further/trace_sampling_and_storage/#priority-sampling-for-distributed-tracing

When sampling, the process that starts the trace can make a decision about
whether it should be sampled. It then passes that information to downstream
processes via the HTTP headers.

In distributed tracing, the priority may be set as follows:

* Set the priority based on the `x-datadog-sampling-priority` header on the
  inbound request, propagating it to downstream http requests.

* If no priority header is present (i.e. this is the first app in the trace),
  make a sampling decision and set the `priority` to 0 or 1 on the current trace.
  `SpandexDatadog.RateSampler.sampled?/2` supports sampling a proportion of
  traces based on the `trace_id` (which should be assigned randomly).  This would
  typically be called from in a Phoenix `plug`, which then sets the priority to 1
  on the current trace using `Spandex.Tracer.update_priority/2`.

* Force tracking manually by setting priority to 2 on the trace in application
  code. This is usually done for requests with errors, as they are the ones
  that need troubleshooting. You can also enable tracing dynamically with a
  feature flag to debug a feature in production. This overrides whatever sampling
  decision was made upstream, and Datadog will keep the complete trace.

Older versions of Datadog used rate sampling to tune the priority of spans, but
those are considered obsolete. You can still set them by adding tags to spans:

* Use `sample_rate` tag to set `_dd1.sr.eausr`
* Use `rule_sample_rate` tag to set `_dd.rule_psr` without default (previously
  hard coded to 1.0)
* Use `rate_limiter_rate` tag to set `_dd.limit_psr`, without default
  (previously hard coded to 1.0)
* Use `agent_sample_rate` tag to set `_dd.agent_psr` without default (was 1.0)

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
before it blocks/throttles your application by making the tracing call
synchronous instead of async.

Ideally, the sync threshold would be set to a point that you wouldn't
reasonably reach often, but that is low enough to not cause systemic
performance issues if you don't apply
backpressure.

A simple way to think about it is that if you are seeing 1000 request per
second and `batch_size` is 10, then you'll be making 100 requests per second to
Datadog (probably a bad config).  With `sync_threshold` set to 10, only 10 of
those requests can be processed concurrently before trace calls become
synchronous.

This concept of backpressure is very important, and strategies for switching to
synchronous operation are often surprisingly far more performant than purely
asynchronous strategies (and much more predictable).

## Copyright and License

Copyright (c) 2021 Zachary Daniel & Greg Mefford

Released under the MIT License, which can be found in the repository in [`LICENSE`](https://github.com/spandex-project/spandex_datadog/blob/master/LICENSE).
