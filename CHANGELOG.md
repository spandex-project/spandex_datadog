# Changelog

## [1.4.0](https://github.com/spandex-project/spandex_datadog/compare/1.3.0...1.4.0) (2023-08-26)

## Features
* Add option to flush remaining traces on shutdown by @SophisticaSean in https://github.com/spandex-project/spandex_datadog/pull/34
* Support service version tagging by @gorkunov in https://github.com/spandex-project/spandex_datadog/pull/57
* Add datadog meta headers by @DReigada in https://github.com/spandex-project/spandex_datadog/pull/60

## Bug Fixes
* Handle boolean tag values safely by @DReigada in https://github.com/spandex-project/spandex_datadog/pull/61

## New Contributors
* @SophisticaSean made their first contribution in https://github.com/spandex-project/spandex_datadog/pull/34
* @gorkunov made their first contribution in https://github.com/spandex-project/spandex_datadog/pull/57
* @DReigada made their first contribution in https://github.com/spandex-project/spandex_datadog/pull/61


## [1.3.0](https://github.com/spandex-project/spandex_datadog/compare/1.2.0...1.3.0) (2022-10-16)

## Features

* Update supervision tree docs in README by @GregMefford in https://github.com/spandex-project/spandex_datadog/pull/46
* Add rule_psr and limit_psr metrics to improve trace ingestion rate by @mrz in https://github.com/spandex-project/spandex_datadog/pull/45

## Bug Fixes

* Fix typos by @kianmeng in https://github.com/spandex-project/spandex_datadog/pull/48

## New Contributors
* @mrz made their first contribution in https://github.com/spandex-project/spandex_datadog/pull/45


## [1.2.0](https://github.com/spandex-project/spandex_datadog/compare/1.1.0...1.2.0) (2021-10-23)

### Features:

* Handle structs explicitly when adding error type [#37](https://github.com/spandex-project/spandex_datadog/pull/37)
* Misc doc generation changes [#40](https://github.com/spandex-project/spandex_datadog/pull/40)
* Remove usage of the transitive dependency Optimal [#33](https://github.com/spandex-project/spandex_datadog/pull/33)
* Update min version of telemetry [#43](https://github.com/spandex-project/spandex_datadog/pull/43)
* add container id to ApiServer.State and send in header [#38](https://github.com/spandex-project/spandex_datadog/pull/38)

## [1.1.0](https://github.com/spandex-project/spandex_datadog/compare/1.0.0...1.1.0) (2021-01-19)

### Features:

* Add Telemetry for ApiServer [#28](https://github.com/spandex-project/spandex_datadog/pull/28)



## [1.0.0](https://github.com/spandex-project/spandex_datadog/compare/0.6.0...1.0.0) (2020-05-22)
### Breaking Changes:

* support distributed_context/2 with headers



## [0.6.0](https://github.com/spandex-project/spandex_datadog/compare/0.5.0...0.6.0) (2020-04-23)




### Features:

* add support for app analytics (#23)

## [0.5.0](https://github.com/spandex-project/spandex_datadog/compare/0.4.1...0.5.0) (2019-11-25)




### Features:

* Add X-Datadog-Trace-Count header (#22)

## [0.4.1](https://github.com/spandex-project/spandex_datadog/compare/0.4.0...0.4.1) (2019-10-4)




### Bug Fixes:

* Ensure tags are converted to strings (#16)

## [0.4.0](https://github.com/spandex-project/spandex_datadog/compare/0.3.1...0.4.0) (2019-02-01)




### Features:

* support elixir 1.8 via msgpax bump

## [0.3.1](https://github.com/spandex-project/spandex_datadog/compare/0.3.0...0.3.1) (2018-10-19)

Initial release using automated changelog management

# Changelog prior to automated change log management

## [0.3.0] (2018-09-16)

[0.3.0]: https://github.com/spandex-project/spandex_datadog/compare/v0.3.0...v0.2.0

### Added
- `SpandexDatadog.Adapter.inject_context/3` added to support the new version of
  the `Spandex.Adapter` behaviour.

## [0.2.0] (2018-08-31)

[0.2.0]: https://github.com/spandex-project/spandex_datadog/compare/v0.2.0...v0.1.0

### Added
- Priority sampling of distributed traces is now supported by sending the
  `priorty` field from the `Trace` along with each `Span` sent to Datadog,
  using the appropriate `_sampling_priority_v1` field under the `metrics`
  field.

### Changed
- If the `env` option is not specified for a trace, it will no longer be sent
  to Datadog, This allows the Datadog trace collector configured default to be
  used, if desired.
- `SpandexDatadog.Adapter.distributed_context/2` now returns a `Spandex.Trace`
  struct, including a `priority` based on the `x-datadog-sampling-priority`
  HTTP header.
- `SpandexDatadog.ApiServer` now supports the `send_trace` function, taking a
  `Spandex.Trace` struct.

### Deprecated
- `SpandexDatadog.ApiServer.send_spans/2` is deprecated in favor of
  `SpandexDatadog.ApiServer.send_trace/2`.

## [0.1.0] (2018-08-23)

### Added
- Initial release of the `spandex_datadog` library separately from the
  `spandex` library.

[0.1.0]: https://github.com/spandex-project/spandex_datadog/commit/3c217429ec5e79e77e05729f2a83d355eeab4996
