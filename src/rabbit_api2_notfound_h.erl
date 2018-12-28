-module(rabbit_api2_notfound_h).
-behavior(cowboy_handler).

-export([init/2]).

init(Req0, State) ->
    Req = cowboy_req:reply(404,#{<<"content-type">>=><<"application/xml">>}, Req0),
    {ok, Req, State}.
