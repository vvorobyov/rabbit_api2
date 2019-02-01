PROJECT = rabbitmq_api2
PROJECT_DESCRIPTION = API v2.0 plugin for RabbitMQ
PROJECT_VERSION = 0.0.1
PROJECT_MOD = rabbit_api2_app

define PROJECT_ENV
[	{default,[{prefix, "api/v2"},
		  {methods, [post]},
		  {authorization, none},
		  {content_type, <<"application/json">>},
		  {vhost, <<"/">>},
		  {max_body_length, 131072},
		  {delivery_mode, 1},
		  {user_id, none},
		  {app_id, none},
		  {handlers, []},
		  {properties, []},
		  {reconnect_delay, 5},
		  {tcp_config, []},
		  {ssl_config, none},
		  {default_port, 5080},
		  {prefetch_count, 1000},
		  {async_response, {202, "{\"result\":true}"}},
		  {publish_error_response, {500, "{\"result\":false}"}},
		  {internal_error_response, {500, ""}},
		  {timestamp_format, utc},
		  {expiration, timeout},
		  {timeout_response, {504, "TimeOut"}},
		  {bad_request_response, {400, "{\"reason\":\"Request is not valid json\"}"}}
		 ]},
	{allowed, [{methods, [get, post, put, delete]},
		   {timestamp_format, [utc, local]},
		   {expiration, [infinity, timeout]},
		   {type, [sync, async]},
		   {content_type, [<<"application/json">>]},
		   {delivery_mode, [1, 2]}
		  ]},
	{prefix, "api/v2"},
	{tcp_config,[{port, 8080},
		     {cowboy_opts, [{idle_timeout,      10000},
				    {inactivity_timeout,20000},
				    {request_timeout,   5000}]}

		    ]},
	{ssl_config, [{port, 8443},
		      {ssl_opts, [{cacertfile, "/etc/ssl/rmq/ca_certificate.pem"},
				  {certfile,   "/etc/ssl/rmq/server_certificate.pem"},
				  {keyfile,    "/etc/ssl/rmq/server_key.pem"}]},
		      {cowboy_opts, [{idle_timeout,      30000},
				     {inactivity_timeout,40000},
				     {request_timeout,   10000}]}
               ]},
	{handlers,[{handle1,[{type, sync},
			     {timestamp_format, local},
			     {authorization, ["1e0a58af51ef9471c1a30773ea341392"]},
			     {content_type, <<"application/json">>},
			     {methods, [get,post]},
			     {handle, "sync"},
			     {properties,[{delivery_mode,1}]},
			     {source, [{queue, <<"response">>},
				       {vhost, <<"/">>},
				       {declarations, [{'queue.declare',[{queue,<<"response">>}]}]}]},
			     {destination, [{exchange, <<"">>},
					    {routing_key, <<"test_sync">>},
					    {declarations, [{'queue.declare',[{queue,<<"test_sync">>}]}]}]}
			    ]},
		   {handle2,[{type, async},
			     {timestamp_format, local},
			     {authorization, rabbitmq_auth},
			     {content_type, <<"application/json">>},
			     {methods, [get, post]},
			     {handle, "async"},
			     {properties,[{delivery_mode,1},
					  {expiration, timeout}]},
			     {source, [{queue, <<"123">>}]},
			     {destination, [{exchange, <<"">>},
					    {routing_key, <<"test_async">>},
					    {declarations, [{'queue.declare',[{queue,<<"test_async">>}]}]}]}
			    ]}
		  ]}
]
endef

define PROJECT_APP_EXTRA_KEYS
		{broker_version_requirements, []}
endef

DEPS = rabbit_common rabbit amqp_client cowboy cowlib rabbitmq_web_dispatch rabbitmq_management
TEST_DEPS = rabbitmq_ct_helpers rabbitmq_ct_client_helpers rabbitmq_amqp1_0
LOCAL_DEPS += mnesia ranch ssl crypto public_key

# FIXME: Add Ranch as a BUILD_DEPS to be sure the correct version is picked.
# See rabbitmq-components.mk.
BUILD_DEPS += ranch

DEP_EARLY_PLUGINS = rabbit_common/mk/rabbitmq-early-plugin.mk
DEP_PLUGINS = rabbit_common/mk/rabbitmq-plugin.mk cowboy

ERLANG_MK_REPO = https://github.com/rabbitmq/erlang.mk.git
ERLANG_MK_COMMIT = rabbitmq-tmp

include rabbitmq-components.mk
include erlang.mk
