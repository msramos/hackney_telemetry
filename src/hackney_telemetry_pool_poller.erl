%%% @doc Polls the stats of every hackney pool.
%%%
%%% Hackney 4 no longer reports pool metrics, so this process reads
%%% `hackney_pool:get_stats/1' and emits a `[hackney_pool]' event for each of
%%% these measurements, with the pool in the metadata:
%%%
%%% - max
%%% - in_use_count
%%% - free_count
%%%
%%% Each pool is polled in its own process, so a pool that doesn't answer
%%% doesn't delay the others. When a pool doesn't answer in time it emits
%%% `[hackney_pool, stats_timeout]'.
%%%
%%% On each poll it also calls `hackney_telemetry:sweep/0'.
%%%
%%% It polls every `report_interval' milliseconds, or every second when
%%% `report_interval' is 0.
%%% @end

-module(hackney_telemetry_pool_poller).

-behaviour(gen_server).

-export([start_link/0, child_spec/0, poll/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-define(MEASUREMENTS, [max, in_use_count, free_count]).
-define(DEFAULT_POLL_INTERVAL, 1000).

-spec child_spec() -> supervisor:child_spec().
child_spec() ->
    #{id => ?MODULE, start => {?MODULE, start_link, []}}.

-spec start_link() -> gen_server:start_ret().
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% @doc Poll the pools now.

-spec poll() -> ok.
poll() ->
    gen_server:call(?MODULE, poll).

init([]) ->
    schedule(),
    {ok, undefined}.

handle_call(poll, _From, State) ->
    poll_pools(),
    {reply, ok, State};
handle_call(_Message, _From, State) ->
    {reply, ok, State}.

handle_cast(_Message, State) ->
    {noreply, State}.

handle_info(poll, State) ->
    schedule(),
    poll_pools(),
    {noreply, State};
handle_info(_Message, State) ->
    {noreply, State}.

poll_pools() ->
    hackney_telemetry:sweep(),
    lists:foreach(fun(Pool) -> proc_lib:spawn(fun() -> report(Pool) end) end, pools()).

% hackney has no function that lists pools, so read the table it keeps them in.
pools() ->
    try ets:tab2list(hackney_pool) of
        Entries -> [Pool || {Pool, _Pid} <- Entries]
    catch
        error:badarg -> []
    end.

report(Pool) ->
    try hackney_pool:get_stats(Pool) of
        Stats ->
            lists:foreach(
                fun(Measurement) ->
                    telemetry:execute(
                        [hackney_pool],
                        #{Measurement => proplists:get_value(Measurement, Stats)},
                        #{pool => Pool}
                    )
                end,
                ?MEASUREMENTS
            )
    catch
        exit:{timeout, _} ->
            telemetry:execute([hackney_pool, stats_timeout], #{count => 1}, #{pool => Pool});
        % The pool stopped after it was listed.
        exit:_ ->
            ok
    end.

schedule() ->
    Interval =
        case application:get_env(hackney_telemetry, report_interval, 0) of
            0 -> ?DEFAULT_POLL_INTERVAL;
            ReportInterval -> ReportInterval
        end,
    erlang:send_after(Interval, self(), poll).
