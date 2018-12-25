-module(rabbit_api2_h).
-behavior(cowboy_handler).

-export([init/2,
         variances/2,
         allowed_methods/2,
         is_authorized/2,
         accept_content/2,
         content_types_provided/2,
         %% to_json/2,
         content_types_accepted/2]).

init(Req, State) ->
    io:format("~n~p~n", [Req]),
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

is_authorized(Req, State=#{auth:=rabbitmq_auth, name:=Name})->
    io:format("is_authorized~n"),
    case cowboy_req:parse_header(<<"authorization">>, Req) of
        {basic, Username, Password} ->
            {rabbit_api2_worker:auth({global, Name},{Username,Password}),
             Req, State};
        _ -> {{false,<<"Basic realm=\"cowboy\"">>}, Req, State}
    end;
is_authorized(Req, State=#{auth:=Auth}) ->
    io:format("is_authorized~n"),
    case cowboy_req:parse_header(<<"authorization">>, Req) of
            {basic, Username, Password} ->
                {case lists:member(
                       rabbit_api2_utils:gen_hash(Username,Password),
                       Auth) of
                     true ->
                         true;
                     false -> {false,<<"Basic realm=\"cowboy\"">> }
                 end,
                 Req, State};
            _ -> {{false,<<"Basic realm=\"cowboy\"">>}, Req, State}
        end.

%% предоставляемые типы данных
content_types_provided(Req, State) ->
    io:format("content_types_provided~n"),
    {[{<<"application/json">>, accept_content}], Req, State}.

%% возвращаемые типы данных
content_types_accepted(Req, State) ->
    io:format("content_types_accepted~n"),
    {[{<<"application/json">>, accept_content}], Req, State}.

accept_content(Req0,State=#{name:=Name})->
    io:format("accept_content~n"),
    Response = rabbit_api2_worker:request({global,Name},Req0),
    Req = cowboy_req:reply(200,
                           #{<<"content-type">> => <<"text/plain">>},
                           Response,
                           Req0),
    {ok, Req, State}.
