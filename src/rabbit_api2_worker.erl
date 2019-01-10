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
-include_lib("amqp_client/include/amqp_client.hrl").

%% API
-export([start_link/1]).
-export([request/2, auth/2]).
%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3, format_status/2]).

-define(SERVER, ?MODULE).

-record(state, {name,
                type,
                dst_conn,
                src_conn,
                publish_ch,
                consume_ch,
                src_config,
                dst_config,
                current_delivery_tag=1,
                consumer_tag,
                wait_response}).

%%%===================================================================
%%% API
%%%===================================================================

start_link(Config=#{name:=Name}) ->
    gen_server2:start_link({global, Name}, ?MODULE, Config, []).

request(Pid, Msg=#amqp_msg{})->
    gen_server:call(Pid,{request, Msg}).
auth(_Pid, {_,_})->
    true.
%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

init(Config=#{name:=Name,
              type:=Type,
              dst_config:=DstConfig,
              src_config:=SrcConfig}) ->
    io:format("~n~p ~n~p~n",[Config, self()]),
    process_flag(trap_exit, true),
    {ok, DstConn, DstCh, SrcConn, SrcCh} =
        make_connections_and_channels(Config),
    {ok, #state{
            name=Name,
            type=Type,
            dst_conn=DstConn,
            src_conn=SrcConn,
            publish_ch=DstCh,
            consume_ch=SrcCh,
            dst_config=DstConfig,
            src_config=SrcConfig,
            wait_response= rabbit_api2_waitlist:empty()}}.

handle_call({request, Msg}, From, S=#state{}) ->
    MessageID = publish_message(S#state.publish_ch,
                                Msg, S#state.dst_config),
    NewState = append_wait(MessageID, From, S),
    {noreply, NewState};
handle_call(_Request, _From, State) ->
    {noreply, State}.

handle_cast(_Request, State) ->
    {noreply, State}.

%% Успешная подписка на очередь
handle_info(#'basic.consume_ok'{consumer_tag=ConsTag},S) ->
    {noreply, S#state{consumer_tag=ConsTag}};
%% Ошибка маршрутизации сообщения
handle_info({#'basic.return'{reply_text = Reason},
             #amqp_msg{props=#'P_basic'{message_id=MessageId}}},
            S=#state{}) ->
    {From} = rabbit_api2_waitlist:get([from], MessageId, S#state.wait_response),
    gen_server2:reply(From, {publish_error, Reason}),
    NewState=delete_wait(MessageId, S),
    {noreply, NewState};
%% Успешная публикация сообщения
handle_info(#'basic.ack'{delivery_tag = DeliveryTag},
            S=#state{}) ->
    case S#state.type of
        sync ->
            {noreply, S};
        async ->
            {From} = rabbit_api2_waitlist:get([from], DeliveryTag,
                                              S#state.wait_response),
            gen_server2:reply(From, {publish_ok, <<"publish_ok">>}),
            {noreply, delete_wait(DeliveryTag, S)}
    end;
%% Ошибка публикации сообщения
handle_info(#'basic.nack'{delivery_tag=DeliveryTag},
            S=#state{wait_response=WaitList}) ->
    {From} = rabbit_api2_waitlist:get([from], DeliveryTag, WaitList),
    gen_server2:reply(From, {publish_error, <<"Server Return nack">>}),
    NewState=delete_wait(DeliveryTag, S),
    {noreply, NewState};
handle_info({#'basic.deliver'{consumer_tag=ConsTag,
                             delivery_tag=DeliveryTag},
             Msg = #amqp_msg{props=#'P_basic'{correlation_id=MessageId}}},
            S = #state{consumer_tag = ConsTag})->
    NewState = case MessageId of
                   undefined ->
                       S;
                   _ ->
                       case rabbit_api2_waitlist:get(
                              [from], MessageId,
                              S#state.wait_response) of
                           {false} ->
                               S;
                           {From} ->
                               gen_server2:reply(From, {response,Msg}),
                               delete_wait(MessageId, S)
                       end
               end,
    amqp_channel:cast(S#state.consume_ch,
                      #'basic.ack'{delivery_tag=DeliveryTag}),
    {noreply, NewState};
handle_info(_Info, State) ->
    io:format("~p~n",[_Info]),
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

%%%-------------------------------------------------------------------
%%% Change State Functions
%%%-------------------------------------------------------------------
append_wait(MessageID, From, S)->
    DeliveryTag = S#state.current_delivery_tag,
    WaitList = rabbit_api2_waitlist:append(
                 {DeliveryTag, MessageID, From}, S#state.wait_response),
    S#state{wait_response=WaitList,
            current_delivery_tag=DeliveryTag+1}.

delete_wait(Key, S=#state{})->
    WaitList = rabbit_api2_waitlist:delete(Key, S#state.wait_response),
    S#state{wait_response=WaitList}.

%% register_response({#'basic.deliver'{delivery_tag=Tag},
%%                    Msg}, S=#state{consume_ch= Ch})->

%%     amqp_channel:cast(Ch,#'basic.ack'{})
%%     {noreply, S}.



%% register_ack(#'basic.ack'{delivery_tag = DeliveryTag}, S)->
%%     case S#state.type of
%%         async ->
%%             gen_server2:reply(From, {publish_ok,<<"publish_ok">>});
%%         sync -> ok
%%     end,
%%     end.

%% register_nack(#'basic.nack'{delivery_tag=DeliveryTag}, S=#state{})->
%%     case lists:keyfind(DeliveryTag, 1, S#state.wait_ack) of
%%         {DeliveryTag, MessageID, From} ->
%%             WaitAck = lists:keydelete(DeliveryTag, 1, S#state.wait_ack),
%%             WaitResponse = lists:keydelete(MessageID, 1, S#state.wait_response),
%%             gen_server2:reply(From, {publish_error, <<"Server Return nack">>}),
%%             {noreply, S#state{wait_ack = WaitAck,
%%                               wait_response = WaitResponse}};
%%         false ->
%%             {noreply, S}
%%     end.

publish_message(Channel,
                Message=#amqp_msg{props=#'P_basic'{message_id=MessageID}},
                #{exchange:=Exchange,
                  routing_key:=RoutingKey})->
    amqp_channel:cast(Channel,
                      #'basic.publish'{
                         exchange=Exchange,
                         mandatory=true,
                         routing_key=RoutingKey},
                      Message),
    MessageID.

make_connections_and_channels(#{type:=sync,
                                name := Name,
                                dst_config := #{vhost:=VHost},
                                src_config := SrcConf = #{vhost:=VHost}})->
    ConnName = get_connection_name(Name),
    {ok,Connection} = make_connection(ConnName, VHost),
    DstCh = make_channel(Connection),
    amqp_channel:register_return_handler(DstCh, self()),
    amqp_channel:cast(DstCh, #'confirm.select'{}),
    amqp_channel:register_confirm_handler(DstCh, self()),
    SrcCh = make_channel(Connection),
    consume(SrcCh, SrcConf),
    {ok,Connection, DstCh, Connection, SrcCh};
make_connections_and_channels(#{type:=sync,
                                name := Name,
                                dst_config := #{vhost:=DstVHost},
                                src_config := SrcConf = #{vhost:=SrcVHost}}) ->
    DstConnName = get_connection_name(<<"Publisher">>, Name),
    {ok, DstConn} = make_connection(DstConnName, DstVHost),
    DstCh = make_channel(DstConn),
    amqp_channel:register_return_handler(DstCh, self()),
    #'confirm.select_ok'{}=amqp_channel:call(DstCh, #'confirm.select'{}),
    amqp_channel:register_confirm_handler(DstCh, self()),
    SrcConnName = get_connection_name(<<"Consumer">>, Name),
    {ok, SrcConn} = make_connection(SrcConnName, SrcVHost),
    SrcCh = make_channel(SrcConn),
    consume(SrcCh, SrcConf),
    {ok, DstConn, DstCh, SrcConn, SrcCh};
make_connections_and_channels(#{type:=async,
                                name := Name,
                                dst_config := #{vhost:=VHost}}) ->
    ConnName = get_connection_name(Name),
    {ok, Connection} = make_connection(ConnName, VHost),
    DstCh = make_channel(Connection),
    amqp_channel:register_return_handler(DstCh, self()),
    amqp_channel:cast(DstCh, #'confirm.select'{}),
    amqp_channel:register_confirm_handler(DstCh, self()),
    {ok, Connection, DstCh, none, none}.

make_connection(ConnName, VHost)->
    {ok, AmqpParam} = amqp_uri:parse(get_uri(VHost)),
    case amqp_connection:start(AmqpParam, ConnName) of
        {ok, Conn} ->
            link(Conn),
            {ok, Conn};
        {error, Reason} ->
            throw({error, io_lib:format(
                            "Error start connection with reason:~p",
                            [Reason])})
    end.

make_channel(Connection)->
    {ok, Ch} = amqp_connection:open_channel(Connection),
    link(Ch),
    Ch.

get_uri(<<"/">>)->
    "amqp:///%2f";
get_uri(VHost) ->
    "amqp:///"++binary_to_list(VHost).

%% Функция функция формирования имени подключения на основании
get_connection_name(Name)->
    get_connection_name(<<>>, Name).

get_connection_name(<<>>, Name)
  when is_atom(Name) ->
    Prefix = <<"RabbitMQ APIv2.0 ">>,
    NameAsBinary = atom_to_binary(Name, utf8),
    <<Prefix/binary, NameAsBinary/binary>>;
get_connection_name(<<>>, Name)
  when is_binary(Name) ->
    Prefix = <<"RabbitMQ APIv2.0 ">>,
    <<Prefix/binary, Name/binary>>;
get_connection_name(Postfix, Name)
  when is_atom(Name) ->
    Prefix = <<"RabbitMQ APIv2.0 ">>,
    NameAsBinary = atom_to_binary(Name, utf8),
    <<Prefix/binary, NameAsBinary/binary,
      <<" (">>/binary, Postfix/binary, <<")">>/binary>>;
%% for dynamic shovels, name is a binary
get_connection_name(Postfix, Name)
  when is_binary(Name) ->
    Prefix = <<"RabbitMQ APIv2.0 ">>,
    <<Prefix/binary, Name/binary,
      <<" (">>/binary, Postfix/binary, <<")">>/binary>>;
%% fallback
get_connection_name(_ , _) ->
    <<"RabbitMQ APIv2.0">>.

consume(Channel,#{queue := Queue,
                  prefetch_count := PrefCount})->
    amqp_channel:call(Channel, #'basic.qos'{prefetch_count = PrefCount}),
    amqp_channel:subscribe(Channel,
                           #'basic.consume'{queue = Queue},
                           self()).

