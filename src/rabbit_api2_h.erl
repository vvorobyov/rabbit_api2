-module(rabbit_api2_h).
-behavior(cowboy_handler).

-export([init/2]).

init(Req0, State=#{name:=Name}) ->
    io:format("~nReq: ~p~nState: ~p~n",[Req0,State]),
    Response = rabbit_api2_worker:request({global,Name},Req0),
    io:format("~nResponse: ~s~n",[Response]),
    Req = cowboy_req:reply(200,
                           #{<<"content-type">> => <<"text/plain">>},
                           Response,
                           Req0),
    {ok, Req, State}.
