%%--------------------------------------------------------------------
%% Copyright (c) 2023 EMQ Technologies Co., Ltd. All Rights Reserved.
%%--------------------------------------------------------------------

-ifndef(EMQX_EE_SCHEMA_REGISTRY_HRL).
-define(EMQX_EE_SCHEMA_REGISTRY_HRL, true).

-define(CONF_KEY_ROOT, schema_registry).
-define(CONF_KEY_PATH, [?CONF_KEY_ROOT]).

-define(SCHEMA_REGISTRY_SHARD, emqx_ee_schema_registry_shard).
-define(SERDE_TAB, emqx_ee_schema_registry_serde_tab).

-type schema_name() :: binary().
-type schema_source() :: binary().

-type encoded_data() :: iodata().
-type decoded_data() :: map().
-type serializer() :: fun((decoded_data()) -> encoded_data()).
-type deserializer() :: fun((encoded_data()) -> decoded_data()).
-type destructor() :: fun(() -> ok).
-type serde_type() :: avro.
-type serde_opts() :: map().

-record(serde, {
    name :: schema_name(),
    serializer :: serializer(),
    deserializer :: deserializer(),
    destructor :: destructor()
}).
-type serde() :: #serde{}.
-type serde_map() :: #{
    name := schema_name(),
    serializer := serializer(),
    deserializer := deserializer(),
    destructor := destructor()
}.

-endif.