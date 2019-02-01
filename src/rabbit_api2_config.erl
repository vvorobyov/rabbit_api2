%%%-------------------------------------------------------------------
%%% @author Vladislav Vorobyov <vlad@erldev>
%%% @copyright (C) 2018, Vladislav Vorobyov
%%% @doc
%%%
%%% @end
%%% Created : 21 Dec 2018 by Vladislav Vorobyov <vlad@erldev>
%%%-------------------------------------------------------------------
-module(rabbit_api2_config).
%% API
-export([parse_handlers/0,
	 parse_handler/2,
         get_env_value/2,
         get_env_timeout/1]).

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

get_env_timeout(Name) when Name=:=tcp_config;Name=:=ssl_config->
    try
        Config = proplists:get_value(Name,application:get_all_env(), []),
        CowboyOpts = proplists:get_value(cowboy_opts, Config, []),
        Timeout = lists:min([proplists:get_value(idle_timeout, CowboyOpts),
                             proplists:get_value(inactivity_timeout,
                                                 CowboyOpts)]),
        case Timeout of
            Value when is_integer(Value) ->
                Value;
            _ -> 60000
        end
    catch
        _:_ ->
            60000
    end.

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

parse_handler(Name0, Config) when is_binary(Name0)->
    Name=erlang:binary_to_atom(Name0, unicode),
    try
	parse_handler(Name, Config)
    catch
	throw:{error, Reason} ->
	    throw({error, Reason, []})
    end;
parse_handler(Name, Config) when is_atom(Name) ->
    Handle = get_value(handle, string, Config),
    Methods = get_value(methods, {list,atom}, Config),
    Authorization = get_value(authorization, {list, string}, Config),
    Type = get_value(type, atom, Config),
    AsyncResponse = get_value(async_response, response, Config),
    PubErrResponse = get_value(publish_error_response, response, Config),
    IntErrResponse = get_value(internal_error_response, response, Config),
    TimeOutResponse = get_value(timeout_response, response, Config),
    BadReqResponse = get_value(bad_request_response, response, Config),
    Responses = #{async_response => AsyncResponse,
                  publish_error_response => PubErrResponse,
                  internal_error_response => IntErrResponse,
                  timeout_response => TimeOutResponse,
                  bad_request_response => BadReqResponse},
    TimestampFormat = get_value(timestamp_format, atom, Config),
    ContentType = get_value(content_type, binary, Config),
    MaxBodyLen = get_value(max_body_length, not_neg_integer, Config),
    Props0 = get_value(properties, proplist, Config),
    {ok, Props} = parse_properties(Props0),
    ReconnectDelay = get_value(reconnect_delay, not_neg_integer, Config),
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
    Handler = #{handle => Handle,
                methods => Methods,
                auth => Authorization,
                responses => Responses,
                timestamp_format => TimestampFormat,
                max_body_length => MaxBodyLen,
                properties => Props,
                dst => {DstVHost, Exchange},
                src => {SrcVHost, Queue},
                content_type => ContentType},
    {ok, #{name => Name,
           type => Type,
           reconnect_delay => ReconnectDelay,
           handle_config => Handler,
           src_config => Source,
           dst_config => Dest}};
parse_handler(_, _) ->
    throw({error, "Handler name is not atom"}).


parse_destination(DstConfig)->
    VHost = get_value(vhost, binary, "destination.", DstConfig),
    validate_vhost(VHost),
    Exchange = get_value(exchange, binary, "destination.", DstConfig),
    RoutingKey = get_value(routing_key, binary, "destination.", DstConfig),
    DeclareFun=get_declarations(DstConfig),
    {ok,#{vhost => VHost,
          exchange => Exchange,
          routing_key => RoutingKey,
          decl_fun => DeclareFun}}.

parse_source(SrcConfig)->
    VHost = get_value(vhost, not_empty_binary, "source.", SrcConfig),
    validate_vhost(VHost),
    Queue = get_value(queue, not_empty_binary, "source.", SrcConfig),
    PrefetchCount =
        get_value(prefetch_count, not_neg_integer, "source.", SrcConfig),
    DeclareFun=get_declarations(SrcConfig),
    {ok, #{vhost => VHost,
           queue => Queue,
           prefetch_count => PrefetchCount,
           decl_fun => DeclareFun}}.

get_declarations(Config)->
    Declare0 = get_value(declarations, proplist, "destination.", Config,[]),
    Declare1 = parse_declaration({Declare0,[]}),
    fun (none)->ok;
        (Ch) ->
            [begin
                 amqp_channel:call(Ch, M)
             end || M <- lists:reverse(Declare1)]
    end.

parse_declaration({[], Acc}) ->
    Acc;
parse_declaration({[{Method, Props} | Rest], Acc}) when is_list(Props) ->
    FieldNames = try rabbit_framing_amqp_0_9_1:method_fieldnames(Method)
                 catch exit:Reason -> throw(Reason)
                 end,
    case proplists:get_keys(Props) -- FieldNames of
        []            -> ok;
        UnknownFields -> throw({unknown_fields, Method, UnknownFields})
    end,
    {Res, _Idx} = lists:foldl(
                    fun (K, {R, Idx}) ->
                            NewR = case proplists:get_value(K, Props) of
                                       undefined -> R;
                                       V         -> setelement(Idx, R, V)
                                   end,
                            {NewR, Idx + 1}
                    end, {rabbit_framing_amqp_0_9_1:method_record(Method), 2},
                    FieldNames),
    parse_declaration({Rest, [Res | Acc]});
parse_declaration({[{Method, Props} | _Rest], _Acc}) ->
    throw({expected_method_field_list, Method, Props});
parse_declaration({[Method | Rest], Acc}) ->
    parse_declaration({[{Method, []} | Rest], Acc}).

parse_properties(Props)->
    DeliveryMode = get_value(delivery_mode, not_neg_integer, Props),
    UserID = get_value(user_id, not_empty_binary, Props),
    AppID = get_value(app_id, not_empty_binary, Props),
    Expiration = get_value(expiration, atom, Props),
    {ok, #{delivery_mode=>DeliveryMode,
           user_id=>UserID,
           app_id=>AppID,
           expiration=>Expiration}}.



%%%-------------------------------------------------------------------
%%% Get Functions
%%%-------------------------------------------------------------------
get_value(Name, Type, Config)->
    get_value(Name, Type, "", Config).

get_value(Name, Type, Prefix, Config)->
    Default = get_default(Name),
    get_value(Name, Type, Prefix, Config, Default).

get_value(Name, Type, Prefix, Config, Default)->
    Allowed = get_allowed(Name),
    Value0 = case {Default, proplists:get_value(Name, Config)} of
                {undefined,undefined} ->
                    throw({error,
                           io_lib:format("Property '~s~p' not found.",
                                         [Prefix,Name])});
                {_, undefined} -> undefined;
                {_, Val} -> Val
            end,
    Value =
        case {Default, Value0} of
            {_, undefined} ->
                Default;
            {_,_} ->
                check_type(Prefix,Name, Value0, Type),
                check_allowed(Prefix, Name, Value0, Type, Allowed),
                Value0
        end,
    convert(Name, Value).

get_default(Name)->
    {ok, DefValues} = application:get_env(rabbitmq_api2, default),
    proplists:get_value(Name, DefValues).

get_allowed(Name)->
    {ok, AllowedValues} = application:get_env(rabbitmq_api2, allowed),
    proplists:get_value(Name, AllowedValues).
%%%-------------------------------------------------------------------
%%% Conver Functions
%%%-------------------------------------------------------------------
convert(Name, Value)->
    case Name of
        methods -> convert_methods(Value);
        authorization -> convert_authorization(Value);
        _ -> Value
    end.

convert_authorization(none)->
    rabbitmq_auth;
convert_authorization(V) ->
    V.

convert_methods(Methods)when is_list(Methods)->
    Fun = fun(Method, AccIn)->
                  String = atom_to_list(Method),
                  Upper = string:uppercase(String),
                  Binary = list_to_binary(Upper),
                  [Binary|AccIn]
          end,
    lists:foldl(Fun,[],Methods).

%%%-------------------------------------------------------------------
%%% Validate Functions
%%%-------------------------------------------------------------------
get_validate_fun({list, Type})->
    get_validate_fun(Type);
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
        not_neg_integer -> fun is_not_neg_integer/1;
        response -> fun is_response/1;
        _ -> false

    end.
check_type(Prefix, Name, Value, Type)->
    case catch validate_type(Value, Type) of
        true -> ok;
        false ->
            throw({error,
                   io_lib:format(
                     "Property '~s~p' is not '~p'.",
                     [Prefix,Name,Type])});
        {error, Reason} ->
            throw({error,
                   io_lib:format(
                     "Property '~s~p' is not valid '~p'. Reason: ~s.",
                     [Prefix,Name,Type, Reason])})
    end.

validate_type(undefined, _)->
    false;
validate_type([], {list, _Type})->
    false;
validate_type(Values, {list, Type}) when is_list(Values)->
    ValidValues = lists:filter(get_validate_fun(Type),Values),
    Values=:=ValidValues;
validate_type(Value, Type) when is_atom(Type) ->
    Fun = get_validate_fun(Type),
    Fun(Value);
validate_type(_,_) ->
    false.

check_allowed(Prefix, Name, Value, Type,Allowed)->
    case validate_allowed(Value, Type, Allowed) of
        true -> ok;
        false ->
            throw({error,
                   io_lib:format(
                     "The '~s~p' property has an incorrect value. "
                     "Expected one of ~p.", [Prefix,Name,Allowed])})
    end.

validate_allowed(_Value, _Type, undefined)->
    true;
validate_allowed(Values, {list, _Type}, Allowed)
  when is_list(Values) ->
    AllowedValues = lists:filter(
                      fun(Value)-> lists:member(Value, Allowed) end,
                      Values),
    Values=:=AllowedValues;
validate_allowed(Value, Type, Allowed) when is_atom(Type) ->
    lists:member(Value, Allowed);
validate_allowed(_,_,_) ->
    false.

validate_vhost(VHost)->
    case rabbit_vhost:exists(VHost) of
        true ->
            ok;
        false -> throw({error,
                        io_lib:format("VHost '~s' not exists",[VHost])})
    end.
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
    case validate_type(Value, {list, string}) of
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
                          "Expected 'rabbitmq_auth' or list of string(-s)"
                          " with hashes. Use ~p for generate it",
                          ["rabbitmqctl eval 'rabbitmq_api2:gen_auth_hash"
                           "(USERNAME, PASSWORD).'"])})
    end;
is_auth2(_) ->
    throw({error,
           io_lib:format(
             "Expected 'rabbitmq_auth' or list of string(-s)"
             " with hashes. Use ~p for generate it",
             ["rabbitmqctl eval 'rabbitmq_api2:gen_auth_hash"
              "(USERNAME, PASSWORD).'"])}).

is_response({Status, Body})
  when is_integer(Status),
       is_binary(Body) ->
    true;
is_response(_) ->
    false.

is_not_empty_binary(<<>>)->
    false;
is_not_empty_binary(V) ->
    erlang:is_binary(V).

is_not_neg_integer(V) when is_integer(V), V >=0 ->
    true;
is_not_neg_integer(_) ->
    false.
