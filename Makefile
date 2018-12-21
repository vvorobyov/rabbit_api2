PROJECT = rabbit_api2
PROJECT_DESCRIPTION = API v2.0 plugin for RabbitMQ
PROJECT_VERSION = 0.0.0
PROJECT_MOD = rabbit_api2_app

define PROJECT_ENV
[ {ssl_config, [ {port, 8443},
								 {ssl_opts, [{cacertfile, "/etc/ssl/rmq/ca_certificate.pem"},
		                         {certfile,   "/etc/ssl/rmq/server_certificate.pem"},
				                     {keyfile,    "/etc/ssl/rmq/server_key.pem"}]}
								 ]},
	{handlers,[{handler1, [{type, sync}]},
						 {handler2, [{type, async}]}

		]}
]
endef

define PROJECT_APP_EXTRA_KEYS
		{broker_version_requirements, []}
endef

DEPS = rabbit_common rabbit amqp_client cowboy cowlib rabbitmq_web_dispatch
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
