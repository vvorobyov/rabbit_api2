%%%-------------------------------------------------------------------
%%% @author Vladislav Vorobyov <vlad@erldev>
%%% @copyright (C) 2018, Vladislav Vorobyov
%%% @doc
%%%
%%% @end
%%% Created : 24 Dec 2018 by Vladislav Vorobyov <vlad@erldev>
%%%-------------------------------------------------------------------
-module(rabbit_api2_sup_sup).

-behaviour(supervisor2).

-define(COWBOY_SPEC(CONFIG),
        {rabbit_api2_cowboy_worker,
         {rabbit_api2_cowboy_worker, start_link, [CONFIG]},
         permanent,
         16#ffffffff,
         worker,
         [rabbit_api2_cowboy_worker]}).

%% API
-export([start_link/0]).

%% Supervisor callbacks
-export([init/1]).

%%%===================================================================
%%% API functions
%%%===================================================================
start_link() ->
    case rabbit_api2_config:parse_handlers() of
        {ok, Configuration} ->
            %% io:format("~n~p", [Configuration]),
            supervisor2:start_link(
              {local, ?MODULE}, ?MODULE, [Configuration]
             );
        {error, Reason} ->
            io:format("~n~s", [Reason]),
            {error, binary_to_list(iolist_to_binary(Reason))}
    end.

%%%===================================================================
%%% Supervisor callbacks
%%%===================================================================
init([Configuration]) ->
    SupFlags = {one_for_one, 5 ,2},
    WorkerSupSpec = {rabbit_api2_worker_sup,
                     {rabbit_api2_worker_sup, start_link,[Configuration]},
                     permanent,
                     16#ffffffff,
                     supervisor,
                     [rabbit_api2_worker_sup]},
    CowboySpec = make_cowboy_spec(Configuration),
    {ok, {SupFlags, [WorkerSupSpec, CowboySpec]}}.

%%%===================================================================
%%% Internal functions
%%%===================================================================
make_cowboy_spec(Configuration0)->
    Fun = fun(Name, #{handle_config:=Config0, name:=Name, type:=Type}, AccIn) ->
                  AccIn#{Name => Config0#{name=>Name, type=>Type}}
          end,
    Configuration = maps:fold(Fun, #{}, Configuration0),
    ?COWBOY_SPEC(Configuration).
