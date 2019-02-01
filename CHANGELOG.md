# Change Log

All notable changes to this project will be documented in this file.
See [Conventional Commits](Https://conventionalcommits.org) for commit guidelines.

<!-- changelog -->

## [0.4.0](https://github.com/spandex-project/spandex_datadog/compare/0.3.1...0.4.0) (2019-2-1)




### Features:

* support elixir 1.8 via msgpax bump

## [0.3.1](https://github.com/spandex-project/spandex_datadog/compare/0.3.1...0.3.1) (2018-10-19)

Initial release using automated changelog management

# Changelog prior to automated change log management

## [0.3.0]

[0.3.0]: https://github.com/spandex-project/spandex_datadog/compare/v0.3.0...v0.2.0

### Added
- `SpandexDatadog.Adapter.inject_context/3` added to support the new version of
  the `Spandex.Adapter` behaviour.

## [0.2.0]

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

## [0.1.0]

### Added
- Initial release of the `spandex_datadog` library separately from the
  `spandex` library.

[0.1.0]: https://github.com/spandex-project/spandex_datadog/commit/3c217429ec5e79e77e05729f2a83d355eeab4996
