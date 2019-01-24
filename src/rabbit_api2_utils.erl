%%%-------------------------------------------------------------------
%%% @author Vladislav Vorobyov <vlad@erldev>
%%% @copyright (C) 2018, Vladislav Vorobyov
%%% @doc
%%%
%%% @end
%%% Created : 25 Dec 2018 by Vladislav Vorobyov <vlad@erldev>
%%%-------------------------------------------------------------------
-module(rabbit_api2_utils).

%% API
-export([gen_auth_hash/2,
         is_authorized/2,
         is_forbidden/2,
         get_body/2,
         request/4]).
-include_lib("amqp_client/include/amqp_client.hrl").


%%%===================================================================
%%% API
%%%===================================================================

%% Генерация хеша для авторизации средствами плагина
gen_auth_hash(Username, Password)
  when is_list(Username), is_list(Password)->
    Hash = crypto:hash(md5, "RabbitMQ API2 "++Username++":"++Password),
    lists:flatten([io_lib:format("~2.16.0b",[N]) || <<N>> <= Hash]);
gen_auth_hash(Username, Password)
  when is_binary(Username), is_binary(Password) ->
    gen_auth_hash(binary_to_list(Username),binary_to_list(Password));
gen_auth_hash(Username,Password) ->
    throw({error,requare_list_or_binary,{Username,Password}}).

%% Проверка авторизации, возвращает
%% {true, Username} - Пользователь авторизован
%% false - Пользователь не авторизован
is_authorized(Req, #{auth:=rabbitmq_auth})->
    case cowboy_req:parse_header(<<"authorization">>, Req) of
        {basic, Username, Password} ->
            rabbit_auth(Username,Password);
        _ -> false
    end;
is_authorized(Req, #{auth:=HashList}) when is_list(HashList) ->
    case cowboy_req:parse_header(<<"authorization">>, Req) of
        {basic, Username, Password} ->
            api2_auth(Username, Password, HashList);
        _ -> false
    end.

%% Проверка наличия досупа
%% true - доступ запрещен
%% false - доступ разрешен
is_forbidden(Req,#{auth := rabbitmq_auth,
                   rmq_user := User,
                   dst := {DstVHost, Exchange},
                   src := SrcRes0}) ->
    Socket = authz_socket_info(Req),
    PublishAccess = check_publish_access(User, Socket,
                                         DstVHost, Exchange),
    ConsumeAccess = case SrcRes0 of
                        undefined -> true;
                        {SrcVHost, Queue} ->
                            check_consume_access(User, Socket,
                                                 SrcVHost, Queue)
                    end,
    case PublishAccess andalso ConsumeAccess of
        true -> false;
        false -> true
    end;
is_forbidden(_Req,_State)->
    false.

%% Получение тела запроса
%% {ok, Body, NewReq}
get_body(Req=#{method:=<<"GET">>}, _)->
    PListQs = cowboy_req:parse_qs(Req),
    Keys = proplists:get_keys(PListQs),
    UKeys0 = lists:foldl(fun(Item,Acc)->
                                 case lists:member(Item,Acc) of
                                     true -> Acc;
                                     false  -> [Item|Acc]
                                 end
                         end, [], Keys),
    UKeys = [binary_to_atom(K,unicode)|| K <- UKeys0],
    QsMap = cowboy_req:match_qs(UKeys, Req),
    {ok, jsx:encode(QsMap), Req};
get_body(Req, #{max_body_len:=Len}) ->
    {ok, _, _} = cowboy_req:read_body(Req, #{length=>Len}).
%% Запрос
request(Method, Headers0, Body, State = #{name:=Name,
                                          responses:=Responses,
                                          content_type:=ContentType,
                                          timeout:=TimeOut
                                          })->
    try
        validate_body(ContentType, Body),
        {ok, Headers} = make_amqp_headers(Headers0),
        {ok, Props} = make_amqp_props(Method, Headers, State),
        AMQPMsg = #amqp_msg{props = Props, payload = Body},
        Response = rabbit_api2_worker:request({global, Name}, AMQPMsg,
                                              TimeOut-500),
        case Response of
            {publish_error, Reasone} ->
                io:format("~nError reasone ~p",[Reasone]),
                get_response(publish_error_response, Responses);
            {ok, publish_ok} ->
                get_response(async_response, Responses);
            {ok, Msg} ->
                parse_amqp(Msg)
        end
    catch
        _:{timeout, _}    ->
            get_response(timeout_response, Responses);
        _: not_valid_body ->
            get_response(bad_request_response, Responses);
        _:Reasone2 ->
            io:format("~n Error reasone ~p",[Reasone2]),
            get_response(internal_error_response, Responses)
    end.

%%%===================================================================
%%% Internal functions
%%%===================================================================
%%--------------------------------------------------------------------
%% Request functions
%%--------------------------------------------------------------------
validate_body(<<"application/json">>, Body)->
    case jsx:is_json(Body) of
        true ->
            ok;
        false ->
            throw(not_valid_body)
    end.

get_response(Key, Responses = #{}) ->
    {Status, Body} = maps:get(Key, Responses),
    {ok, Status, #{}, Body}.

parse_amqp(#amqp_msg{props = #'P_basic'{headers = _AmqpHeaders,
                                        type=Type},
                     payload = Body})->
    Headers = #{},
    Status = get_http_status(Type),
    {ok, Status, Headers, Body}.

get_http_status(Type) when is_integer(Type), Type >= 100, Type =<599 ->
    Type;
get_http_status(Type) when is_binary(Type) ->
    case string:to_lower(Type) of
        <<"ok">> ->
            200;
        <<"error">> ->
            400;
        <<>> ->
            200
    end;
get_http_status(_) ->
    200.

make_amqp_props(Method, Headers, #{content_type := ContentType,
                                   properties   := Properties,
                                   username     := UserName,
                                   timeout      := TimeOut,
                                   timestamp_format := TimestampFormat})->
    DeliveryMode = maps:get(delivery_mode, Properties),
    AppID = case maps:get(app_id, Properties) of
                none -> undefined;
                V -> V
            end,
    UserID = case maps:get(user_id, Properties) of
                 none -> UserName;
                 Value -> Value
             end,
    MessageId =  get_message_id(),
    Timestamp = get_unix_time(TimestampFormat),
    Expiration = case maps:get(expiration, Properties) of
                     infinity -> undefined;
                     timeout-> get_expiration(Timestamp, TimeOut)
                 end,
    {ok, #'P_basic'{content_type = ContentType,
                    headers = Headers,
                    delivery_mode = DeliveryMode,
                    expiration = Expiration,
                    message_id = MessageId,
                    timestamp = Timestamp,
                    type = Method,
                    user_id = UserID,
                    app_id = AppID
                   }}.

make_amqp_headers(Headers)->
    ClearHeaders = maps:without([<<"cookie">>,
                                 <<"connection">>,
                                 <<"authorization">>],Headers),
    Fun = fun(K,V,Acc)->
                  [{K,longstr,V}|Acc]
          end,
    ResultHeaders = maps:fold(Fun,[], ClearHeaders),
    {ok, [{<<"x-system">>,
           longstr,
           <<"RabbitMQ APIv2.0 Plugin">>}|ResultHeaders]}.


get_expiration(Timestamp, TimeOut)->
    integer_to_binary(Timestamp+TimeOut div 1000).

get_message_id()->
    Ref = ref_to_list(erlang:make_ref()),
    Hash = crypto:hash(md5, "RabbitMQ API2 "++Ref),
    ListHash =lists:flatten([io_lib:format("~2.16.0b",[N]) || <<N>> <= Hash]),
    list_to_binary(ListHash).

get_unix_time(Format)->
    case Format of
        utc ->
            os:system_time(second);
        local ->
            calendar:datetime_to_gregorian_seconds(
              calendar:local_time()) - 62167219200
    end.

%%--------------------------------------------------------------------
%% Check access functions
%%--------------------------------------------------------------------

authz_socket_info(ReqData) ->
    Host = cowboy_req:host(ReqData),
    Port = cowboy_req:port(ReqData),
    Peer = cowboy_req:peer(ReqData),
    #authz_socket_info{sockname = {Host, Port},
                       peername = Peer}.

check_publish_access(User, Socket, VHost, Exchange)->
    check_vhost_access(User, VHost, Socket) andalso
        check_resource_access(User, VHost, Exchange, exchange).

check_consume_access(User, Socket, VHost, Queue)->
    check_vhost_access(User, VHost, Socket) andalso
        check_resource_access(User, VHost, Queue, queue).

check_vhost_access(User, VHost, Socket)->
    case catch rabbit_access_control:check_vhost_access(
                 User, VHost, Socket) of
        ok -> true;
        _  -> false
    end.

check_resource_access(User, VHost, ResName, ResType)
  when ResType=:=queue; ResType=:=exchange ->
    Res = #resource{virtual_host = VHost,
                    kind         = ResType,
                    name         = ResName},
    OperType = case ResType of
                   queue    -> read;
                   exchange -> write
               end,
    case catch rabbit_access_control:check_resource_access(
                 User, Res, OperType) of
        ok -> true;
        _  -> false
    end.

%%--------------------------------------------------------------------
%% Check authorization functions
%%--------------------------------------------------------------------
rabbit_auth(Username, Password)->
    RMQAuth = rabbit_access_control:check_user_pass_login(Username,
                                                          Password),
    case RMQAuth of
        {ok, User} -> {true, Username, User};
        _          -> false
    end.

api2_auth(Username, Password, HashList)->
    case lists:member(gen_auth_hash(Username,Password),HashList) of
        true  -> {true, Username, none};
        false -> false
    end.


