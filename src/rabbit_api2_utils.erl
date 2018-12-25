%%%-------------------------------------------------------------------
%%% @author Vladislav Vorobyov <vlad@erldev>
%%% @copyright (C) 2018, Vladislav Vorobyov
%%% @doc
%%%
%%% @end
%%% Created : 25 Dec 2018 by Vladislav Vorobyov <vlad@erldev>
%%%-------------------------------------------------------------------
-module(rabbit_api2_utils).

%% API
-export([gen_hash/2]).

%%%===================================================================
%%% API
%%%===================================================================

%%--------------------------------------------------------------------
%% @doc
%% @spec
%% @end
%%--------------------------------------------------------------------
gen_hash(Username, Password)
  when is_list(Username), is_list(Password)->
    Hash = crypto:hash(md5, "RabbitMQ API2 "++Username++":"++Password),
    lists:flatten([io_lib:format("~2.16.0b",[N]) || <<N>> <= Hash]);
gen_hash(Username, Password)
  when is_binary(Username), is_binary(Password) ->
    gen_hash(binary_to_list(Username),binary_to_list(Password));
gen_hash(Username,Password) ->
    throw({error,requare_list_or_binary,{Username,Password}}).

%%%===================================================================
%%% Internal functions
%%%===================================================================
