![Tests](https://github.com/msramos/hackney_telemetry/actions/workflows/ci.yml/badge.svg)
[![Contributor Covenant](https://img.shields.io/badge/Contributor%20Covenant-2.1-4baaaa.svg)](CODE_OF_CONDUCT.md)

> [!IMPORTANT]
> This is the new upstream of this project. The [TheRealReal](https://github.com/TheRealReal/hackney_telemetry) repository will no longer be mantained.

# hackney_telemetry

Telemetry adapter for Hackney metrics.

> [!NOTE]
> This version requires hackney 4.8. For hackney 1.x use 0.2.0.

Hackney 4 no longer reports metrics itself. This library adds a
[middleware](https://hackney.hexdocs.pm/middleware.html) to hackney that
tracks requests, and a poller that reads `hackney_pool:get_stats/1`, and
generates [Telemetry](https://github.com/beam-telemetry/telemetry) events.

## Telemetry metrics

The following metrics are exported by this library to telemetry.

| Metric                      | Tags | Meaning                                               |
| --------------------------- | ---- | ----------------------------------------------------- |
| `hackney.nb_requests`       | -    | Current number of requests                            |
| `hackney.finished_requests` | -    | Total number of finished requests                     |
| `hackney.total_requests`    | -    | Total number of requests                              |
| `hackney_pool.max`          | pool | Maximum number of idle sockets kept in a pool         |
| `hackney_pool.free_count`   | pool | Number of free sockets in a connection pool           |
| `hackney_pool.in_use_count` | pool | Number of busy sockets in a connection pool           |

The poller reads the pools and `nb_requests` every `report_interval` (every
second when it's 0). Pool metrics are emitted when they're read. `nb_requests`
is reported by its worker, so it can be up to two intervals old. A request
whose process is killed before it returns counts as finished at the next read.

In hackney 4, `in_use_count` can go above `max`: `max` bounds the idle sockets,
not the busy ones.

Hackney 4 can't provide `hackney_pool.no_socket`, `hackney_pool.queue_count` or
`hackney_pool.take_rate`, so they are no longer reported.

The library also emits these events:

| Event                            | Metadata                                        | Meaning                                               |
| -------------------------------- | ----------------------------------------------- | ----------------------------------------------------- |
| `[hackney, request, start]`      | method, host, pool                              | A request started                                     |
| `[hackney, request, stop]`       | method, host, pool, status, error               | A request returned, with its `duration`               |
| `[hackney, request, exception]`  | method, host, pool, kind, reason, stacktrace    | A request raised, with its `duration`                 |
| `[hackney, checkout_timeout]`    | host, pool                                      | A request got `{error, checkout_timeout}`             |
| `[hackney_pool, stats_timeout]`  | pool                                            | A pool didn't answer `get_stats/1` in time            |

`pool` is `none` for requests that don't use a pool. `status` is `undefined`
for errors and for async or streaming requests. Don't use `error`, `reason` or
`stacktrace` as tags.

To use it, make sure that the `hackney_telemetry` application starts before
your application.

The middleware passes request metrics to a `hackney_telemetry_worker`, which
keeps the current state of the metric and generates Telemetry events.

Requests that set their own `middleware` option replace hackney's global chain,
so they are not counted.

A worker process has two jobs:

1.  Calculate metric values

    The middleware sends updates like "increase this counter by 1" for every
    request. The job of a metric worker is to process these updates and keep
    up-to-date state representing the value of the tracked metric. State
    updates run in constant time (O(1)).

2.  Send metric values to Telemetry

    If we send the metric value to Telemetry after every update, then
    telemetry processing may not be able to keep up, and Telemetry will apply
    backpressure.

    Since the worker maintains the most up-to-date value, we can send the current
    value periodically. Gauge metrics may be less accurate, but it avoids overload.

## Installation

Install it from [Hex](https://hex.pm/packages/hackney_telemetry) or
[Github](https://github.com/msramos/hackney_telemetry).

## Configuration

No hackney configuration is needed: the application installs its middleware
when it starts.

### Options

#### Report interval

By default, workers will report data to telemetry every 1000 milliseconds.
If set to 0, events are generated after every update. The poller uses the same
interval, or every second when it's 0.

You can change that by setting the `report_interval` option:

**Erlang**

```erlang
{hackney_telemetry, [{report_interval, 2000}]}
```

**Elixir**

```elixir
config :hackney_telemetry, report_interval: 2_000
```

## Usage

After installing the module, your application will receive Telemetry events.
You can handle them in your application, or install a reporting module such
as [Telemetry.Metrics](https://hex.pm/packages/telemetry_metrics)
or [prom_ex](https://hex.pm/packages/prom_ex).

## Elixir

```elixir
defmodule YourApplcation.Telemetry do
  import Telemetry.Metrics

  def metrics do
  [
    # other metrics

    last_value("hackney.nb_requests"),
    last_value("hackney.finished_requests"),
    last_value("hackney.total_requests"),
    last_value("hackney_pool.max", tags: [:pool]),
    last_value("hackney_pool.free_count", tags: [:pool]),
    last_value("hackney_pool.in_use_count", tags: [:pool]),
    counter("hackney_pool.stats_timeout.count", tags: [:pool]),
    counter("hackney.checkout_timeout.count", tags: [:host, :pool]),
    distribution("hackney.request.stop.duration",
      unit: {:native, :millisecond},
      tags: [:host, :pool, :status]
    )
  ]
  end
end
```

## Building

To build the source code locally you'll need [rebar3](https://github.com/erlang/rebar3):

```
rebar3 compile
```

## Test

```console
rebar3 ct
```

## Docs

```console
rebar3 ex_doc
```

## Format code

```console
rebar3 format
```

## Code of Conduct

This project  Contributor Covenant version 2.1. Check [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md) file for more information.

## License

`hackney_telemetry` source code is released under Apache License 2.0.

Check [NOTICE](NOTICE) and [LICENSE](LICENSE) files for more information.
