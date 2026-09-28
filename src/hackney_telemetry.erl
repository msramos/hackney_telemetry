%%% @doc Hackney middleware that reports request metrics.
%%%
%%% The application adds `call/2' to hackney's global middleware chain when it
%%% starts. The middleware updates these request metrics, each kept by a
%%% `hackney_telemetry_worker':
%%%
%%% - [hackney, nb_requests]
%%% - [hackney, total_requests]
%%% - [hackney, finished_requests]
%%%
%%% Requests in flight are kept in an ETS table with the process that made
%%% them. A process can be killed before the middleware sees its request
%%% finish, so `sweep/0' finishes the requests of dead processes and sets
%%% `nb_requests' to the number still in flight. The pool poller calls it.
%%%
%%% It also wraps each request in a `[hackney, request]' span and emits
%%% `[hackney, checkout_timeout]' when a request gets
%%% `{error, checkout_timeout}'.
%%%
%%% Requests pass through untouched while the application isn't running.
%%% @end

-module(hackney_telemetry).

-export([install/0, call/2, new_table/0, sweep/0]).

-include_lib("hackney/include/hackney_lib.hrl").

-define(REQUESTS, hackney_telemetry_requests).
-define(CHECKOUT_TIMEOUT_REPORTED, {?MODULE, checkout_timeout_reported}).

%% @doc Add the middleware to the front of hackney's global chain.
%%
%% Middleware already in the chain is kept.
%% @end

-spec install() -> ok.
install() ->
    Middleware = fun ?MODULE:call/2,
    Chain = application:get_env(hackney, middleware, []),
    application:set_env(hackney, middleware, [Middleware | lists:delete(Middleware, Chain)]).

%% @doc The hackney middleware. See `hackney_middleware'.

-spec call(hackney_middleware:request(), hackney_middleware:next()) ->
    hackney_middleware:response().
call(Request, Next) ->
    Ref = make_ref(),
    try ets:insert(?REQUESTS, {Ref, self()}) of
        true -> count(Ref, Request, Next)
    catch
        % The application isn't running.
        error:badarg -> Next(Request)
    end.

%% @doc Create the table of requests in flight, owned by the calling process.

-spec new_table() -> ok.
new_table() ->
    ?REQUESTS = ets:new(?REQUESTS, [
        set, public, named_table, {write_concurrency, auto}, {decentralized_counters, true}
    ]),
    ok.

%% @doc Finish the requests of dead processes and report `nb_requests'.

-spec sweep() -> ok.
sweep() ->
    Dead = [Ref || {Ref, Pid} <- ets:tab2list(?REQUESTS), not is_process_alive(Pid)],
    lists:foreach(fun(Ref) -> ets:delete(?REQUESTS, Ref) end, Dead),
    Dead =/= [] andalso
        increment([hackney, finished_requests], length(Dead)),
    set([hackney, nb_requests], ets:info(?REQUESTS, size)).

count(Ref, #{options := Options} = Request, Next) ->
    increment([hackney, total_requests], 1),
    try
        span(Request, Next)
    after
        finish(Ref),
        % hackney sets redirect_count on the requests it makes to follow a
        % redirect, so a request without it is the one the caller made.
        proplists:is_defined(redirect_count, Options) orelse
            erase(?CHECKOUT_TIMEOUT_REPORTED)
    end.

% The request only counts as finished if it's still in the table. It isn't when
% the application stopped, or restarted, while the request was in flight.
finish(Ref) ->
    try ets:take(?REQUESTS, Ref) of
        [_] -> increment([hackney, finished_requests], 1);
        [] -> ok
    catch
        error:badarg -> ok
    end.

span(#{method := Method, url := #hackney_url{host = Host}, options := Options} = Request, Next) ->
    Metadata = #{method => Method, host => list_to_binary(Host), pool => pool(Options)},
    telemetry:span([hackney, request], Metadata, fun() ->
        Response = Next(Request),
        Response =:= {error, checkout_timeout} andalso checkout_timeout(Metadata),
        {Response, maps:merge(Metadata, response_metadata(Response))}
    end).

% hackney follows a redirect with a nested request that goes through this
% middleware again and returns its error unchanged. Report a checkout timeout
% once, from the request it happened in.
checkout_timeout(Metadata) ->
    case put(?CHECKOUT_TIMEOUT_REPORTED, true) of
        true ->
            ok;
        undefined ->
            telemetry:execute(
                [hackney, checkout_timeout], #{count => 1}, maps:remove(method, Metadata)
            )
    end.

% Same rules hackney uses to pick the pool of a request.
pool(Options) ->
    case proplists:get_value(pool, Options) of
        false ->
            none;
        undefined ->
            case application:get_env(hackney, use_default_pool, true) of
                false -> none;
                _ -> default
            end;
        Pool ->
            Pool
    end.

response_metadata({ok, Status, _Headers, _Body}) ->
    #{status => Status};
response_metadata({ok, Status, _Headers}) ->
    #{status => Status};
response_metadata({error, Reason}) ->
    #{status => undefined, error => Reason};
response_metadata(_Async) ->
    #{status => undefined}.

increment(Metric, Value) ->
    hackney_telemetry_worker:update(Metric, Value, fun sum/2).

set(Metric, Value) ->
    hackney_telemetry_worker:update(Metric, Value, fun replace/2).

sum(StateValue, EventValue) ->
    StateValue + EventValue.

replace(_StateValue, EventValue) ->
    EventValue.
