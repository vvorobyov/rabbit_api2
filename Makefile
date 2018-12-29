PROJECT = rabbitmq_api2
PROJECT_DESCRIPTION = API v2.0 plugin for RabbitMQ
PROJECT_VERSION = 0.0.0
PROJECT_MOD = rabbit_api2_app

define PROJECT_ENV
[	{default,[{prefix, "api/v2"},
						{methods, [post]},
						{authorization, none},
						{content_type, <<"application/json">>},
						{vhost, <<"/">>},
						{async_response, none},
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
            {prefetch_count, 1000}
           ]},
	{allowed, [{methods, [get, post, put, delete]},
						 {type, [sync, async]},
						 {content_type, [<<"application/json">>]},
						 {delivery_mode, [1, 2]}
            ]},
  {prefix, "api2"},
  {tcp_config,[{port, 8080}]},
	{ssl_config, [{port, 8443},
                {ssl_opts, [{cacertfile, "/etc/ssl/rmq/ca_certificate.pem"},
                            {certfile,   "/etc/ssl/rmq/server_certificate.pem"},
                            {keyfile,    "/etc/ssl/rmq/server_key.pem"}]},
                {cowboy_opts, [{idle_timeout,      120000},
                               {inactivity_timeout,120000},
                               {request_timeout,   120000}]}
               ]},
	{handlers,[{handle1,[{type, sync},
                       {authorization, ["1e0a58af51ef9471c1a30773ea341392"]},
                       {content_type, <<"application/json">>},
                       {methods, [get]},
                       {handle, "handle"},
                       {properties,[{delivery_mode,2}]},
                       {source, [{queue, <<"test">>},
                                {vhost, <<"test">>}]},
                       {destination, [{exchange, <<"">>},
                                      {routing_key, <<"test">>}]}
                      ]},
             {handle2,[{type, async},
                       {authorization, ["1e0a58af51ef9471c1a30773ea341392"]},
                       {content_type, <<"application/json">>},
                       {methods, [get]},
                       {handle, "handle2"},
                       {properties,[{delivery_mode,2}]},
                       {source, [{queue, <<"123">>},
                                 {vhost, <<"test">>}]},
                       {destination, [{exchange, <<"">>},
                                      {routing_key, <<"test">>}]}
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
