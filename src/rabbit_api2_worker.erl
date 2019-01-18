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
    gen_server2:call(Pid,{request, Msg},infinity).
auth(_Pid, {_,_})->
    true.
%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

init(Config=#{name:=Name,
              type:=Type,
              dst_config:=DstConfig,
              src_config:=SrcConfig}) ->
    try
    process_flag(trap_exit, true),
    {ok, DstConn, DstCh, SrcConn, SrcCh} =
        make_connections_and_channels(Config),
    io:format("~n~nWorker: ~p ~p"
              "~nPublish connection: ~p"
              "~nPublish channel: ~p"
              "~nConsum connection: ~p"
              "~nConsum channel: ~p",
              [Name,self(),DstConn, DstCh, SrcConn, SrcCh]),
    {ok, #state{
            name=Name,
            type=Type,
            dst_conn=DstConn,
            src_conn=SrcConn,
            publish_ch=DstCh,
            consume_ch=SrcCh,
            dst_config=DstConfig,
            src_config=SrcConfig,
            wait_response= rabbit_api2_waitlist:empty()}}
    catch
        {error, Reason}->
            Error = io_lib:format("Error start '~p' with reason: ~s",[Name,
              Reason]),
            {stop, binary_to_list(iolist_to_binary(Error))}
    end.

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
    case {S#state.type,rabbit_api2_waitlist:get([from], DeliveryTag,
                                                S#state.wait_response)} of
        {sync, _} ->
            {noreply, S};
        {async,{false}} ->
            {noreply, S};
        {async, {From}} ->
            io:format("~n Ack From: ~p",[From]),
            gen_server2:reply(From, {publish_ok, <<"publish_ok">>}),
            io:format("Ack Replied"),
            {noreply, delete_wait(DeliveryTag, S)}
    end;
%% Ошибка публикации сообщения
handle_info(#'basic.nack'{delivery_tag=DeliveryTag},
            S=#state{wait_response=WaitList}) ->
    case rabbit_api2_waitlist:get([from], DeliveryTag, WaitList) of
        {false} -> {noreply, S};
        {From} ->
            gen_server2:reply(From, {publish_error, <<"Server Return nack">>}),
            NewState=delete_wait(DeliveryTag, S),
            {noreply, NewState}
    end;
%% Получение сообщения из очереди
handle_info({#'basic.deliver'{consumer_tag=ConsTag,
                             delivery_tag=DeliveryTag},
             Msg = #amqp_msg{props=#'P_basic'{correlation_id=MessageId}}},
            S = #state{consumer_tag = ConsTag}) ->
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
%% Обработка завершения процесса Cowboy
handle_info({'DOWN', Ref, process, _Pid,_Reason}, S=#state{}) ->
    io:format("~nResponse: ~p",[erlang:localtime()]),
    NewState = delete_wait(Ref, S),
    {noreply, NewState};
%% Обработка завершения подключения
handle_info({'EXIT', Conn0, _Reason},
            S=#state{dst_conn=Conn0, src_conn=Conn0})->
    {ok, Conn, DstCh, Conn, SrcCh} =
        make_connections_and_channels(#{name=>S#state.name,
                                        type=>S#state.type,
                                        dst_config=>S#state.dst_config,
                                        src_config=>S#state.src_config}),
    {noreply,S#state{dst_conn=Conn,
                     publish_ch=DstCh,
                     src_conn=Conn,
                     consume_ch=SrcCh}};
%% Обработка завершения подключения публишера
handle_info({'EXIT', Conn0, _Reason},
            S=#state{dst_conn=Conn0 ,src_conn=none}) ->
    {ok, Conn, Ch} = make_dst_conn_and_ch(<<"">>,
                                          S#state.name,
                                          S#state.dst_config),
    {noreply, S#state{dst_conn=Conn,
                      publish_ch=Ch}};
handle_info({'EXIT', Conn0, _Reason},
            S=#state{dst_conn=Conn0}) ->
    {ok, Conn, Ch} = make_dst_conn_and_ch(<<"Publisher">>,
                                                S#state.name,
                                                S#state.dst_config),
    {noreply, S#state{dst_conn=Conn,
                      publish_ch=Ch}};
%% Обработка завершения подключения консьюмера
handle_info({'EXIT', Conn0, _Reason},
            S=#state{src_conn=Conn0}) ->
    {ok, Conn, Ch} = make_src_conn_and_ch(S#state.name,
                                          S#state.src_config),
    {noreply, S#state{dst_conn=Conn,
                      publish_ch=Ch}};

%% Прочие сообщения
handle_info(_Info, S) ->
    io:format("~nUnknown message: ~p",[_Info]),
    {noreply, S}.
terminate(_Reason, State) ->
    close_channels(State),
    close_connections(State),
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
append_wait(MessageID, From = {Pid, _}, S)->
    DeliveryTag = S#state.current_delivery_tag,
    Ref = erlang:monitor(process, Pid),
    WaitList = rabbit_api2_waitlist:append(
                 {DeliveryTag, MessageID, From, Ref},
                 S#state.wait_response),
    S#state{wait_response=WaitList,
            current_delivery_tag=DeliveryTag+1}.

delete_wait(Key, S=#state{})
  when not is_reference(Key) ->
    case rabbit_api2_waitlist:get([ref], Key, S#state.wait_response) of
        {false} -> S;
        {Ref} -> erlang:demonitor(Ref, [flush]),
                 delete_wait(Ref,S)
    end;
delete_wait(Key, S=#state{}) ->
    WaitList = rabbit_api2_waitlist:delete(Key, S#state.wait_response),
    S#state{wait_response=WaitList}.

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
                                dst_config := DstConf = #{vhost:=VHost},
                                src_config := SrcConf = #{vhost:=VHost}})->
    {ok, Connection, DstCh} = make_dst_conn_and_ch(<<>>, Name, DstConf),
    SrcCh = make_channel(Connection),
    consume(SrcCh, SrcConf),
    {ok,Connection, DstCh, Connection, SrcCh};
make_connections_and_channels(#{type:=sync,
                                name := Name,
                                dst_config := DstConf,
                                src_config := SrcConf}) ->
    {ok, DstConn, DstCh} = make_dst_conn_and_ch(<<"Publisher">>, Name, DstConf),
    {ok, SrcConn, SrcCh} = make_src_conn_and_ch(Name, SrcConf),
    {ok, DstConn, DstCh, SrcConn, SrcCh};
make_connections_and_channels(#{type:=async,
                                name := Name,
                                dst_config := DstConf}) ->
    {ok, Connection, DstCh} = make_dst_conn_and_ch(<<>>, Name, DstConf),
    {ok, Connection, DstCh, none, none}.

%% Создание канала и подключения публишера
make_dst_conn_and_ch(Prefix, Name, #{vhost:=VHost})->
    DstConnName = get_connection_name(Prefix, Name),
    {ok, DstConn} = make_connection(DstConnName, VHost),
    DstCh = make_channel(DstConn),
    amqp_channel:register_return_handler(DstCh, self()),
    amqp_channel:cast(DstCh, #'confirm.select'{}),
    amqp_channel:register_confirm_handler(DstCh, self()),
    {ok, DstConn, DstCh}.


%% Зодание канала и подключения подписка
make_src_conn_and_ch(Name, SrcConf = #{vhost:=SrcVHost})->
    SrcConnName = get_connection_name(<<"Consumer">>, Name),
    {ok, SrcConn} = make_connection(SrcConnName, SrcVHost),
    SrcCh = make_channel(SrcConn),
    consume(SrcCh, SrcConf),
    {ok, SrcConn, SrcCh}.


%% Создание подключения
make_connection(ConnName, VHost)->
    {ok, AmqpParam} = amqp_uri:parse(get_uri(VHost)),
    case amqp_connection:start(AmqpParam, ConnName) of
        {ok, Conn} ->
            link(Conn),
            {ok, Conn};
        {error, Reason} ->
            throw({error,{connection_not_opened,Reason}})
    end.

%% Создание канала
make_channel(Connection)->
    {ok, Ch} = amqp_connection:open_channel(Connection),
    Ch.

%% Генерация URI для подключения
get_uri(<<"/">>)->
    "amqp:///%2f";
get_uri(VHost) ->
    "amqp:///"++binary_to_list(VHost).

%% Функция функция формирования имени подключения на основании
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

%% Подписка на очередь
consume(Channel,#{queue := Queue,
                  prefetch_count := PrefCount})->
    amqp_channel:call(Channel, #'basic.qos'{prefetch_count = PrefCount}),
    amqp_channel:subscribe(Channel,
                           #'basic.consume'{queue = Queue},
                           self()).

%% Закрытие каналов 
close_channels(#state{consume_ch=ConsCh, publish_ch=PubCh})->
    lists:foreach(fun close_channel/1, [ConsCh, PubCh]).

%% Закрытие канала
close_channel(Ch) when is_pid(Ch)->
    catch amqp_channel:close(Ch),
    ok;
close_channel(_)->
    ok.

%% Закрытие подключений
close_connections(#state{dst_conn=Conn1, src_conn=Conn2})->
    lists:foreach(fun close_connection/1, [Conn1, Conn2]).

%% Закрытие подключения
close_connection(Conn) when is_pid(Conn)->
    catch amqp_connection:close(Conn),
    ok;
close_connection(_) ->
    ok.
