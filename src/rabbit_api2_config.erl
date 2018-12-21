%%%-------------------------------------------------------------------
%%% @author Vladislav Vorobyov <vlad@erldev>
%%% @copyright (C) 2018, Vladislav Vorobyov
%%% @doc
%%%
%%% @end
%%% Created : 21 Dec 2018 by Vladislav Vorobyov <vlad@erldev>
%%%-------------------------------------------------------------------
-module(rabbit_api2_config).
-include("rabbit_api2.hrl").
%% API
-export([parse/2]).

%%%===================================================================
%%% API
%%%===================================================================
parse(Name,Config)->
    try
        validate(Config),
        parse_current(Name, Config)
    catch
        throw:{error, Reason} ->
            {error, {invalid_handler_configuration, Name, Reason}};
        throw:Reason ->
            {error, {invalid_handler_configuration, Name, Reason}}
    end.
%%%===================================================================
%%% Internal functions
%%%===================================================================

%%%-------------------------------------------------------------------
%%% Parse Functions
%%%-------------------------------------------------------------------
parse_current(Name, _Config) when is_atom(Name) ->
    {ok, #worker{name=Name}};
parse_current(_, _) ->
    throw({handler_name_is_not_atom}).

%%%-------------------------------------------------------------------
%%% Validate Functions
%%%-------------------------------------------------------------------
validate(Config) ->
    validate_proplist(Config),
    validate_duplicates(Config).

validate_proplist(Config) when is_list (Config) ->
    PropsFilterFun = fun ({_, _}) -> false;
                         (_) -> true
                     end,
    case lists:filter(PropsFilterFun, Config) of
        [] -> ok;
        Invalid ->
            throw({invalid_parameters, Invalid})
    end;
validate_proplist(X) ->
    throw({require_list, X}).

validate_duplicates(Config) ->
    case duplicate_keys(Config) of
        [] -> ok;
        Invalid ->
            throw({duplicate_parameters, Invalid})
    end.

duplicate_keys(PropList) when is_list(PropList) ->
    proplists:get_keys(
      lists:foldl(fun (K, L) -> lists:keydelete(K, 1, L) end, PropList,
                  proplists:get_keys(PropList))).
