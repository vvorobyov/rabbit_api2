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
-export([parse_handlers/0, get_env_value/2]).

%%%===================================================================
%%% API
%%%===================================================================
parse_handlers()->
    try
        Handlers0 = get_env_value(handlers, proplist),
        parse_handlers(Handlers0, #{})
    catch
        throw:{error,Reason}->
            {error, io_lib:format("Error configuration. ~s",[Reason])};
        throw:Reason ->
            {error, io_lib:format("~n~p",[Reason])}
    end.


get_env_value(Name, Type)->
    get_value(Name, Type, application:get_all_env()).
%%%===================================================================
%%% Internal functions
%%%===================================================================

%%%-------------------------------------------------------------------
%%% Parse Functions
%%%-------------------------------------------------------------------
parse_handlers([], Acc) ->
    {ok, Acc};
parse_handlers(Handlers=[{Name, _}| Rest], Acc)->
    try
        Config = get_value(Name, proplist, Handlers),
        {ok, Handler} = parse_handler(Name, Config),
        Acc2 = maps:put(Name, Handler, Acc),
        parse_handlers(Rest, Acc2)
    catch
        throw:{error, Reason} ->
            throw({error,
                   io_lib:format("Invalid handler '~p' configuration. ~s",
                                 [Name,Reason])})
    end.

parse_handler(Name, Config) when is_atom(Name) ->
    Type = get_value(type, atom, Config),
    Dest0 = get_value(destination, proplist, Config),
    {ok,Dest} = {ok,#{vhost := DstVHost,
                 exchange:= Exchange}} = parse_destination(Dest0),
    {ok, Source} =
        {ok,#{ vhost :=SrcVHost,queue:=Queue}} =
        case Type of
            sync ->
                Source0 = get_value(source, proplist, Config),
                parse_source(Source0);
            async ->
                {ok, #{vhost=>none, queue=>none}}
        end,
    {ok, Handle} = parse_handle(Config),
    {ok, #{name => Name,
           type => Type,
           handle_config => Handle#{dst =>{DstVHost, Exchange},
                                    src =>{SrcVHost, Queue}},
           source_config => Source,
           destination_config => Dest}};
parse_handler(_, _) ->
    throw({error, "Handler name is not atom"}).


parse_destination(DstConfig)->
    VHost = get_value(vhost, binary, "destination.", DstConfig),
    Exchange = get_value(exchange, binary, "destination.", DstConfig),
    RoutingKey = get_value(routing_key, binary, "destination.", DstConfig),
    {ok,#{vhost => VHost,
          exchange => Exchange,
          routing_key => RoutingKey}}.

parse_source(SrcConfig)->
    VHost = get_value(vhost, not_empty_binary, "source.", SrcConfig),
    Queue = get_value(queue, not_empty_binary, "source.", SrcConfig),
    {ok, #{vhost => VHost,
           queue => Queue}}.

parse_handle(Config)->
    Handle = get_value(handle, string, Config),
    Methods = get_value(methods, atom, Config),
    Authorization = get_value(authorization, authorization, Config),
    ContentType = get_value(content_type, binary, Config),
    {ok, #{handle => Handle,
           methods => Methods,
           auth => Authorization,
           content_type => ContentType}}.


%%%-------------------------------------------------------------------
%%% Get Functions
%%%-------------------------------------------------------------------
get_value(Name, Type, Config)->
    get_value(Name, Type, "", Config).

get_value(Name, Type, Prefix, Config)->
    Default = get_default(Name),
    Allowed = get_allowed(Name),
    case proplists:get_value(Name, Config, Default) of
        undefined ->
            throw({error,
                   io_lib:format("Property '~s~p' not found.",[Prefix,Name])});
        Value ->
            case catch validate_type(Value, Type) of
                true -> ok;
                false ->
                    throw({error,
                           io_lib:format(
                             "Property '~s~p' is not '~p'.",[Prefix,Name,Type])});
                {error, Reason} ->
                    throw({error,
                           io_lib:format(
                             "Property '~s~p' is not valid '~p'. Reason: ~s.",
                             [Prefix,Name,Type, Reason])})
            end,
            case validate_allowed(Value, Type, Allowed) of
                true -> ok;
                false ->
                    throw({error,
                           io_lib:format(
                             "The '~s~p' property has an incorrect value. "
                             "Expected one of ~p.", [Prefix,Name,Allowed])})
            end,
            convert(Name, Value)
    end.

get_default(Name)->
    {ok, DefValues} = application:get_env(default),
    proplists:get_value(Name, DefValues).

get_allowed(Name)->
    {ok, AllowedValues} = application:get_env(allowed),
    proplists:get_value(Name, AllowedValues).
%%%-------------------------------------------------------------------
%%% Conver Functions
%%%-------------------------------------------------------------------
convert(Name, Value)->
    case Name of
        methods -> convert_methods(Value);
        _ -> Value
    end.

convert_methods(Methods)when is_list(Methods)->
    Fun = fun(Method, AccIn)->
                  String = atom_to_list(Method),
                  Upper = string:uppercase(String),
                  Binary = list_to_binary(Upper),
                  [Binary|AccIn]
          end,
    lists:foldl(Fun,[],Methods);
convert_methods(Method) ->
    convert_methods([Method]).

%%%-------------------------------------------------------------------
%%% Validate Functions
%%%-------------------------------------------------------------------
get_validate_fun(Type)->
    case Type of
        proplist ->
            fun is_proplist/1;
        atom ->
            fun erlang:is_atom/1;
        binary -> fun erlang:is_binary/1;
        not_empty_binary -> fun is_not_empty_binary/1;
        string -> fun is_string/1;
        authorization -> fun is_auth/1;
        _ -> false

    end.

validate_type(undefined, _)->
    false;
validate_type([], Type)
  when Type=/=string, Type=/=proplist,
       Type=/=authorization ->
    false;
validate_type(Values, Type)
  when is_list(Values), Type=/=string, Type=/=proplist,
       Type=/=authorization->
    ValidValues = lists:filter(get_validate_fun(Type),Values),
    Values=:=ValidValues;
validate_type(Value, Type) ->
    Fun = get_validate_fun(Type),
    Fun(Value).

validate_allowed(_Value, _Type, undefined)->
    true;
validate_allowed(Values, Type, Allowed)
  when is_list(Values), Type=/=string->
    AllowedValues = lists:filter(
                      fun(Value)-> lists:member(Value, Allowed) end,
                      Values),
    Values=:=AllowedValues;
validate_allowed(Value, _Type, Allowed) ->
    lists:member(Value, Allowed).

%%%-------------------------------------------------------------------
%%% Validate types Functions
%%%-------------------------------------------------------------------

is_proplist(Config) when is_list(Config) ->
    validate_proplist(Config),
    validate_duplicates(Config),
    true;
is_proplist(_NotList) ->
    false.

validate_proplist(Config)->
    PropsFilterFun = fun ({_, _}) -> false;
                         (_) -> true
                     end,
    case lists:filter(PropsFilterFun, Config) of
        [] -> ok;
        Invalid ->
            throw({error, io_lib:format("invalid parameters ~p", [Invalid])})
    end.

validate_duplicates(Config) ->
    case duplicate_keys(Config) of
        [] -> ok;
        Invalid ->
            throw({error, io_lib:format("duplicate parameters ~p", [Invalid])})
    end.

duplicate_keys(PropList) when is_list(PropList) ->
    proplists:get_keys(
      lists:foldl(fun (K, L) -> lists:keydelete(K, 1, L) end, PropList,
                  proplists:get_keys(PropList))).


is_string(V) when is_list(V)->
    io_lib:printable_unicode_list(V);
is_string(_) ->
    false.

is_auth(Value)->
    case validate_type(Value, string) of
        true -> true;
        false -> is_auth2(Value)
    end.

is_auth2(rabbitmq_auth)->
    true;
is_auth2([])->
    true;
is_auth2([Value|Rest])->
    io:format("~p ~p~n",[Value, Rest]),
    case validate_type(Value, string) of
        true -> is_auth(Rest);
        false -> throw({error,
                        io_lib:format(
                        "Expected 'rabbitmq_auth' or string(-s) with hashes. "
                        "Use ~p for generate it",
                        ["rabbitmqctl eval 'rabbitmq_api2:gen_hash"
                         "(USERNAME, PASSWORD).'"])})
    end;
is_auth2(_) ->
    throw({error,
           io_lib:format(
             "Expected 'rabbitmq_auth' or string(-s) with hashes. "
             "Use ~p for generate it",
             ["rabbitmqctl eval 'rabbitmq_api2:gen_hash"
              "(USERNAME, PASSWORD).'"])}).

is_not_empty_binary(<<>>)->
    false;
is_not_empty_binary(V) ->
    erlang:is_binary(V).
