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

is_authorized(Req, State)->
    rabbit_api2_utils:is_authorized(Req, State).
forbidden(Req,State)->
    rabbit_api2_utils:forbidden(Req, State).

%% предоставляемые типы данных
content_types_provided(Req, State=#{content_type:=ContentType}) ->
    {[{ContentType, accept_content}], Req, State}.

%% возвращаемые типы данных
content_types_accepted(Req, State=#{content_type:=ContentType}) ->
    {[{ContentType, accept_content}], Req, State}.

accept_content(Req, State)->
    rabbit_api2_utils:accept_content(Req,State).
