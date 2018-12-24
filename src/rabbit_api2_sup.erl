-module(rabbit_api2_sup).
-behaviour(supervisor2).
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
    supervisor2:start_link({local, ?MODULE}, ?MODULE, Configuration).

%%%===================================================================
%%% Supervisor callbacks
%%%===================================================================
init(Configuration) ->
    Len = maps:size(Configuration),
    SupFlags = {one_for_one, Len*2,2},
    WorkerSpecs = make_child_specs(Configuration),
    ChildSpecs = WorkerSpecs,
	{ok, {SupFlags, ChildSpecs}}.

%%%===================================================================
%%% Internal functions
%%%===================================================================
make_child_specs(Configuration)->
    Fun = fun(WSName, WSConfig, AccIn) ->
                  ChildSpec = ?CHILD_SPEC(WSName, WSConfig) ,
                  [ChildSpec|AccIn]
          end,
    maps:fold(Fun, [], Configuration).

%% parse_configuration(undefined) ->
%%     {ok, #{}};
%% parse_configuration({ok, Env}) ->
%%     parse_configuration(Env, #{}).

%% parse_configuration([], Acc) ->
%%     {ok, Acc};
%% parse_configuration([{Name, Config}| Env], Acc)
%%   when is_atom(Name) andalso is_list(Config)->
%%     case maps:is_key(Name, Acc) of
%%         true  -> {error, {duplicate_handler_definition, Name}};
%%         false -> case validate_handler_config(Name, Config) of
%%                      {ok, Handler} ->
%%                          Acc2 = maps:put(Name, Handler, Acc),
%%                          parse_configuration(Env, Acc2);
%%                      Error ->
%%                          Error
%%                  end
%%     end;
%% parse_configuration( _Other, _Acc) ->
%%     {error, require_list_of_webshovel_configurations}.

%% validate_handler_config(Name, Config) ->
%%     rabbit_api2_config:parse(Name, Config).
