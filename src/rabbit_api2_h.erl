-module(rabbit_api2_h).
-behavior(cowboy_handler).

-export([init/2,
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

variances(Req, Context) ->
    {[<<"accept-encoding">>, <<"origin">>], Req, Context}.

allowed_methods(Req, State=#{methods := Methods})->
    {Methods, Req, State}.

%% Авторизация пользователя
is_authorized(Req, State)->
    case rabbit_api2_utils:is_authorized(Req, State) of
        {true, Username} ->
            {true, Req, State#{username=>Username}};
        false ->
            Text1 = <<"Basic realm=\"">>,
            Text2 = cowboy_req:host(Req),
            Text3 = <<"\", charset=\"UTF-8\"">>,
            WWWAuth = <<Text1/binary, Text2/binary, Text3/binary>>,
            {{false, WWWAuth}, Req, State}
    end.

%% Порверка прав доступа
forbidden(Req,State)->
    {rabbit_api2_utils:forbidden(Req, State),Req, State}.

%% предоставляемые типы данных
content_types_provided(Req, State=#{content_type:=ContentType}) ->
    {[{ContentType, accept_content}], Req, State}.

%% возвращаемые типы данных
content_types_accepted(Req, State=#{content_type:=ContentType}) ->
    {[{ContentType, accept_content}], Req, State}.

%% возвращаемый контент
accept_content(Req, State)->
    rabbit_api2_utils:accept_content(Req,State).
