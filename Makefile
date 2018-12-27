PROJECT = rabbitmq_api2
PROJECT_DESCRIPTION = API v2.0 plugin for RabbitMQ
PROJECT_VERSION = 0.0.0
PROJECT_MOD = rabbit_api2_app

define PROJECT_ENV
[	{default,[{prefix, "api/v2"},
						{methods, [post]},
						{authorization, rabbitmq_auth},
						{content_type, <<"application/json">>},
						{vhost, <<"/">>},
						{async_response, none},
						{max_body_length, 131072},
						{delivery_mode, 1},
						{user_id, none},
						{app_id, none},
						{handlers, []}
	]},
	{allowed, [{methods, [get, post, put, delete]},
						 {type, [sync, async]},
						 {content_type, [<<"application/json">>]},
						 {delivery_mode, [1, 2]}
	]},
	{handlers,[
             {handle1,[{type, sync},
                       {authorization, "qwefsddf"},
                       {content_type, <<"application/json">>},
                       {methods, [get,post, put, delete]},
                       {handle, "handle"},
                       {source, [{queue, <<"123">>}]},
                       {destination, [{exchange, <<"">>},
                                     {routing_key, <<"">>}]}]}
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
