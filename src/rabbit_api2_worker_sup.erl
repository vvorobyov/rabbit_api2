-module(rabbit_api2_worker_sup).
-behaviour(mirrored_supervisor).
-include("rabbit_api2.hrl").

-export([start_link/1]).
-export([init/1]).

-define(CHILD_SPEC(NAME, CONFIG),
        {{static, NAME},
         {rabbit_api2_worker, start_link, [CONFIG]},
         permanent,
         16#ffffffff,
         worker,
         [rabbit_api2_worker]}).
%%%-------------------------------------------------------------------
%%% Starts the supervisor
%%%-------------------------------------------------------------------
start_link(Configuration) ->
    mirrored_supervisor:start_link(?MODULE,
                                   fun rabbit_misc:execute_mnesia_transaction/1,
                                   ?MODULE, Configuration).

%%%===================================================================
%%% Supervisor callbacks
%%%===================================================================
init(Configuration) ->
    Len = maps:size(Configuration),
    SupFlags = {one_for_one, Len*2,2},
    WorkerSpecs = make_worker_specs(Configuration),
    ChildSpecs = WorkerSpecs,
	{ok, {SupFlags, ChildSpecs}}.

%%%===================================================================
%%% Internal functions
%%%===================================================================
make_worker_specs(Configuration)->
    Fun = fun(Name, Config0, AccIn) ->
                  Config = maps:remove(handle_config, Config0),
                  ChildSpec = ?CHILD_SPEC(Name, Config) ,
                  [ChildSpec|AccIn]
          end,
    maps:fold(Fun, [], Configuration).
