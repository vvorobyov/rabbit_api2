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
-export([request/3]).
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

request(Pid, Msg=#amqp_msg{}, TimeOut)->
    gen_server2:call(Pid,{request, Msg}, TimeOut).

%% auth(_Pid, {_,_})->
%%     true.
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
        case maps:find(decl_fun, DstConfig) of
            {ok, Fun} -> Fun(DstCh);
            _ -> ok
        end,
        case maps:find(decl_fun, SrcConfig) of
            {ok, Fun2} -> Fun2(SrcCh);
            _ -> ok
        end,
        consume(SrcCh, SrcConfig),
        rabbit_api2_utils:write_log(info,
                                    "RabbitMQ APIv2.0 plugin "
                                    "start ~p '~p' handler worker process: "
                                    "~n    Destination connection PID: ~p"
                                    "~n    Destination channel PID: ~p"
                                    "~n    Source connection PID: ~p"
                                    "~n    Source channel PID: ~p",
                                    [Type, Name,DstConn, DstCh, SrcConn, SrcCh]),
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
            Error = io_lib:format("Error start '~p' with reason: ~s",
                                  [Name, Reason]),
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

    State#state.wait_response,

    {noreply, State}.

%%%-------------------------------------------------------------------
%%% Работа с сообщениями
%%%-------------------------------------------------------------------
%% Успешная публикация сообщения
handle_info(#'basic.ack'{delivery_tag = DeliveryTag},
            S=#state{}) ->
    case {S#state.type,
          rabbit_api2_waitlist:get([from], DeliveryTag,
                                   S#state.wait_response)} of
        {sync, _} ->
            {noreply, S};
        {async,{false}} ->
            {noreply, S};
        {async, {From}} ->
            gen_server2:reply(From, {ok, publish_ok}),
            {noreply, delete_wait(DeliveryTag, S)}
    end;
%% Получение сообщения из очереди
handle_info({#'basic.deliver'{consumer_tag=ConsTag,
                             delivery_tag=DeliveryTag},
             Msg = #amqp_msg{
                      props=#'P_basic'{correlation_id=MessageId}}},
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
                               gen_server2:reply(From, {ok, Msg}),
                               delete_wait(MessageId, S)
                       end
               end,
    amqp_channel:cast(S#state.consume_ch,
                      #'basic.ack'{delivery_tag=DeliveryTag}),
    {noreply, NewState};
%% Ошибка маршрутизации сообщения
handle_info({#'basic.return'{reply_text = Reason},
             #amqp_msg{props=#'P_basic'{message_id=MessageId}}},
            S=#state{}) ->
    {From} = rabbit_api2_waitlist:get([from], MessageId, S#state.wait_response),
    gen_server2:reply(From, {publish_error, Reason}),
    NewState=delete_wait(MessageId, S),
    {noreply, NewState};
%% Ошибка публикации сообщения
handle_info(#'basic.nack'{delivery_tag=DeliveryTag},
            S=#state{wait_response=WaitList}) ->
    case rabbit_api2_waitlist:get([from], DeliveryTag, WaitList) of
        {false} -> {noreply, S};
        {From} ->
            gen_server2:reply(From, {publish_error, noack}),
            NewState=delete_wait(DeliveryTag, S),
            {noreply, NewState}
    end;

%%%-------------------------------------------------------------------
%%% Работа с подпиской
%%%-------------------------------------------------------------------

%% Успешная подписка на очередь
handle_info(#'basic.consume_ok'{consumer_tag=ConsTag},S) ->
    %rabbit_log:info("Consume ok"),
    {noreply, S#state{consumer_tag=ConsTag}};
%% Отписка от очереди (может возникнуть в случае удаления очереди)
handle_info(#'basic.cancel'{consumer_tag=ConsTag},
            S = #state{consumer_tag=ConsTag,
                       src_config = SrcConf=#{decl_fun:=DF},
                       consume_ch =Ch})->
    %rabbit_log:info("Consume canceled"),
    DF(Ch), % Декларирование очередей
    consume(Ch, SrcConf),
    {noreply, S};


%%%-------------------------------------------------------------------
%%% Работа с процессами Cowboy
%%%-------------------------------------------------------------------

%% Обработка завершения процесса Cowboy
handle_info({'DOWN', Ref, process, _Pid,_Reason}, S=#state{}) ->
    NewState = delete_wait(Ref, S),
    {noreply, NewState};

%%%-------------------------------------------------------------------
%%% Работа с подключениями
%%%-------------------------------------------------------------------
%% Обработка завершения подключения
handle_info({'EXIT', Conn0, Reason},
            S=#state{dst_conn=Conn0, src_conn=Conn0, name=Name})->
    rabbit_api2_utils:write_log(
      error,
      "RabbitMQ APIv2.0 Sync handler '~p'. "
      "Closed sync connection (~p) with reason:~n    ~p",
      [Name, Conn0, Reason]),
    {ok, Conn, DstCh, Conn, SrcCh} =
        make_connections_and_channels(#{name=>S#state.name,
                                        type=>S#state.type,
                                        dst_config=>S#state.dst_config,
                                        src_config=>S#state.src_config}),
    rabbit_api2_utils:write_log(
      info,
      "RabbitMQ APIv2.0 Sync handler '~p'."
      "Restart connections and channels: "
      "~n    Destination & Source connection PID: ~p"
      "~n    Destination channel PID: ~p"
      "~n    Source connection PID: ~p",
      [Name, Conn, DstCh, SrcCh]),
    {noreply,S#state{dst_conn=Conn,
                     publish_ch=DstCh,
                     src_conn=Conn,
                     consume_ch=SrcCh,
                     current_delivery_tag = 1}};
%% Обработка завершения подключения публишера
handle_info({'EXIT', Conn0, Reason},
            S=#state{name=Name,
                     type=async,
                     dst_conn=Conn0,
                     dst_config=#{vhost:=VHost}}) ->
    rabbit_api2_utils:write_log(
      error,
      "RabbitMQ APIv2.0 Async handler '~p'. "
      "Closed connection (~p) with reason:~n    ~p",
      [Name, Conn0, Reason]),
    {ok, Conn} = make_connection(<<"async">>, Name, VHost),
    {ok, Ch} = make_publish_channel(Conn),
    rabbit_api2_utils:write_log(
      info,
      "RabbitMQ APIv2.0 Async handler '~p'."
      "Restart connection and channel: "
      "~n    Destination connection PID: ~p"
      "~n    Destination channel PID: ~p",
      [Name, Conn, Ch]),
    {noreply, S#state{dst_conn=Conn,
                      publish_ch=Ch,
                      current_delivery_tag = 1}};
handle_info({'EXIT', Conn0, Reason},
            S=#state{name=Name,
                     type=sync,
                     dst_conn=Conn0,
                     dst_config=#{vhost:=VHost}}) ->
    rabbit_api2_utils:write_log(
      error,
      "RabbitMQ APIv2.0 Sync handler '~p'. "
      "Closed destination connection (~p) with reason:~n    ~p",
      [Name, Conn0, Reason]),
    {ok, Conn} = make_connection(<<"Publisher">>, Name, VHost),
    {ok, Ch} = make_publish_channel(Conn),
    rabbit_api2_utils:write_log(
      info,
      "RabbitMQ APIv2.0 Sync handler '~p'."
      "Restart destination connection and channel: "
      "~n    Destination connection PID: ~p"
      "~n    Destination channel PID: ~p",
      [Name, Conn, Ch]),
    {noreply, S#state{dst_conn=Conn,
                      publish_ch=Ch,
                      current_delivery_tag = 1}};
%% Обработка завершения подключения консьюмера
handle_info({'EXIT', Conn0, Reason},
            S=#state{name = Name,
                     src_conn=Conn0,
                     src_config=Config=#{vhost:=VHost}}) ->
    rabbit_api2_utils:write_log(
      error,
      "RabbitMQ APIv2.0 Sync handler '~p'. "
      "Closed source connection (~p) with reason:~n    ~p",
      [Name, Conn0, Reason]),
    {ok, Conn} = make_connection(<<"Consumer">>,Name, VHost),
    {ok, Ch} = make_consume_channel(Conn),
    consume(Ch, Config),
    rabbit_api2_utils:write_log(
      info,
      "RabbitMQ APIv2.0 Sync handler '~p'."
      "Restart source connection and channel: "
      "~n    Source connection PID: ~p"
      "~n    Source channel PID: ~p",
      [Name, Conn, Ch]),
    {noreply, S#state{dst_conn=Conn,
                      publish_ch=Ch}};

%%%-------------------------------------------------------------------
%%% Работа с каналами
%%%-------------------------------------------------------------------
%% Обработка закрытия канала публишера
handle_info({'EXIT', Ch, Reason},
            S=#state{name=Name, publish_ch=Ch, dst_conn=Conn,
		     dst_config = #{decl_fun:=DF}}) ->
    rabbit_api2_utils:write_log(
      error,
      "RabbitMQ APIv2.0. Handler '~p'. "
      "Destination channel closed with reasone:~n~p",
      [Name, Reason]),
    NewCh = try
                {ok, Ch0} = make_publish_channel(Conn),
                DF(Ch0),
		rabbit_api2_utils:write_log(
		  error,
		  "RabbitMQ APIv2.0. Handler '~p'. "
		  "Start destination channel with PID: ~p",
		  [Name, Ch0]),
                Ch0    
            catch
                _:_ -> none
            end,
    {noreply, S#state{publish_ch=NewCh, current_delivery_tag=1}};
%% Обработка закрытия канала консьюмера
handle_info({'EXIT', Ch, Reason},
            S=#state{name=Name, consume_ch = Ch, src_conn = Conn,
                    src_config = SrcConf= #{decl_fun:=DF}}) ->
    rabbit_api2_utils:write_log(
      error,
      "RabbitMQ APIv2.0. Handler '~p'. "
      "Source channel closed with reasone:~n~p",
      [Name, Reason]),
    NewCh = try
                {ok, Ch0} = make_consume_channel(Conn),
                DF(Ch0),
                consume(Ch0, SrcConf),
		rabbit_api2_utils:write_log(
		  info,
		  "RabbitMQ APIv2.0. Handler '~p'. "
		  "Start source channel with PID: ~p",
		  [Name, Ch0]),
                Ch0
            catch
                _:_ -> none
            end,
    {noreply, S#state{consume_ch=NewCh}};

%%%-------------------------------------------------------------------
%%% Прочие сообщения
%%%-------------------------------------------------------------------
%% Прочие сообщения
handle_info(Info, S=#state{name=Name}) ->
    rabbit_api2_utils:write_log(
      error,
      "RabbitMQ APIv2.0. Handler '~p'. "
      "Unknown message:~n~p",
      [Name, Info]),
    {noreply, S}.

terminate(Reason, State = #state{name=Name}) ->
    rabbit_api2_utils:write_log(
      warning,
      "RabbitMQ APIv2.0. Handler '~p' terminate with reason:~n~p",
      [Name, Reason]),
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
append_wait(MessageID, From = {Pid, _}, S=#state{type=Type})->
    DeliveryTag = S#state.current_delivery_tag,
    Ref = case Type of
              sync -> erlang:monitor(process, Pid);
              async -> erlang:make_ref()
          end,
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


%% Открытие подключений и каналов
make_connections_and_channels(#{type:=sync,
                                name := Name,
                                dst_config := #{vhost:=VHost},
                                src_config := #{vhost:=VHost}})->
    {ok, Connection} = make_connection(<<"sync">>, Name, VHost),
    {ok, DstCh} = make_publish_channel(Connection),
    {ok, SrcCh} = make_consume_channel(Connection),
    {ok, Connection, DstCh, Connection, SrcCh};
make_connections_and_channels(#{type:=sync,
                                name := Name,
                                dst_config := #{vhost:=DstVHost},
                                src_config := #{vhost:=SrcVHost}}) ->
    {ok, DstConn} = make_connection(<<"Publisher">>, Name, DstVHost),
    {ok, DstCh} = make_publish_channel(DstConn),
    {ok, SrcConn} = make_connection(<<"Consumer">>, Name, SrcVHost),
    {ok, SrcCh} = make_consume_channel(SrcConn),
    {ok, DstConn, DstCh, SrcConn, SrcCh};
make_connections_and_channels(#{type:=async,
                                name := Name,
                                dst_config := #{vhost:=VHost}}) ->
    {ok, Connection} = make_connection(<<"async">>, Name, VHost),
    {ok, DstCh} = make_publish_channel(Connection),
    {ok, Connection, DstCh, none, none}.

%% Подписка на очередь
consume(none,_)->
    ok;
consume(Channel,#{queue := Queue,
                  prefetch_count := PrefCount})->
    amqp_channel:call(Channel, #'basic.qos'{prefetch_count = PrefCount}),
    amqp_channel:subscribe(Channel,
                           #'basic.consume'{queue = Queue},
                           self()).

%%%-------------------------------------------------------------------
%%% Connection functions
%%%-------------------------------------------------------------------

%% Создание подключения
make_connection(Postfix, HandleName, VHost)->
    ConnName = get_connection_name(Postfix, HandleName),
    {ok, AmqpParam} = amqp_uri:parse(get_uri(VHost)),
    case amqp_connection:start(AmqpParam, ConnName) of
        {ok, Conn} ->
            link(Conn),
            {ok, Conn};
        {error, Reason} ->
            throw({error,{connection_not_opened,Reason}})
    end.

%% Закрытие подключений
close_connections(#state{dst_conn=Conn1, src_conn=Conn2})->
    lists:foreach(fun close_connection/1, [Conn1, Conn2]).

%% Закрытие подключения
close_connection(Conn) when is_pid(Conn)->
    catch amqp_connection:close(Conn),
    ok;
close_connection(_) ->
    ok.

%% Генерация URI для подключения
get_uri(<<"/">>)->
    "amqp:///%2f";
get_uri(VHost) ->
    "amqp:///"++binary_to_list(VHost).

%% Функция функция формирования имени подключения
get_connection_name(Postfix, Name)
  when is_atom(Name), is_binary(Postfix) ->
    NameAsBinary = atom_to_binary(Name, utf8),
    get_connection_name(Postfix, NameAsBinary);
get_connection_name(Postfix, Name)
  when is_binary(Name), is_binary(Postfix) ->
    Prefix = <<"RabbitMQ APIv2.0 ">>,
    case Postfix of
        <<>> ->
            <<Prefix/binary, Name/binary>>;
        _ ->
            <<Prefix/binary, Name/binary,
              <<" (">>/binary, Postfix/binary, <<")">>/binary>>
    end;
get_connection_name(_, _) ->
    <<"RabbitMQ APIv2.0">>.

%%%-------------------------------------------------------------------
%%% Channel functions
%%%-------------------------------------------------------------------

%% Создание канала публишера
make_publish_channel(Connection)->
    Channel = make_channel(Connection),
    amqp_channel:register_return_handler(Channel, self()),
    amqp_channel:cast(Channel, #'confirm.select'{}),
    amqp_channel:register_confirm_handler(Channel, self()),
    {ok, Channel}.

%% Создание канало консьюмера
make_consume_channel(Connection)->
    {ok, make_channel(Connection)}.

%% Создание канала
make_channel(Connection)->
    {ok, Ch} = amqp_connection:open_channel(Connection),
    link(Ch),
    Ch.

%% Закрытие каналов
close_channels(#state{consume_ch=ConsCh, publish_ch=PubCh})->
    lists:foreach(fun close_channel/1, [ConsCh, PubCh]).

%% Закрытие канала
close_channel(Ch) when is_pid(Ch)->
    unlink(Ch),
    catch amqp_channel:close(Ch),
    ok;
close_channel(_)->
    ok.

