-module(rabbit_api2_h).
-behavior(cowboy_handler).

-export([init/2,
         info/3,
         variances/2,
         allowed_methods/2,
         is_authorized/2,
         accept_content/2,
         content_types_provided/2,
         forbidden/2,
         content_types_accepted/2]).

init(Req, State) ->
    %% Проработать настройки по аналогии с
    %% rabbit_mgmt_headers:set_common_permission_headers
    {cowboy_rest, Req, State}.
info(Msg, Req, State) ->
    io:format("~nCowboy info: ~p",[Msg]),
    {ok, Req, State}.

variances(Req, Context) ->
    {[<<"accept-encoding">>, <<"origin">>], Req, Context}.

allowed_methods(Req, State=#{methods := Methods})->
    {Methods, Req, State}.

%% Авторизация пользователя
is_authorized(Req, State)->
    case rabbit_api2_utils:is_authorized(Req, State) of
        {true, Username, RMQUser} ->
            {true, Req, State#{username => Username,
                               rmq_user => RMQUser}};
        false ->
            Host = cowboy_req:host(Req),
            WWWAuth = << <<"Basic realm=\"">>/binary,
                         Host/binary,
                         <<"\", charset=\"UTF-8\"">>/binary>>,
            {{false, WWWAuth}, Req, State}
    end.

%% Порверка прав доступа
forbidden(Req,State)->
    {rabbit_api2_utils:is_forbidden(Req, State), Req, State}.

%% предоставляемые типы данных
content_types_provided(Req, State=#{content_type:=ContentType}) ->
    {[{ContentType, accept_content}], Req, State}.

%% возвращаемые типы данных
content_types_accepted(Req, State=#{content_type:=ContentType}) ->
    {[{ContentType, accept_content}], Req, State}.

%% возвращаемый контент
accept_content(Req0 = #{method := Method},
               State = #{content_type := ContentType})->
    Headers = cowboy_req:headers(Req0),
    {ok, ReqBody, Req1} = rabbit_api2_utils:get_body(Req0, State),
    {ok, Status, ResHead, ResBody} =
        rabbit_api2_utils:request(Method, Headers, ReqBody, State),
    Req = cowboy_req:reply(Status, ResHead#{<<"content-type">> => ContentType},
                           ResBody, Req1),
    {ok, Req, State}.
