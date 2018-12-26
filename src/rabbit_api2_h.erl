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
    io:format("init~n"),
    %% Проработать настройки по аналогии с
    %% rabbit_mgmt_headers:set_common_permission_headers
    {cowboy_rest, Req, State}.

variances(Req, Context) ->
    io:format("variances~n"),
    {[<<"accept-encoding">>, <<"origin">>], Req, Context}.

allowed_methods(Req, State=#{methods := Methods})->
    io:format("allowed_methods~n"),
    {Methods, Req, State}.

is_authorized(Req, State)->
    io:format("is_authorized~n"),
    rabbit_api2_utils:is_authorized(Req, State).
forbidden(Req,State)->
    io:format("forbidden~n"),
    rabbit_api2_utils:forbidden(Req, State).

%% предоставляемые типы данных
content_types_provided(Req, State) ->
    io:format("content_types_provided~n"),
    {[{<<"application/json">>, accept_content}], Req, State}.

%% возвращаемые типы данных
content_types_accepted(Req, State) ->
    io:format("content_types_accepted~n"),
    {[{<<"application/json">>, accept_content}], Req, State}.

accept_content(Req0=#{method:=Method}, State=#{name:=Name})->
    io:format("accept_content GET~n"),
    {ok, UserName} = rabbit_api2_utils:get_user_name(Req0),
    {ok, Headers} = rabbit_api2_utils:get_headers(Req0),
    io:format("~nHeaders: ~p~n", [Headers]),
    {ok, Body, Req1} = rabbit_api2_utils:get_body(Req0, #{max_body_len=>131072}),
    Req =
        case {Method,jsx:is_json(Body)} of
            {<<"GET">>, false} ->
                cowboy_req:reply(400,#{<<"content-type">> =>
                                           <<"application/json">>},
                                 "{\"error\":\"not_valid_request\","
                                 "\"description\":\"Request is not valid\"}",
                                 Req1);
            {_, false} ->
                cowboy_req:reply(400,#{<<"content-type">> =>
                                           <<"application/json">>},
                                 "{\"error\":\"not_valid_json\","
                                 "\"description\":\"Request is not valid JSON\"}",
                                 Req1);
            {_, true} ->
                cowboy_req:reply(200,
                                 #{<<"content-type">> => <<"application/json">>},
                                 rabbit_api2_worker:request(
                                   {global,Name},
                                   {UserName, Headers, Body}),
                                 Req1)
        end,
    {ok, Req, State}.
