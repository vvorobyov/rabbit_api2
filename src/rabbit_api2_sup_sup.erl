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

%% API
-export([start_link/0]).

%% Supervisor callbacks
-export([init/1]).

%%%===================================================================
%%% API functions
%%%===================================================================
start_link() ->
    case parse_configuration(application:get_env(handlers)) of
        {ok, Configuration} ->
            supervisor2:start_link(
              {local, ?MODULE}, ?MODULE, [Configuration]
             );
        {error, Reason} ->
            {error, Reason}
    end.

%%%===================================================================
%%% Supervisor callbacks
%%%===================================================================
init([Configuration]) ->
    SupFlags = {one_for_one, 5 ,2},
    WorkerSupSpec = {rabbit_api2_sup,
                     {rabbit_api2_sup, start_link,[Configuration]},
                     permanent,
                     16#ffffffff,
                     supervisor,
                     [rabbit_api2_sup]},
    {ok, {SupFlags, [WorkerSupSpec]}}.

%%%===================================================================
%%% Internal functions
%%%===================================================================
parse_configuration(undefined) ->
    {ok, #{}};
parse_configuration({ok, Env}) ->
    parse_configuration(Env, #{}).

parse_configuration([], Acc) ->
    {ok, Acc};
parse_configuration([{Name, Config}| Env], Acc)
  when is_atom(Name) andalso is_list(Config)->
    case maps:is_key(Name, Acc) of
        true  -> {error, {duplicate_handler_definition, Name}};
        false -> case validate_handler_config(Name, Config) of
                     {ok, Handler} ->
                         Acc2 = maps:put(Name, Handler, Acc),
                         parse_configuration(Env, Acc2);
                     Error ->
                         Error
                 end
    end;
parse_configuration( _Other, _Acc) ->
    {error, require_list_of_webshovel_configurations}.

validate_handler_config(Name, Config) ->
    rabbit_api2_config:parse(Name, Config).
