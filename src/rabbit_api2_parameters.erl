%%%-------------------------------------------------------------------
%%% @author Vladislav Vorobyov <vlad@erldev>
%%% @copyright (C) 2019, Vladislav Vorobyov
%%% @doc
%%%
%%% @end
%%% Created : 31 Jan 2019 by Vladislav Vorobyov <vlad@erldev>
%%%-------------------------------------------------------------------
-module(rabbit_api2_parameters).
-behaviour(rabbit_runtime_parameter).

-rabbit_boot_step({?MODULE,
                   [{description, "RabbitMQ API2 plugin parameters"},
                    {mfa, {rabbit_api2_parameters, register, []}},
                    {cleanup, {?MODULE, unregister, []}},
                    {requires, rabbit_registry},
                    {enables, recovery}]}).

-export([validate/5, notify/5, notify_clear/4]).

%% API
-export([register/0, unregister/0]).

%%%===================================================================
%%% API
%%%===================================================================
register()->
    rabbit_registry:register(runtime_parameter, <<"api2">>, ?MODULE).
unregister()->
    rabbit_registry:unregister(runtime_parameter, <<"api2">>).

%%%===================================================================
%%% Callbacks
%%%===================================================================
%% Валидация параметров
validate(VHost,<<"api2">>, Name, Def0, User)->
    io:format("~nValidate: ~nVHost: ~p~nName: ~p~n Def: ~p~n User: ~p~n",
	      [VHost, Name, Def0, User]),
    case lists:member(erlang:binary_to_atom(Name, unicode),
		      global:registered_names()) of
	true -> {error, "Name '~ts' used to other process", [Name]};
	false ->
	    try
		Def = rabbit_data_coercion:to_proplist(Def0),
		Config = make_config(Def),
		rabbit_api2_config:parse_handler(Name, Config),
		io:format("Config: ~p", [Config]),
		ok
	    catch
		throw:Error ->
		    Error
	    end
    end;
validate(_VHost, _Component, Name, _Def, _User) ->
     {error, "name not recognised: ~p", [Name]}.

%% Запуск процесса
notify(_VHost, <<"api2">>, _Name, _Definition, _Username)->
%    io:format("Notify: ~nVHost: ~p~nName: ~p~n Def: ~p~n",
%	      [VHost, Name, Definition]),
    ok.

%% Остановка параметра
notify_clear(VHost, <<"api2">>, Name, _Username)->    
    io:format("Notify_clear: ~nVHost: ~p~nName: ~p~n", [VHost, Name]),
    ok.
    
%%--------------------------------------------------------------------
%% @doc
%% @spec
%% @end
%%--------------------------------------------------------------------

%%%===================================================================
%%% Internal functions
%%%===================================================================
make_config(Config0)->
    Config1 = lists:foldl(fun ({Key, Value}, Acc)->
			convert_value(
			  {string:lowercase(Key), Value}, Acc)
			 end, #{}, Config0),
    Config2 = case maps:find(properties, Config1) of
		  {ok, Value2} ->
		      Config1#{properties => maps:to_list(Value2)};
		  error ->
		      Config1
	      end,
    Config3 = case maps:find(destination, Config2) of
		  {ok, Value3} ->
		      Config2#{destination => maps:to_list(Value3)};
		  error ->
		      Config2
	      end,
    Config4 = case maps:find(source, Config3) of
		  {ok, Value4} ->
		      Config3#{source => maps:to_list(Value4)};
		  error ->
		      Config3
	      end,
    maps:to_list(Config4).

convert_value({<<"handle">>, Value}, Acc)->
    if
	is_binary(Value) ->
	    Acc#{handle => erlang:binary_to_list(Value)};
	true ->
	    throw({error,
		   "invalid handle type. Expected string. Value: ~p",
		   [Value]})
    end;
convert_value({<<"methods">>, Value}, Acc) ->
    if
	is_list(Value) ->
	    Acc#{methods => lists:map(fun parse_method/1, Value)};
	is_binary(Value) ->
	    Acc#{methods => [parse_method(Value)]};
	true ->
	    throw({error,
		   "invalid methods type. "
		   "Expected string or array. Value: ~p",
		   [Value]})
		
    end;
convert_value({<<"auth">>, Value}, Acc) ->
    if
	is_list(Value) ->
	    Acc#{authorization=>Value};
	Value =:= <<"rabbitmq_auth">> ->
	    Acc#{authorization=>rabbitmq_auth};
	true ->
	    throw({error,
		   "invalid Auth type. "
		   "Expected \"rabbitmq_auth\" or array of hashes. "
		   "Value: ~p"
		   "~nTo generate hash use "
		   "\"rabbitmqctl eval 'rabbitmq_api2:gen_auth_hash"
		   "(USERNAME, PASSWORD)'\"",
		   [Value]})
    end;
convert_value({<<"type">>, Value}, Acc) ->
    if
	is_binary(Value) ->
	    case string:lowercase(Value) of
		<<"sync">> -> Acc#{type=>sync};
		<<"async">> -> Acc#{type=>async};
		_ ->
		    throw({error,
			   "invalid value of 'type'. "
			   "Expected 'sync' or 'async'. "
			   "Value: ~p",
			   [Value]})
	    end;
	true ->
	    throw({error,
		   "invalid type of filed 'type'. "
		   "Expected string or array. Value: ~p",
		   [Value]})
    end;
convert_value({Name, Value}, Acc)
  when Name =:= <<"async-resp">>; Name =:= <<"publ-err-resp">>;
       Name=:= <<"int-err-resp">>; Name=:= <<"timeout-resp">> ->
    case {Name,
	  parse_response(rabbit_data_coercion:to_map(Value))} of
	{<<"async-resp">>, {value, Response}} ->
	    Acc#{async_response => Response};
	{<<"publ-err-resp">>, {value, Response}} ->
	    Acc#{publish_error_response => Response};
	{<<"int-err-resp">>, {value, Response}} ->
	    Acc#{internal_error_response => Response};
	{<<"timeout-resp">>, {value, Response}} ->
	    Acc#{timeout_response => Response};
	{_, error} ->
	    throw({error,
		   "invalid '~s' value. "
		   "Expected object format '{\"code\": Code, \"body\": Body}.'"
		   "When Code is number betwean 100 and 599, "
		   "Body is string",
		   [Name]})
    end;
convert_value({<<"content-type">>, Value}, Acc) ->
    if
	is_binary(Value) ->
	    Acc#{content_type=>Value};
	true ->
	    throw({error,
		   "invalid type of filed 'content-type'. "
		   "Expected string. Value: ~p", [Value]})
    end;
convert_value({<<"max-body-length">>, Value}, Acc) ->
    if
	is_integer(Value) andalso Value > 0 ->
	    Acc#{max_body_length=>Value};
	true ->
	    throw({error,
		   "invalid type of filed 'max-body-length'. "
		   "Expected integer above zero. Value: ~p", [Value]})
    end;
convert_value({<<"timestamp">>, Value}, Acc) ->
    if
	is_binary(Value) -> 
	    case string:lowercase(Value) of
		<<"utc">> -> Acc#{timestamp_format=>utc};
		<<"local">> -> Acc#{timestamp_format=>local};
		_ -> 
		    throw({error,
			   "invalid value of 'timestamp'. "
			   "Expected 'utc' or 'local'. "
			   "Value: ~p",
			   [Value]})
	    end;
	true ->
	    throw({error,
		   "invalid type of 'timestamp'. "
		   "Expected string. "
		   "Value: ~p",
		   [Value]})
    end;
convert_value({<<"expiration">>, Value}, Acc) ->
    if
	is_binary(Value) -> 
	    case string:lowercase(Value) of
		<<"infinity">> -> add_to_map(properties,
					     expiration,
					     infinity,
					     Acc);
		<<"timeout">> -> add_to_map(properties,
					    expiration,
					    timeout,
					    Acc);
		_ -> 
		    throw({error,
			   "invalid value of 'expiration'. "
			   "Expected 'infinity' or 'timeout'. "
			   "Value: ~p",
			   [Value]})
	    end;
	true ->
	    throw({error,
		   "invalid type of 'expiration'. "
		   "Expected string. "
		   "Value: ~p",
		   [Value]})
    end;
convert_value({<<"user-id">>, Value}, Acc) ->
    if
	is_binary(Value) ->
	    add_to_map(properties, user_id, Value, Acc);
	true ->
	    throw({error,
		   "invalid type of 'user-id'. "
		   "Expected string. "
		   "Value: ~p",
		   [Value]})
    end;
convert_value({<<"app-id">>, Value}, Acc) ->
    if
	is_binary(Value) ->
	    add_to_map(properties, app_id, Value, Acc);
	true ->
	    throw({error,
		   "invalid type of 'app-id'. "
		   "Expected string. "
		   "Value: ~p",
		   [Value]})
    end;
convert_value({<<"delivery-mode">>, Value}, Acc) ->
    if
	Value=:=1; Value=:=2 ->
	    add_to_map(properties, delivery_mode, Value, Acc);
	true ->
	    throw({error,
		   "invalid type of 'delivery-mode'. "
		   "Expected 1 for 'Non-persistent', 2 for 'Persistent'. "
		   "Value: ~p",
		   [Value]})
    end;
convert_value({<<"dst-vhost">>, Value}, Acc) ->
    if
	is_binary(Value) ->
	    add_to_map(destination, vhost, Value, Acc);
	true ->
	    throw({error,
		   "invalid type of 'dst-vhost'. "
		   "Expected string. "
		   "Value: ~p",
		   [Value]})
    end;
convert_value({<<"dst-exchange">>, Value}, Acc) ->
    if
	is_binary(Value) ->
	    add_to_map(destination, exchange, Value, Acc);
	true ->
	    throw({error,
		   "invalid type of 'dst-exchange'. "
		   "Expected string. "
		   "Value: ~p",
		   [Value]})
    end;
convert_value({<<"dst-route-key">>, Value}, Acc) ->
    if
	is_binary(Value) ->
	    add_to_map(destination, routing_key, Value, Acc);
	true ->
	    throw({error,
		   "invalid type of 'dst-route-key'. "
		   "Expected string. "
		   "Value: ~p",
		   [Value]})
    end;
convert_value({<<"src-vhost">>, Value}, Acc) ->
    if
	is_binary(Value) ->
	    add_to_map(source, vhost, Value, Acc);
	true ->
	    throw({error,
		   "invalid type of 'src-vhost'. "
		   "Expected string. "
		   "Value: ~p",
		   [Value]})
    end;
convert_value({<<"src-queue">>, Value}, Acc) ->
    if
	is_binary(Value) ->
	    add_to_map(source, queue, Value, Acc);
	true ->
	    throw({error,
		   "invalid type of 'src-queue'. "
		   "Expected string. "
		   "Value: ~p",
		   [Value]})
    end;
convert_value({Key, Value}, _) ->
    throw({error,
	   "Unknown key '~s'. "
	   "Value: ~p",
	   [Key,Value]}).

add_to_map(Section, Key, Value, Map)->
    SubMap = maps:get(Section, Map, #{}),
    Map#{Section=> SubMap#{Key=>Value}}.
		
parse_method(Value) when is_binary(Value)->
    case string:uppercase(Value) of
	<<"GET">> -> get;
	<<"POST">> -> post;
	<<"PUT">> -> put;
	<<"DELETE">> -> delete;
	_ ->
	    throw({error,
		   "invalid method value."
		   " Allowed: \"GET\", \"POST\", \"PUT\", \"DELETE\"."
		   "Value: ~p",
		   [Value]})
    end;
parse_method(Value) ->
    throw({error,
	   "invalid method value type. Expected string. Value: ~p",
	   [Value]}).

parse_response(#{<<"code">> := Code, <<"body">> := Body})
  when is_number(Code),
       Code >= 100,
       Code < 600,
       is_binary(Body) ->
    {value, {Code, Body}};
parse_response(Val) ->
    io:format("~n~p",[Val]),
    error.


	
