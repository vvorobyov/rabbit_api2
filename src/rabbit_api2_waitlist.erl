%%%-------------------------------------------------------------------
%%% @author Vladislav Vorobyov <vlad@erldev>
%%% @copyright (C) 2019, Vladislav Vorobyov
%%% @doc
%%%
%%% @end
%%% Created : 10 Jan 2019 by Vladislav Vorobyov <vlad@erldev>
%%%-------------------------------------------------------------------
-module(rabbit_api2_waitlist).

%% API
-export([empty/0,
         append/2,
         delete/2,
         get/2,
         get/3]).

%%%===================================================================
%%% API
%%%===================================================================
empty()->
    [].

append({DeliveryTag, MessageId, From}, WaitList)
  when is_integer(DeliveryTag), DeliveryTag > 0,
       is_binary(MessageId), is_list(WaitList)->
    case lists:member({DeliveryTag, MessageId, From}, WaitList) of
        true -> WaitList;
        false -> [{DeliveryTag, MessageId, From}|WaitList]
    end;
append({D, M, F}, W) ->
    io:format("~p ~p ~p ~p",[D,M,F,W]),
    throw({error, incorrect_parameters}).

delete(DeliveryTag, WaitList)
  when is_integer(DeliveryTag), is_list(WaitList) ->
    lists:keydelete(DeliveryTag, 1, WaitList);
delete(MessageID, WaitList)
  when is_binary(MessageID), is_list(WaitList)->
    lists:keydelete(MessageID, 2, WaitList);
delete(From, WaitList)
  when is_list(WaitList) ->
    lists:keydelete(From, 3, WaitList).

get(DeliveryTag, WaitList) when is_number(DeliveryTag)->
    lists:keyfind(DeliveryTag, 1, WaitList);
get(MessageID, WaitList) when is_binary(MessageID)->
    lists:keyfind(MessageID, 2, WaitList);
get(From, WaitList) ->
    lists:keyfind(From, 3, WaitList).

get([], _, _)->
    throw({error, incorrect_fields_name});
get(Acc, Key, WaitList) ->
    {DeliveryTag, MessageId, From} =
        case get(Key, WaitList) of
            Item = {_, _, _} ->
                Item;
            false -> {false, false, false}
        end,
    Fun = fun (delivery_tag) -> DeliveryTag;
              (message_id) -> MessageId;
              (from) -> From;
              (_) -> throw({error, incorrect_fields_name})
          end,
    erlang:list_to_tuple(lists:map(Fun,Acc)).

%%%===================================================================
%%% Internal functions
%%%===================================================================
