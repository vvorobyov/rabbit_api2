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
-export([gen_hash/2, is_authorized/2, forbidden/2, accept_content/2]).
-include_lib("amqp_client/include/amqp_client.hrl").
%%%===================================================================
%%% API
%%%===================================================================

%%--------------------------------------------------------------------
%% @doc
%% @spec
%% @end
%%--------------------------------------------------------------------
gen_hash(Username, Password)
  when is_list(Username), is_list(Password)->
    Hash = crypto:hash(md5, "RabbitMQ API2 "++Username++":"++Password),
    lists:flatten([io_lib:format("~2.16.0b",[N]) || <<N>> <= Hash]);
gen_hash(Username, Password)
  when is_binary(Username), is_binary(Password) ->
    gen_hash(binary_to_list(Username),binary_to_list(Password));
gen_hash(Username,Password) ->
    throw({error,requare_list_or_binary,{Username,Password}}).

is_authorized(Req, State=#{auth:=Auth})->
    case cowboy_req:parse_header(<<"authorization">>, Req) of
        {basic, Username, Password} ->
            case Auth of
                rabbitmq_auth ->
                    rabbit_auth(Username,Password, Req, State);
                List when is_list(List) ->
                    api2_auth(Username, Password, Req, State)
            end;
        _ -> {{false,<<"Basic realm=\"cowboy\"">>}, Req, State}
    end.
forbidden(Req,State=#{auth:=rabbitmq_auth,
                      username :=User,
                      dst := {DstVHost, Exchange},
                      src := SrcRes0}) ->
    Socket = authz_socket_info(Req),
    DstVHostAccess = (catch rabbit_access_control:check_vhost_access(
                              User, DstVHost, Socket)),
    DstRes = #resource{virtual_host=DstVHost,
                       kind = exchange,
                       name=Exchange},
    DstAccess = (catch rabbit_access_control:check_resource_access(
                         User, DstRes,write)),
    {SrcVHostAccess, SrcAccess} =
        case SrcRes0 of
            undefined -> {ok, ok};
            {SrcVHost, Queue} ->
                SrcRes = #resource{virtual_host=SrcVHost,
                                   kind = queue,
                                   name=Queue},
                {(catch rabbit_access_control:check_vhost_access(
                          User, SrcVHost, Socket)),
                 (catch rabbit_access_control:check_resource_access(
                          User, SrcRes, read))}
        end,
    case {DstVHostAccess, DstAccess, SrcVHostAccess, SrcAccess} of
        {ok, ok, ok, ok} -> {false, Req, State};
        _ ->  {true, Req, State}
    end;
forbidden(Req,State)->
    {false, Req, State}.

accept_content(Req0, State=#{name:=Name,
                             content_type:=ContentType})->
    {AMQPMsg, Req1} = json_to_amqp(Req0,State),
    {_,Response} = rabbit_api2_worker:request({global,Name}, AMQPMsg),
    Req =
        %% case {Method,jsx:is_json(Body)} of
        %%     {<<"GET">>, false} ->
        %%         cowboy_req:reply(400,#{<<"content-type">> =>
        %%                                    ContentType},
        %%                          "{\"error\":\"not_valid_request\","
        %%                          "\"description\":\"Request is not valid\"}",
        %%                          Req1);
        %%     {_, false} ->
        %%         cowboy_req:reply(400,#{<<"content-type">> =>
        %%                                    ContentType},
        %%                          "{\"error\":\"not_valid_json\","
        %%                          "\"description\":\"Request is not valid JSON\"}",
        %%                          Req1);
        %%     {_, true} ->
        cowboy_req:reply(200,
                         #{<<"content-type">> =>ContentType},
                         binary_to_list(Response),
                         Req1),
        %% end,
    {ok, Req, State}.
%%%===================================================================
%%% Internal functions
%%%===================================================================
json_to_amqp(Req0,State=#{content_type:=ContentType,
                         properties:=Properties})->
    {ok, UserName} = get_user_name(Req0),
    {ok, Headers} = get_headers(Req0),
    io:format("~p~n",[Headers]),
    {ok, Body, Req} = get_body(Req0, State),
    DeliveryMode = maps:get(delivery_mode, Properties),
    AppID = case maps:get(app_id, Properties) of
                none -> undefined;
                V -> V
            end,
    UserID = case maps:get(user_id, Properties) of
                 none -> UserName;
                 Value -> Value
             end,
    Props = #'P_basic'{content_type = ContentType,
                       headers = Headers,
                       delivery_mode = DeliveryMode,
                       expiration = get_expiration(),
                       message_id = get_message_id(),
                       timestamp = get_unix_time(),
                       type = cowboy_req:method(Req0),
                       user_id = UserID,
                       app_id = AppID
                      },
    {#amqp_msg{props = Props, payload = Body}, Req}.

get_expiration()->
    undefined.

get_message_id()->
    Ref = ref_to_list(erlang:make_ref()),
    Hash = crypto:hash(md5, "RabbitMQ API2 "++Ref),
    ListHash =lists:flatten([io_lib:format("~2.16.0b",[N]) || <<N>> <= Hash]),
    list_to_binary(ListHash).

get_unix_time()->
    os:system_time(second).

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

get_user_name(Req)->
    {basic, UserName, _} = cowboy_req:parse_header(<<"authorization">>, Req),
    {ok, UserName}.

get_headers(Req)->
    AllHeaders = cowboy_req:headers(Req),
    ClearHeaders = maps:without([<<"cookie">>,
                                 <<"connection">>,
                                 <<"authorization">>],AllHeaders),
    Fun = fun(K,V,Acc)->
                  [{K,longstr,V}|Acc]
          end,
    ResultHeaders = maps:fold(Fun,[], ClearHeaders),
    {ok, [{<<"x-system">>,longstr,<<"RabbitMQ APIv2.0 Plugin">>}|ResultHeaders]}.

rabbit_auth(Username,Password, Req, State)->
    RMQAuth = rabbit_access_control:check_user_pass_login(Username,Password),
    case RMQAuth of
        {ok, User} ->
            {true, Req, State#{username =>User}};
         _ ->
            {{false,<<"Basic realm=\"cowboy\"">>}, Req, State}
        end.

api2_auth(Username, Password, Req, State=#{auth:=Auth})->
    case lists:member(
           rabbit_api2_utils:gen_hash(Username,Password),
           Auth) of
        true ->
            {true, Req, State#{username=>Username}};
        false -> {{false,<<"Basic realm=\"cowboy\"">> }, Req, State}
    end.

authz_socket_info(ReqData) ->
    Host = cowboy_req:host(ReqData),
    Port = cowboy_req:port(ReqData),
    Peer = cowboy_req:peer(ReqData),
    #authz_socket_info{ sockname = {Host, Port},
                        peername = Peer}.
