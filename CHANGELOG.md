# Changelog
All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.3.0] - Unreleased
### Changed
- Support hackney 4, which no longer reports metrics. Requires hackney 4.8
  and OTP 27. A middleware updates the request metrics and a poller reads
  `hackney_pool:get_stats/1` for the pool metrics.

### Added
- `hackney_pool.max` metric.
- `[hackney, request, start | stop | exception]` span events.
- `[hackney, checkout_timeout]` and `[hackney_pool, stats_timeout]` events.

### Removed
- `hackney_pool.no_socket`, `hackney_pool.queue_count` and
  `hackney_pool.take_rate`, which hackney 4 can't provide.
- Support for hackney 1.x. Use 0.2.0 with hackney 1.x.
- The `mod_metrics` callbacks: `new/2`, `delete/1`, `increment_counter/1,2`,
  `decrement_counter/1,2`, `update_histogram/2`, `update_meter/2` and
  `update_gauge/2`. `hackney_telemetry` is now the middleware.
- `hackney_telemetry_sup:start_worker/1` and `stop_worker/1`. Pool metrics are
  emitted by the poller instead of per-pool workers.

## [0.2.0] - 2024-07-08
### Changed
- Change project ownership
- Update testing matrix with Erlang 26 and 27 on github CI
- Use telemetry `~> 1.0` instead of `~ 1.0.0`
- Drop `rebar3_steamroll` in favor of `erlfmt`
- Reformat whole project

## [0.1.2] - 2022-09-19
### Changed
- Update docs
- Build docs with ex_doc
- Update specs to successfully run Dialyzer
- Update GitHub action to use caching and run Dializer

## [0.1.1] - 2021-12-10

### Changed
Minor update.

### Fixed
- Fix histogram values shift for `in_use_count` and `free_count metrics`

## [0.1.0] - 2021-12-08

## Added
- First version!
- Metrics collector for hackney global and pool metrics
