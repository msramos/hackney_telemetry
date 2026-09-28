%%% @doc hackney_telemetry application supervisor.
%%% @end

-module(hackney_telemetry_sup).

-behaviour(supervisor).

% Supervisor callbacks
-export([init/1]).
% Public API
-export([start_link/0]).

-define(SERVER, ?MODULE).

start_link() ->
    supervisor:start_link({local, ?SERVER}, ?MODULE, []).

init([]) ->
    ok = hackney_telemetry:new_table(),
    SupFlags =
        #{
            strategy => one_for_one,
            intensity => 0,
            period => 1
        },
    ChildSpecs =
        [
            hackney_telemetry_worker:child_spec([{metric, [hackney, nb_requests]}]),
            hackney_telemetry_worker:child_spec([{metric, [hackney, total_requests]}]),
            hackney_telemetry_worker:child_spec([{metric, [hackney, finished_requests]}]),
            hackney_telemetry_pool_poller:child_spec()
        ],
    {ok, {SupFlags, ChildSpecs}}.
