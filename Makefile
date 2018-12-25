PROJECT = rabbit_api2
PROJECT_DESCRIPTION = API v2.0 plugin for RabbitMQ
PROJECT_VERSION = 0.0.0
PROJECT_MOD = rabbit_api2_app

define PROJECT_ENV
[ {tcp_config, [ {port, 8443},
								 {ssl_opts, [{cacertfile, "/etc/ssl/rmq/ca_certificate.pem"},
		                         {certfile,   "/etc/ssl/rmq/server_certificate.pem"},
				                     {keyfile,    "/etc/ssl/rmq/server_key.pem"}]},
								 {cowboy_opts, [{idle_timeout,      120000},
                                {inactivity_timeout,120000},
                                {request_timeout,   120000}]}
								 ]},
	{prefix, "/api/test/"},
	{handlers,[{handler1, [{type, sync},
												 {handle, "/api2/handle1"},
												 {methods, [get]},
												 {authorization, ["179988ddc329fd90a420bc1a5835d3f7",
																					"1899e39494676f218922307bd8f43417"]},
												 {destination, [{uris,["amqps://test:test@10.232.5.11/%2f",
																							 "amqps://test:test@10.232.5.12/test"]},
																				{exchange, <<"test">>},
																				{routing_key, <<"test.rt">>}]},
												 {source, []}]},
						 {handler2, [{type, async},
												 {handle, "api2/handle2"},
												 {destination, [{uris,["amqp://test:test@10.232.5.11/%2f"]},
																				{exchange, <<"test">>},
																				{routing_key, <<"test.rt">>}]}
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
