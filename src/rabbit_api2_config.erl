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
    {type, Type} = proplists:lookup(type, Config),
    ok = validate_parameter(type,
                            fun valid_allowed_value/1,
                            {Type, [sync, async]}),
    {destination, Dest0} = proplists:lookup(destination, Config),
    {ok,Dest} = parse_destination(Dest0),
    Source = case Type of
                 sync ->
                     Source0 = proplists:get_value(source, Config),
                     parse_source(Source0);
                 async ->
                     undefined
             end,
    Handle = parse_handle(Config),
    {ok, #{name => Name,
           type => Type,
           handle_config => Handle,
           source_config => Source,
           destination_config => Dest}};
parse_current(_, _) ->
    throw({handler_name_is_not_atom}).

parse_source(undefined)->
    throw({error, undefined_source_config_to_sync_handler});
parse_source(SrcConfig)->
    SrcConfig.
parse_handle(Config)->
    {handle, Handle} = proplists:lookup(handle, Config),
    ok = validate_parameter(handle,
                            fun valid_string/1,
                            Handle),
    Methods = proplists:get_value(methods, Config, [post]),
    ok = validate_http_methods(Methods),
    Authorization = proplists:get_value(authorization, Config, rabbitmq_auth),
    ok = validate_authorizations(Authorization),
    ContentType = proplists:get_value(content_type, Config, "application/json"),
    ok = validate_parameter(content_type,
                            fun valid_allowed_value/1,
                           {ContentType,["application/json"]}),
    #{handle => Handle,
      method => Methods,
      auth => Authorization,
      content_type => ContentType}.

parse_destination(DstConfig)->
    validate(DstConfig),
    {uris, URIs} = proplists:lookup(uris, DstConfig),
    ok = validate_parameter('destination.uris',
                            fun valid_ampq_uris/1,
                            URIs),
    {exchange, Exchange} = proplists:lookup(exchange, DstConfig),
    ok = validate_parameter(exchange,
                            fun valid_binary/1,
                            Exchange),
    {routing_key, RoutingKey} = proplists:lookup(routing_key, DstConfig),
    ok = validate_parameter(routing_key,
                            fun valid_binary/1,
                            RoutingKey),
    {ok,#{uris => URIs,
          exchange => Exchange,
          routing_key => RoutingKey}}.


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

validate_authorizations(rabbitmq_auth)->
    ok;
validate_authorizations(Auths) when is_list(Auths) ->
    Fun = fun(Auth)->
                  validate_parameter(
                    authorization,
                    fun valid_string/1,
                    Auth)
          end,
    lists:map(Fun, Auths),
    ok;
validate_authorizations(Other) ->
    throw({error, {requare_list_hashes_or_rabbitmq_auth_atom,
                   {authorization,Other}}}).

validate_http_methods(Methods)
  when is_list(Methods)->
    Fun = fun(Method)->
                  validate_parameter(
                    methods,
                    fun valid_allowed_value/1,
                    {Method, [get, post, put, delete]})
          end,
    lists:map(Fun, Methods),
    ok;
validate_http_methods(Other) ->
    throw({error, {requare_list, {methods, Other}}}).

validate_parameter(Param, Fun, Value) ->
    try
        Fun(Value),
        ok
    catch
        _:{error, Err} ->
            throw({error,{invalid_parameter_value, Param, Err}})
    end.

valid_allowed_value({Value, List}) ->
    case lists:member(Value, List) of
        true ->
            Value;
        false ->
            throw({error, {waiting_for_one_of,Value, List}})
    end.

valid_ampq_uris([])->
    throw({error, list_of_uris_is_empty});
valid_ampq_uris(URIs) when is_list(URIs)->
    Fun = fun (URI) ->
                  case catch(amqp_uri:parse(URI)) of
                      {ok, _} -> ok;
                      Error ->
                          throw(Error)
                  end
          end,
    lists:map(Fun, URIs);
valid_ampq_uris(Other)->
    throw({error, {requare_list, Other}}).

valid_binary(V) when is_binary(V) ->
    V;
valid_binary(NotBin) ->
    throw({error, {require_binary, NotBin}}).

valid_string(V) when is_list(V)->
    case io_lib:printable_unicode_list(V) of
        true -> V;
        false ->  throw({error,{requare_printable_string, V}})
    end;
valid_string(NotList) ->
    throw({error,{requare_printable_string, NotList}}).
