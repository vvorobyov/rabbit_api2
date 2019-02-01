%%%-------------------------------------------------------------------
%%% @author Vladislav Vorobyov <vlad@erldev>
%%% @copyright (C) 2019, Vladislav Vorobyov
%%% @doc
%%%
%%% @end
%%% Created : 31 Jan 2019 by Vladislav Vorobyov <vlad@erldev>
%%%-------------------------------------------------------------------
-module(rabbit_api2_dyn_worker_sup).

-behaviour(mirrored_supervisor).

%% API
-export([start_link/0]).

%% Supervisor callbacks
-export([init/1]).

-define(SERVER, ?MODULE).

%%%===================================================================
%%% API functions
%%%===================================================================
start_link() ->
    supervisor:start_link({local, ?SERVER}, ?MODULE, []).

%%%===================================================================
%%% Supervisor callbacks
%%%===================================================================

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Whenever a supervisor is started using supervisor:start_link/[2,3],
%% this function is called by the new process to find out about
%% restart strategy, maximum restart intensity, and child
%% specifications.
%% @end
%%--------------------------------------------------------------------
-spec init(Args :: term()) ->
		  {ok, {SupFlags :: supervisor:sup_flags(),
			[ChildSpec :: supervisor:child_spec()]}} |
		  ignore.
init([]) ->

    SupFlags = #{strategy => one_for_one,
		 intensity => 1,
		 period => 5},

    AChild = #{id => 'AName',
	       start => {'AModule', start_link, []},
	       restart => permanent,
	       shutdown => 5000,
	       type => worker,
	       modules => ['AModule']},

    {ok, {SupFlags, [AChild]}}.

%%%===================================================================
%%% Internal functions
%%%===================================================================
