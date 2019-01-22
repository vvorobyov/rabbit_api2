%%%-------------------------------------------------------------------
%%% @author Vladislav Vorobyov <vlad@erldev>
%%% @copyright (C) 2018, Vladislav Vorobyov
%%% @doc
%%%
%%% @end
%%% Created : 25 Dec 2018 by Vladislav Vorobyov <vlad@erldev>
%%%-------------------------------------------------------------------
-module(rabbit_api2_dispatcher).

%% API
-export([build_dispatcher/3]).

%%%===================================================================
%%% API
%%%===================================================================

%%--------------------------------------------------------------------
%% @doc
%% @spec
%% @end
%%--------------------------------------------------------------------
build_dispatcher(Prefix, TimeOut, Config)->
    Routes = build_routes(Prefix, TimeOut, Config),
    %% io:format("~n~p~n",[Routes]),
    cowboy_router:compile(Routes).
%%%===================================================================
%%% Internal functions
%%%===================================================================
build_routes(Prefix, TimeOut, Config)->
    Dispatcher = parse_config(Prefix, TimeOut, Config),
    %Notfound = [{"/[...]", rabbit_api2_notfound_h, []}],
    [{'_',Dispatcher}].

parse_config(Prefix, TimeOut, Config)->
    Fun = fun(_Name, Conf, AccIn)->
                  Route = {get_handle(Prefix,Conf),
                           rabbit_api2_h,
                           Conf#{timeout => TimeOut}},
                  [Route|AccIn]
          end,
    maps:fold(Fun, [], Config).

get_handle(Prefix, #{handle:=Handle0})->
    case hd(Handle0) of
        $/ ->
           "/"++Prefix++Handle0;
        _ ->
            "/"++Prefix++"/"++Handle0
        end.
