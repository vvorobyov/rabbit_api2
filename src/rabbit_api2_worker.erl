%%%-------------------------------------------------------------------
%%% @author Vladislav Vorobyov <vlad@erldev>
%%% @copyright (C) 2018, Vladislav Vorobyov
%%% @doc
%%%
%%% @end
%%% Created : 21 Dec 2018 by Vladislav Vorobyov <vlad@erldev>
%%%-------------------------------------------------------------------
-module(rabbit_api2_worker).

-behaviour(gen_server2).

-include("rabbit_api2.hrl").
%% API
-export([start_link/1]).
-export([request/2, auth/2]).
%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3, format_status/2]).

-define(SERVER, ?MODULE).

%% -record(state, {name,
%%                 dst_conn,
%%                 src_conn,
%%                 publish_ch,
%%                 consume_ch,
%%                 src_config,
%%                 dst_conig}).

%%%===================================================================
%%% API
%%%===================================================================

start_link(Config=#{name:=Name}) ->
    gen_server2:start_link({global, Name}, ?MODULE, [Config], []).

request(Pid, Request)->
    gen_server:call(Pid,{request, Request}).
auth(_Pid, {_,_})->
    true.
%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

init([Config]) ->
    io:format("~n~p ~n~p~n",[Config, self()]),
    process_flag(trap_exit, true),
    {ok, Config}.

handle_call({request, _Request}, _From, State) ->
    {reply, io_lib:format("~p",[State]),State};
handle_call(_Request, _From, State) ->
    Reply = ok,
    {reply, Reply, State}.

handle_cast(_Request, State) ->
    {noreply, State}.

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

format_status(_Opt, Status) ->
    Status.

%%%===================================================================
%%% Internal functions
%%%===================================================================

