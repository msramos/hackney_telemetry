-module(hackney_telemetry_pool_poller_SUITE).

-compile(export_all).

-include_lib("common_test/include/ct.hrl").

all() ->
    [
        reports_pool_stats,
        skips_pool_that_stopped,
        reports_pool_stats_timeout,
        polls_nothing_without_hackney,
        polls_every_report_interval,
        ignores_unexpected_messages
    ].

init_per_suite(Config) ->
    % Report on every update, so each gauge change emits an event.
    _ = application:load(hackney_telemetry),
    ok = application:set_env(hackney_telemetry, report_interval, 0),
    {ok, _} = application:ensure_all_started(hackney_telemetry),
    Config.

end_per_suite(Config) ->
    application:stop(hackney_telemetry),
    application:unload(hackney_telemetry),
    Config.

init_per_testcase(_TestCase, Config) ->
    ok = telemetry:attach_many(
        ?MODULE,
        [[hackney_pool], [hackney_pool, stats_timeout]],
        fun ?MODULE:send_to_self/4,
        self()
    ),
    Config.

end_per_testcase(_TestCase, Config) ->
    telemetry:detach(?MODULE),
    Config.

%% Tests

reports_pool_stats(_Config) ->
    Pool = unique_pool(),
    ok = hackney_pool:start_pool(Pool, [{max_connections, 7}]),
    try
        ok = hackney_telemetry_pool_poller:poll(),
        7 = receive_measurement(Pool, max),
        0 = receive_measurement(Pool, in_use_count),
        0 = receive_measurement(Pool, free_count)
    after
        hackney_pool:stop_pool(Pool)
    end.

skips_pool_that_stopped(_Config) ->
    Pool = unique_pool(),
    {Pid, Ref} = spawn_monitor(fun() -> ok end),
    receive
        {'DOWN', Ref, process, Pid, _} -> ok
    end,
    true = ets:insert(hackney_pool, {Pool, Pid}),
    try
        ok = hackney_telemetry_pool_poller:poll(),
        receive
            {[hackney_pool | _], _, #{pool := Pool}} = Event -> ct:fail({unexpected_event, Event})
        after 50 -> ok
        end
    after
        ets:delete(hackney_pool, Pool)
    end.

reports_pool_stats_timeout(_Config) ->
    Pool = unique_pool(),
    Pid = spawn(fun() ->
        receive
            stop -> ok
        end
    end),
    true = ets:insert(hackney_pool, {Pool, Pid}),
    try
        ok = hackney_telemetry_pool_poller:poll(),
        receive
            {[hackney_pool, stats_timeout], #{count := 1}, #{pool := Pool}} -> ok
        after 6000 -> ct:fail(stats_timeout_not_received)
        end
    after
        ets:delete(hackney_pool, Pool),
        Pid ! stop
    end.

polls_nothing_without_hackney(_Config) ->
    ok = application:stop(hackney),
    try
        ok = hackney_telemetry_pool_poller:poll()
    after
        {ok, _} = application:ensure_all_started(hackney)
    end.

polls_every_report_interval(_Config) ->
    Pool = unique_pool(),
    ok = hackney_pool:start_pool(Pool, [{max_connections, 3}]),
    application:set_env(hackney_telemetry, report_interval, 10),
    try
        hackney_telemetry_pool_poller ! poll,
        3 = receive_measurement(Pool, max),
        3 = receive_measurement(Pool, max)
    after
        application:set_env(hackney_telemetry, report_interval, 0),
        hackney_pool:stop_pool(Pool)
    end.

ignores_unexpected_messages(_Config) ->
    Pid = whereis(hackney_telemetry_pool_poller),
    ok = gen_server:call(Pid, unexpected),
    ok = gen_server:cast(Pid, unexpected),
    Pid ! unexpected,
    ok = hackney_telemetry_pool_poller:poll(),
    Pid = whereis(hackney_telemetry_pool_poller).

%% Helpers

send_to_self(Event, Measurements, Metadata, TestPid) ->
    TestPid ! {Event, Measurements, Metadata},
    ok.

receive_measurement(Pool, Key) ->
    receive
        {[hackney_pool], #{Key := Value}, #{pool := Pool}} -> Value
    after 500 -> ct:fail({measurement_not_received, Pool, Key})
    end.

unique_pool() ->
    list_to_atom("hackney_telemetry_" ++ integer_to_list(erlang:unique_integer([positive]))).
