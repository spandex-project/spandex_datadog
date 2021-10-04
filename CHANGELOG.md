# Changelog

All notable changes to this project will be documented in this file.
See [Conventional Commits](Https://conventionalcommits.org) for commit guidelines.

<!-- changelog -->

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
