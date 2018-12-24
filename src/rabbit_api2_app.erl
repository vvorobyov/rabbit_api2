-module(rabbit_api2_app).
-behaviour(application).

-export([start/2]).
-export([stop/1]).

-define(TCP_CONTEXT, rabbit_api2_tcp).
-define(TLS_CONTEXT, rabbitmq_api2_tls).
-include("rabbit_api2.hrl").

start(_Type, _Args) ->
    start_configure_listener(),
    rabbit_api2_sup_sup:start_link().

stop(_State) ->
	ok.

%%%-------------------------------------------------------------------
%%% Internal functions
%%%-------------------------------------------------------------------

start_configure_listener()->
    Listeners = case {has_configured_tcp_listener(),
                      has_configured_tls_listener()} of
                    {false, false} ->
                        [get_tcp_listener()];
                    {true, false} ->
                        [get_tcp_listener()];
                    {false, true} ->
                        [get_tls_listener()];
                    {true, true} ->
                        [get_tcp_listener(),
                         get_tls_listener()]
                end,
    [start_listener(Listener) || Listener <- Listeners].

has_configured_tcp_listener()->
    has_configured_listener(tcp_config).

has_configured_tls_listener()->
    has_configured_listener(ssl_config).

has_configured_listener(Key) ->
    case application:get_env(rabbit_api2, Key) of
        undefined -> false;
        _         -> true
    end.

get_tls_listener() ->
    {ok, Listener0} = application:get_env(rabbit_api2, ssl_config),
    [{ssl, true} | Listener0].

get_tcp_listener() ->
    application:get_env(rabbit_api2, tcp_config, []).

start_listener(Listener) ->
    {_Type, ContextName} = case is_tls(Listener) of
                              true  -> {tls, ?TLS_CONTEXT};
                              false -> {tcp, ?TCP_CONTEXT}
                          end,
    {ok, _} = register_context(ContextName, Listener),
    %% case NeedLogStartup of
    %%     true  -> log_startup(Type, Listener);
    %%     false -> ok
    %% end,
    ok.

register_context(ContextName, Listener0) ->
    M0 = maps:from_list(Listener0),
    %% include default port if it's not provided in the config
    %% as Cowboy won't start if the port is missing
    M1 = maps:merge(#{port => ?DEFAULT_PORT}, M0),
    Router = [{'_',[{"/api2/", rabbit_api2_h,[]},
                    {"/api2/test/[...]", rabbit_api2_h,[]}
                   ]}],
    Dispatch = cowboy_router:compile(Router),
    rabbit_web_dispatch:register_context_handler( % Return {ok,""}
      ContextName, % Name
      maps:to_list(M1), % Listener
      "api2", % Prefix
      Dispatch, % cowboy routers
      "RabbitMQ api2 Plugin" % LinkText
     ).

is_tls(Listener) ->
    case proplists:get_value(ssl, Listener) of
        undefined -> false;
        false     -> false;
        _         -> true
    end.
