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
parse_current(Name, Config) when is_atom(Name) ->
    {type, Type0} = proplists:lookup(type, Config),
    Type = validate_parameter(type,
                              fun validate_allowed_value/1,
                              {Type0, [sync, async]}),
    Source = case Type of
                 sync ->
                     Source0 = proplists:get_value(source, Config),
                     parse_source(Source0);
                 async ->
                     undefined
             end,
    {ok, #worker{name=Name,
                 src_config=Source}};
parse_current(_, _) ->
    throw({handler_name_is_not_atom}).

parse_source(_SrcConfig)->
    io:format("~n~p~n",[_SrcConfig]),
    none.
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

validate_parameter(Param, Fun, Value) ->
    try
        Fun(Value)
    catch
        _:{error, Err} ->
            throw({error,{invalid_parameter_value, Param, Err}})
    end.

validate_allowed_value({Value, List}) ->
    case lists:member(Value, List) of
        true ->
            Value;
        false ->
            throw({error, {waiting_for_one_of,List}})
    end.
