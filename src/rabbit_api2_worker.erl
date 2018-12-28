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
                dst_config}).

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
    amqp_channel:register_return_handler(DstCh, self()),
    amqp_channel:register_confirm_handler(DstCh, self()),
    {ok, #state{
            name=Name,
            type=Type,
            dst_conn=DstConn,
            src_conn=SrcConn,
            publish_ch=DstCh,
            consume_ch=SrcCh,
            dst_config=DstConfig,
            src_config=SrcConfig}}.

handle_call({request, Msg}, _From, State) ->
    Request = publish_message(State#state.publish_ch,
                              Msg,
                              State#state.dst_config),
    {reply, io_lib:format("~p",[Request]),State};
handle_call(_Request, _From, State) ->
    Reply = ok,
    {noreply, Reply, State}.

handle_cast(_Request, State) ->
    {noreply, State}.

%% handle_info({_,_}, State) ->
%%     io:format("~p~n",[_Info]),
%%     {noreply, State};
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
publish_message(Channel,
                Message=#amqp_msg{},
                #{exchange:=Exchange,
                  routing_key:=RoutingKey})->
    amqp_channel:call(Channel,
                      #'basic.publish'{
                         exchange=Exchange,
                         mandatory=true,
                         routing_key=RoutingKey},
                      Message).

make_connections_and_channels(#{type:=sync,
                                name := Name,
                                dst_config := #{vhost:=VHost},
                                src_config := #{vhost:=VHost}})->
    ConnName = get_connection_name(Name),
    {ok,Connection} = make_connection(ConnName, VHost),
    DstCh = make_channel(Connection),
    SrcCh = make_channel(Connection),
    {ok,Connection, DstCh, Connection, SrcCh};
make_connections_and_channels(#{type:=sync,
                                name := Name,
                                dst_config := #{vhost:=DstVHost},
                                src_config := #{vhost:=SrcVHost}}) ->
    DstConnName = get_connection_name(<<"Publisher">>, Name),
    {ok, DstConn} = make_connection(DstConnName, DstVHost),
    DstCh = make_channel(DstConn),
    SrcConnName = get_connection_name(<<"Consumer">>, Name),
    {ok, SrcConn} = make_connection(SrcConnName, SrcVHost),
    SrcCh = make_channel(SrcConn),
    {ok, DstConn, DstCh, SrcConn, SrcCh};
make_connections_and_channels(#{type:=async,
                                name := Name,
                                dst_config := #{vhost:=VHost}}) ->
    ConnName = get_connection_name(Name),
    {ok, Connection} = make_connection(ConnName, VHost),
    DstCh = make_channel(Connection),
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

