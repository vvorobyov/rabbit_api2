%%%-------------------------------------------------------------------
%%% @author Vladislav Vorobyov <vlad@erldev>
%%% @copyright (C) 2018, Vladislav Vorobyov
%%% @doc
%%%
%%% @end
%%% Created : 25 Dec 2018 by Vladislav Vorobyov <vlad@erldev>
%%%-------------------------------------------------------------------
-module(rabbit_api2_cowboy_worker).

-behaviour(gen_server2).

%% API
-export([start_link/1]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3, format_status/2]).

-include("rabbit_api2.hrl").

-define(SERVER, ?MODULE).
-define(TCP_CONTEXT, rabbit_api2_tcp).
-define(TLS_CONTEXT, rabbit_api2_tls).

-record(state, {}).

%%%===================================================================
%%% API
%%%===================================================================

%%--------------------------------------------------------------------
%% @doc
%% Starts the server
%% @end
%%--------------------------------------------------------------------
start_link(Config) ->
    start_configure_listener(Config),
    gen_server2:start_link({local, ?SERVER}, ?MODULE, Config, []).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Initializes the server
%% @end
%%--------------------------------------------------------------------
init(Config) ->
    process_flag(trap_exit, true),
    io:format("~nCowboy config~nConfig: ~p~n",[Config]),
    {ok, #state{}}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling call messages
%% @end
%%--------------------------------------------------------------------
handle_call(_Request, _From, State) ->
    Reply = ok,
    {reply, Reply, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling cast messages
%% @end
%%--------------------------------------------------------------------
handle_cast(_Request, State) ->
    {noreply, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling all non call/cast messages
%% @end
%%--------------------------------------------------------------------
handle_info(_Info, State) ->
    {noreply, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% This function is called by a gen_server when it is about to
%% terminate. It should be the opposite of Module:init/1 and do any
%% necessary cleaning up. When it returns, the gen_server terminates
%% with Reason. The return value is ignored.
%% @end
%%--------------------------------------------------------------------
terminate(_Reason, _State) ->
    ok.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Convert process state when code is changed
%% @end
%%--------------------------------------------------------------------
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% This function is called for changing the form and appearance
%% of gen_server status when it is returned from sys:get_status/1,2
%% or when it appears in termination error logs.
%% @end
%%--------------------------------------------------------------------
format_status(_Opt, Status) ->
    Status.

%%%===================================================================
%%% Internal functions
%%%===================================================================

start_configure_listener(Config)->
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
    [start_listener(Listener, Config) || Listener <- Listeners].

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

start_listener(Listener, Config) ->
    {_Type, ContextName} = case is_tls(Listener) of
                              true  -> {tls, ?TLS_CONTEXT};
                              false -> {tcp, ?TCP_CONTEXT}
                          end,
    {ok, _} = register_context(ContextName, Listener, Config),
    %% case NeedLogStartup of
    %%     true  -> log_startup(Type, Listener);
    %%     false -> ok
    %% end,
    ok.

register_context(ContextName, Listener0, Config) ->
    Prefix = get_prefix(),
    M0 = maps:from_list(Listener0),
    %% include default port if it's not provided in the config
    %% as Cowboy won't start if the port is missing
    M1 = maps:merge(#{port => ?DEFAULT_PORT}, M0),
    Dispatch = rabbit_api2_dispatcher:build_dispatcher(Prefix,Config),
    rabbit_web_dispatch:register_context_handler( % Return {ok,""}
      ContextName, % Name
      maps:to_list(M1), % Listener
      Prefix, % Prefix
      Dispatch, % cowboy routers
      "RabbitMQ API2 Plugin" % LinkText
     ).

is_tls(Listener) ->
    case proplists:get_value(ssl, Listener) of
        undefined -> false;
        false     -> false;
        _         -> true
    end.

get_prefix()->
    case application:get_env(prefix) of
        {ok, Value} when is_list(Value) ->
            parse_prefix(Value);
        _ ->
            "api2/v2"
    end.
parse_prefix(Value)->
    case {hd(Value),lists:last(Value)} of
        {$/, $/} ->
            lists:sublist(Value,2, length(Value)-2);
        {$/, _} ->
            tl(Value);
        {_, $/}->
            lists:sublist(Value,1, length(Value)-1);
        {_, _} -> Value
    end.