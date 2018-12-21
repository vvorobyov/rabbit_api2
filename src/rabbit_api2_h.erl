-module(rabbit_api2_h).
-behavior(cowboy_handler).

-export([init/2]).

init(Req0, State) ->
    io:format("~nReq: ~p",[Req0]),
    Req = cowboy_req:reply(200,
                           #{<<"content-type">> => <<"text/plain">>},
                           <<"Hello Erlang!">>,
                           Req0),
    {ok, Req, State}.
