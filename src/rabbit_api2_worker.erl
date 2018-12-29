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
                wait_ack=[],
                wait_response=[]}).

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
    {ok,DstConn, DstCh, SrcConn, SrcCh} =
        make_connections_and_channels(Config),
    {ok, #state{
            name=Name,
            type=Type,
            dst_conn=DstConn,
            src_conn=SrcConn,
            publish_ch=DstCh,
            consume_ch=SrcCh,
            dst_config=DstConfig,
            src_config=SrcConfig}}.

handle_call({request, Msg}, From, S=#state{}) ->
    MessageID = publish_message(
                  S#state.publish_ch, Msg, S#state.dst_config),
    register_wait(MessageID, From, S);
handle_call(_Request, _From, State) ->
    Reply = ok,
    {noreply, Reply, State}.

handle_cast(_Request, State) ->
    {noreply, State}.

handle_info(Info = {#'basic.return'{},#amqp_msg{}}, State) ->
    register_return(Info, State);
handle_info(Info = #'basic.ack'{}, State) ->
    register_ack(Info, State);
handle_info(Info = #'basic.nack'{}, State) ->
    register_nack(Info, State);
handle_info(#'basic.consume_ok'{consumer_tag=ConsTag},S) ->
    {noreply, S#state{consumer_tag=ConsTag}};
handle_info(Info = {#'basic.deliver'{consumer_tag=ConsTag},#amqp_msg{}},
            S=#state{consumer_tag=ConsTag})->
    register_response(Info, S);
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
register_response({#'basic.deliver'{delivery_tag=Tag},
                   Msg}, S=#state{consume_ch= Ch})->

    amqp_channel:cast(Ch,#'basic.ack'{})
    {noreply, S}.

register_wait(MessageID, From, S)->
    DeliveryTag = S#state.current_delivery_tag,
    WaitAck = [{DeliveryTag, MessageID, From}|S#state.wait_ack],
    WaitResponse =case S#state.type  of
                      sync -> [{MessageID, From}| S#state.wait_response];
                      async -> S#state.wait_response
                  end,

    {noreply, S#state{wait_ack=WaitAck,
                      wait_response=WaitResponse,
                      current_delivery_tag=DeliveryTag+1}}.

register_return({#'basic.return'{reply_text=Reason},
                 #amqp_msg{
                   props=#'P_basic'{message_id=MessageID}}},
                S=#state{})->
    {_, MessageID, From} = lists:keyfind(MessageID, 2, S#state.wait_ack),
    WaitAck = lists:keydelete(MessageID, 2, S#state.wait_ack),
    WaitResponse = lists:keydelete(MessageID, 1, S#state.wait_response),
    gen_server2:reply(From, {publish_error, Reason}),
    {noreply, S#state{wait_ack = WaitAck,
                      wait_response = WaitResponse}}.

register_ack(#'basic.ack'{delivery_tag = DeliveryTag}, S)->
    case lists:keyfind(DeliveryTag, 1, S#state.wait_ack) of
        {DeliveryTag, _, From} ->
            WaitAck = lists:keydelete(DeliveryTag, 1, S#state.wait_ack),
            case S#state.type of
                async ->
                    gen_server2:reply(From, {publish_ok,<<"publish_ok">>});
                sync -> ok
            end,
            {noreply, S#state{wait_ack = WaitAck}};
        false -> {noreply, S}
    end.

register_nack(#'basic.nack'{delivery_tag=DeliveryTag}, S=#state{})->
    case lists:keyfind(DeliveryTag, 1, S#state.wait_ack) of
        {DeliveryTag, MessageID, From} ->
            WaitAck = lists:keydelete(DeliveryTag, 1, S#state.wait_ack),
            WaitResponse = lists:keydelete(MessageID, 1, S#state.wait_response),
            gen_server2:reply(From, {publish_error, <<"Server Return nack">>}),
            {noreply, S#state{wait_ack = WaitAck,
                              wait_response = WaitResponse}};
        false ->
            {noreply, S}
    end.

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

