-define(DEFAULT_PORT, 5080).

-record(worker, {name,
                 dst_config,
                 src_config}).
