-module(hackney_telemetry_SUITE).

-compile(export_all).

-include_lib("common_test/include/ct.hrl").

-define(EVENTS, [
    [hackney],
    [hackney, request, start],
    [hackney, request, stop],
    [hackney, request, exception],
    [hackney, checkout_timeout]
]).

all() ->
    [
        installs_middleware_first_and_once,
        passes_through_while_application_is_stopped,
        returns_response_when_application_stops_mid_request,
        does_not_finish_request_started_before_a_restart,
        counts_requests_made_through_hackney,
        counts_request_as_in_flight_until_it_finishes,
        finishes_request_that_raises,
        finishes_request_of_killed_process,
        emits_request_span,
        records_status_of_each_response,
        emits_checkout_timeout_once_across_redirects,
        tags_request_without_pool_as_none
    ].

init_per_suite(Config) ->
    % Report on every update, so each counter change emits an event.
    _ = application:load(hackney_telemetry),
    ok = application:set_env(hackney_telemetry, report_interval, 0),
    {ok, _} = application:ensure_all_started(hackney_telemetry),
    Config.

end_per_suite(Config) ->
    application:stop(hackney_telemetry),
    application:unload(hackney_telemetry),
    Config.

init_per_testcase(_TestCase, Config) ->
    ok = telemetry:attach_many(?MODULE, ?EVENTS, fun ?MODULE:send_to_self/4, self()),
    Config.

end_per_testcase(_TestCase, Config) ->
    telemetry:detach(?MODULE),
    application:set_env(hackney, middleware, [fun hackney_telemetry:call/2]),
    Config.

%% Install

installs_middleware_first_and_once(_Config) ->
    Middleware = fun hackney_telemetry:call/2,
    {ok, [Middleware]} = application:get_env(hackney, middleware),
    Other = fun ?MODULE:other_middleware/2,
    application:set_env(hackney, middleware, [Other, Middleware]),
    ok = hackney_telemetry:install(),
    {ok, [Middleware, Other]} = application:get_env(hackney, middleware).

%% Application stops

passes_through_while_application_is_stopped(_Config) ->
    ok = application:stop(hackney_telemetry),
    try
        {ok, 200, [], <<>>} = hackney_telemetry:call(request([]), fun(_) ->
            {ok, 200, [], <<>>}
        end),
        refute_event([hackney, request, stop])
    after
        ok = application:start(hackney_telemetry)
    end.

returns_response_when_application_stops_mid_request(_Config) ->
    Caller = start_request(),
    ok = application:stop(hackney_telemetry),
    try
        finish_request(Caller)
    after
        ok = application:start(hackney_telemetry)
    end.

does_not_finish_request_started_before_a_restart(_Config) ->
    Caller = start_request(),
    ok = application:stop(hackney_telemetry),
    ok = application:start(hackney_telemetry),
    flush(),
    finish_request(Caller),
    receive
        {[hackney], #{finished_requests := _}, _} = Event -> ct:fail({unexpected_event, Event})
    after 50 -> ok
    end.

%% Counters

counts_requests_made_through_hackney(_Config) ->
    {error, _Reason} = hackney:request(get, <<"http://127.0.0.1:1">>, [], <<>>, []),
    receive_measurement(total_requests),
    receive_measurement(finished_requests).

counts_request_as_in_flight_until_it_finishes(_Config) ->
    Before = in_flight(),
    {ok, 200, [], <<>>} = hackney_telemetry:call(request([]), fun(_) ->
        InFlight = Before + 1,
        InFlight = in_flight(),
        {ok, 200, [], <<>>}
    end),
    Before = in_flight().

finishes_request_that_raises(_Config) ->
    Before = in_flight(),
    {'EXIT', {boom, _}} = (catch hackney_telemetry:call(request([]), fun(_) -> error(boom) end)),
    receive_measurement(finished_requests),
    Before = in_flight(),
    receive
        {[hackney, request, exception], #{duration := _}, Metadata} ->
            #{kind := error, reason := boom, host := <<"api.example.com">>} = Metadata
    after 100 -> ct:fail(exception_not_received)
    end.

finishes_request_of_killed_process(_Config) ->
    Before = in_flight(),
    Caller = start_request(),
    InFlight = Before + 1,
    InFlight = in_flight(),
    Ref = monitor(process, Caller),
    exit(Caller, kill),
    receive
        {'DOWN', Ref, process, Caller, _} -> ok
    end,
    Before = in_flight(),
    receive
        {[hackney], #{finished_requests := _}, #{}} -> ok
    after 100 -> ct:fail(finished_requests_not_received)
    end.

%% Span

emits_request_span(_Config) ->
    hackney_telemetry:call(request([{pool, stripe}]), fun(_) -> {ok, 201, [], <<"body">>} end),
    Metadata = #{method => post, host => <<"api.example.com">>, pool => stripe},
    receive
        {[hackney, request, start], #{system_time := _}, StartMetadata} ->
            Metadata = maps:with([method, host, pool], StartMetadata)
    after 100 -> ct:fail(start_not_received)
    end,
    receive
        {[hackney, request, stop], #{duration := _}, StopMetadata} ->
            #{status := 201} = StopMetadata,
            Metadata = maps:with([method, host, pool], StopMetadata)
    after 100 -> ct:fail(stop_not_received)
    end.

records_status_of_each_response(_Config) ->
    Ref = make_ref(),
    lists:foreach(
        fun({Response, Expected}) ->
            hackney_telemetry:call(request([]), fun(_) -> Response end),
            receive
                {[hackney, request, stop], _, Metadata} ->
                    Expected = maps:with([status, error], Metadata)
            after 100 -> ct:fail({stop_not_received, Response})
            end
        end,
        [
            {{ok, 204, []}, #{status => 204}},
            {{ok, Ref}, #{status => undefined}},
            {{error, timeout}, #{status => undefined, error => timeout}}
        ]
    ),
    refute_event([hackney, checkout_timeout]).

emits_checkout_timeout_once_across_redirects(_Config) ->
    Redirect = maps:merge(request([{redirect_count, 1}]), #{
        url => hackney_url:parse_url(<<"https://redirected.example.com/charges">>)
    }),
    {error, checkout_timeout} = hackney_telemetry:call(request([]), fun(_) ->
        hackney_telemetry:call(Redirect, fun(_) -> {error, checkout_timeout} end)
    end),
    receive
        {[hackney, checkout_timeout], #{count := 1}, #{host := <<"redirected.example.com">>}} -> ok
    after 100 -> ct:fail(checkout_timeout_not_received)
    end,
    refute_event([hackney, checkout_timeout]),
    hackney_telemetry:call(request([{pool, stripe}]), fun(_) -> {error, checkout_timeout} end),
    receive
        {[hackney, checkout_timeout], _, #{host := <<"api.example.com">>, pool := stripe}} -> ok
    after 100 -> ct:fail(checkout_timeout_not_received_again)
    end.

tags_request_without_pool_as_none(_Config) ->
    hackney_telemetry:call(request([{pool, false}]), fun(_) -> {ok, 200, [], <<>>} end),
    receive
        {[hackney, request, stop], _, #{pool := none}} -> ok
    after 100 -> ct:fail(stop_not_received)
    end,
    application:set_env(hackney, use_default_pool, false),
    try
        hackney_telemetry:call(request([]), fun(_) -> {ok, 200, [], <<>>} end),
        receive
            {[hackney, request, stop], _, #{pool := none}} -> ok
        after 100 -> ct:fail(stop_not_received)
        end
    after
        application:unset_env(hackney, use_default_pool)
    end.

%% Helpers

send_to_self(Event, Measurements, Metadata, TestPid) ->
    TestPid ! {Event, Measurements, Metadata},
    ok.

other_middleware(Request, Next) ->
    Next(Request).

request(Options) ->
    #{
        method => post,
        url => hackney_url:parse_url(<<"https://api.example.com/charges">>),
        headers => [],
        body => <<>>,
        options => Options
    }.

% Poll, then take the last nb_requests reported, which is from this poll or a
% later one.
in_flight() ->
    flush(),
    ok = hackney_telemetry_pool_poller:poll(),
    last_in_flight(undefined).

last_in_flight(Value) ->
    receive
        {[hackney], #{nb_requests := NewValue}, #{}} -> last_in_flight(NewValue)
    after 50 ->
        Value =/= undefined orelse ct:fail(nb_requests_not_received),
        Value
    end.

flush() ->
    receive
        {[hackney], _, _} -> flush()
    after 0 -> ok
    end.

% Start a request that blocks until it gets `continue', and return its caller.
start_request() ->
    Self = self(),
    Caller = spawn(fun() ->
        Response = hackney_telemetry:call(request([]), fun(_) ->
            Self ! started,
            receive
                continue -> {ok, 200, [], <<>>}
            end
        end),
        Self ! {response, Response}
    end),
    receive
        started -> Caller
    end.

finish_request(Caller) ->
    Caller ! continue,
    receive
        {response, Response} -> {ok, 200, [], <<>>} = Response
    after 100 -> ct:fail(response_not_received)
    end.

refute_event(Event) ->
    receive
        {Event, _, _} = Received -> ct:fail({unexpected_event, Received})
    after 50 -> ok
    end.

receive_measurement(Key) ->
    receive
        {[hackney], #{Key := Value}, #{}} -> Value
    after 100 -> ct:fail({measurement_not_received, Key})
    end.
