%%--------------------------------------------------------------------
%% Copyright (c) 2022-2023 EMQ Technologies Co., Ltd. All Rights Reserved.
%%--------------------------------------------------------------------
-module(emqx_node_rebalance_api).

-behaviour(minirest_api).

-include_lib("typerefl/include/types.hrl").
-include_lib("hocon/include/hoconsc.hrl").
-include_lib("emqx/include/logger.hrl").

%% Swagger specs from hocon schema
-export([
    api_spec/0,
    paths/0,
    schema/1,
    namespace/0
]).

-export([
    fields/1,
    roots/0
]).

%% API callbacks
-export([
    '/load_rebalance/status'/2,
    '/load_rebalance/global_status'/2,
    '/load_rebalance/availability_check'/2,
    '/load_rebalance/:node/start'/2,
    '/load_rebalance/:node/stop'/2,
    '/load_rebalance/:node/evacuation/start'/2,
    '/load_rebalance/:node/evacuation/stop'/2
]).

%% Schema examples
-export([
    rebalance_example/0,
    rebalance_evacuation_example/0,
    translate/2
]).

-import(hoconsc, [mk/2, ref/1, ref/2]).
-import(emqx_dashboard_swagger, [error_codes/2]).

-define(BAD_REQUEST, 'BAD_REQUEST').
-define(NODE_UNAVAILABLE, 'NODE_UNAVAILABLE').
-define(NODE_EVACUATING, 'NODE_EVACUATING').
-define(RPC_ERROR, 'RPC_ERROR').

%%--------------------------------------------------------------------
%% API Spec
%%--------------------------------------------------------------------

namespace() -> "load_rebalance".

api_spec() ->
    emqx_dashboard_swagger:spec(?MODULE, #{check_schema => true}).

paths() ->
    [
        "/load_rebalance/status",
        "/load_rebalance/global_status",
        "/load_rebalance/availability_check",
        "/load_rebalance/:node/start",
        "/load_rebalance/:node/stop",
        "/load_rebalance/:node/evacuation/start",
        "/load_rebalance/:node/evacuation/stop"
    ].

schema("/load_rebalance/status") ->
    #{
        'operationId' => '/load_rebalance/status',
        get => #{
            tags => [<<"load_rebalance">>],
            summary => <<"Get rebalance status">>,
            description => ?DESC("load_rebalance_status"),
            responses => #{
                200 => local_status_response_schema()
            }
        }
    };
schema("/load_rebalance/global_status") ->
    #{
        'operationId' => '/load_rebalance/global_status',
        get => #{
            tags => [<<"load_rebalance">>],
            summary => <<"Get global rebalance status">>,
            description => ?DESC("load_rebalance_global_status"),
            responses => #{
                200 => response_schema()
            }
        }
    };
schema("/load_rebalance/availability_check") ->
    #{
        'operationId' => '/load_rebalance/availability_check',
        get => #{
            tags => [<<"load_rebalance">>],
            summary => <<"Node rebalance availability check">>,
            description => ?DESC("load_rebalance_availability_check"),
            responses => #{
                200 => response_schema(),
                503 => error_codes([?NODE_EVACUATING], <<"Node Evacuating">>)
            }
        }
    };
schema("/load_rebalance/:node/start") ->
    #{
        'operationId' => '/load_rebalance/:node/start',
        post => #{
            tags => [<<"load_rebalance">>],
            summary => <<"Start rebalancing with the node as coordinator">>,
            description => ?DESC("load_rebalance_start"),
            parameters => [param_node()],
            'requestBody' =>
                emqx_dashboard_swagger:schema_with_examples(
                    ref(rebalance_start),
                    rebalance_example()
                ),
            responses => #{
                200 => response_schema(),
                400 => error_codes([?BAD_REQUEST, ?NODE_UNAVAILABLE], <<"Bad Request">>)
            }
        }
    };
schema("/load_rebalance/:node/stop") ->
    #{
        'operationId' => '/load_rebalance/:node/stop',
        post => #{
            tags => [<<"load_rebalance">>],
            summary => <<"Stop rebalancing coordinated by the node">>,
            description => ?DESC("load_rebalance_stop"),
            parameters => [param_node()],
            responses => #{
                200 => response_schema(),
                400 => error_codes([?BAD_REQUEST, ?NODE_UNAVAILABLE], <<"Bad Request">>)
            }
        }
    };
schema("/load_rebalance/:node/evacuation/start") ->
    #{
        'operationId' => '/load_rebalance/:node/evacuation/start',
        post => #{
            tags => [<<"load_rebalance">>],
            summary => <<"Start evacuation on a node">>,
            description => ?DESC("load_rebalance_evacuation_start"),
            parameters => [param_node()],
            'requestBody' =>
                emqx_dashboard_swagger:schema_with_examples(
                    ref(rebalance_evacuation_start),
                    rebalance_evacuation_example()
                ),
            responses => #{
                200 => response_schema(),
                400 => error_codes([?BAD_REQUEST, ?NODE_UNAVAILABLE], <<"Bad Request">>)
            }
        }
    };
schema("/load_rebalance/:node/evacuation/stop") ->
    #{
        'operationId' => '/load_rebalance/:node/evacuation/stop',
        post => #{
            tags => [<<"load_rebalance">>],
            summary => <<"Stop evacuation on a node">>,
            description => ?DESC("load_rebalance_evacuation_stop"),
            parameters => [param_node()],
            responses => #{
                200 => response_schema(),
                400 => error_codes([?BAD_REQUEST, ?NODE_UNAVAILABLE], <<"Bad Request">>)
            }
        }
    }.

%%--------------------------------------------------------------------
%% Handlers
%%--------------------------------------------------------------------

'/load_rebalance/status'(get, #{}) ->
    case emqx_node_rebalance_status:local_status() of
        disabled ->
            {200, #{status => disabled}};
        {rebalance, Stats} ->
            {200, format_status(rebalance, Stats)};
        {evacuation, Stats} ->
            {200, format_status(evacuation, Stats)}
    end.

'/load_rebalance/global_status'(get, #{}) ->
    #{
        evacuations := Evacuations,
        rebalances := Rebalances
    } = emqx_node_rebalance_status:global_status(),
    {200, #{
        evacuations => format_as_map_list(Evacuations),
        rebalances => format_as_map_list(Rebalances)
    }}.

'/load_rebalance/availability_check'(get, #{}) ->
    case emqx_eviction_agent:status() of
        disabled ->
            {200, #{}};
        {enabled, _Stats} ->
            error_response(503, ?NODE_EVACUATING, <<"Node Evacuating">>)
    end.

'/load_rebalance/:node/start'(post, #{bindings := #{node := NodeBin}, body := Params0}) ->
    with_node(NodeBin, fun(Node) ->
        Params1 = translate(rebalance_start, Params0),
        with_nodes_at_key(nodes, Params1, fun(Params2) ->
            wrap_rpc(
                Node, emqx_node_rebalance_api_proto_v1:node_rebalance_start(Node, Params2)
            )
        end)
    end).

'/load_rebalance/:node/stop'(post, #{bindings := #{node := NodeBin}}) ->
    with_node(NodeBin, fun(Node) ->
        wrap_rpc(
            Node, emqx_node_rebalance_api_proto_v1:node_rebalance_stop(Node)
        )
    end).

'/load_rebalance/:node/evacuation/start'(post, #{
    bindings := #{node := NodeBin}, body := Params0
}) ->
    with_node(NodeBin, fun(Node) ->
        Params1 = translate(rebalance_evacuation_start, Params0),
        with_nodes_at_key(migrate_to, Params1, fun(Params2) ->
            wrap_rpc(
                Node,
                emqx_node_rebalance_api_proto_v1:node_rebalance_evacuation_start(
                    Node, Params2
                )
            )
        end)
    end).

'/load_rebalance/:node/evacuation/stop'(post, #{bindings := #{node := NodeBin}}) ->
    with_node(NodeBin, fun(Node) ->
        wrap_rpc(
            Node, emqx_node_rebalance_api_proto_v1:node_rebalance_evacuation_stop(Node)
        )
    end).

%%--------------------------------------------------------------------
%% Helpers
%%--------------------------------------------------------------------

wrap_rpc(Node, RPCResult) ->
    case RPCResult of
        ok ->
            {200, #{}};
        {error, Reason} ->
            error_response(
                400, ?BAD_REQUEST, io_lib:format("error on node ~p: ~p", [Node, Reason])
            );
        {badrpc, Reason} ->
            error_response(
                503, ?RPC_ERROR, io_lib:format("RPC error on node ~p: ~p", [Node, Reason])
            )
    end.

format_status(Process, Stats) ->
    Stats#{process => Process, status => enabled}.

validate_nodes(Key, Params) when is_map_key(Key, Params) ->
    BinNodes = maps:get(Key, Params),
    {ValidNodes, InvalidNodes} = lists:foldl(
        fun(BinNode, {Nodes, UnknownNodes}) ->
            case parse_node(BinNode) of
                {ok, Node} -> {[Node | Nodes], UnknownNodes};
                {error, _} -> {Nodes, [BinNode | UnknownNodes]}
            end
        end,
        {[], []},
        BinNodes
    ),
    case InvalidNodes of
        [] ->
            case emqx_node_rebalance_evacuation:available_nodes(ValidNodes) of
                ValidNodes -> {ok, Params#{Key => ValidNodes}};
                OtherNodes -> {error, {unavailable, ValidNodes -- OtherNodes}}
            end;
        _ ->
            {error, {invalid, InvalidNodes}}
    end;
validate_nodes(_Key, Params) ->
    {ok, Params}.

with_node(BinNode, Fun) ->
    case parse_node(BinNode) of
        {ok, Node} -> Fun(Node);
        {error, _} -> error_response(400, ?BAD_REQUEST, [<<"Invalid node: ">>, BinNode])
    end.

with_nodes_at_key(Key, Params, Fun) ->
    Res = validate_nodes(Key, Params),
    case Res of
        {ok, Params1} ->
            Fun(Params1);
        {error, {unavailable, Nodes}} ->
            error_response(400, ?NODE_UNAVAILABLE, io_lib:format("Nodes unavailable: ~p", [Nodes]));
        {error, {invalid, Nodes}} ->
            error_response(400, ?BAD_REQUEST, io_lib:format("Invalid nodes: ~p", [Nodes]))
    end.

parse_node(Bin) when is_binary(Bin) ->
    try
        {ok, binary_to_existing_atom(Bin)}
    catch
        error:badarg ->
            {error, {unknown, Bin}}
    end.

format_as_map_list(List) ->
    lists:map(
        fun({Node, Info}) ->
            Info#{node => Node}
        end,
        List
    ).

error_response(HttpCode, Code, Message) ->
    {HttpCode, #{
        code => atom_to_binary(Code),
        message => iolist_to_binary(Message)
    }}.

without(Keys, Props) ->
    lists:filter(
        fun({Key, _}) ->
            not lists:member(Key, Keys)
        end,
        Props
    ).

%%------------------------------------------------------------------------------
%% Schema
%%------------------------------------------------------------------------------

translate(Ref, Conf) ->
    Options = #{atom_key => true},
    #{Ref := TranslatedConf} = hocon_tconf:check_plain(
        ?MODULE, #{atom_to_binary(Ref) => Conf}, Options, [Ref]
    ),
    TranslatedConf.

param_node() ->
    {
        node,
        mk(binary(), #{
            in => path,
            desc => ?DESC(param_node),
            required => true
        })
    }.

fields(rebalance_start) ->
    [
        {"wait_health_check",
            mk(
                emqx_schema:duration_s(),
                #{
                    desc => ?DESC(wait_health_check),
                    required => false
                }
            )},
        {"conn_evict_rate",
            mk(
                pos_integer(),
                #{
                    desc => ?DESC(conn_evict_rate),
                    required => false
                }
            )},
        {"sess_evict_rate",
            mk(
                pos_integer(),
                #{
                    desc => ?DESC(sess_evict_rate),
                    required => false
                }
            )},
        {"abs_conn_threshold",
            mk(
                pos_integer(),
                #{
                    desc => ?DESC(abs_conn_threshold),
                    required => false
                }
            )},
        {"rel_conn_threshold",
            mk(
                number(),
                #{
                    desc => ?DESC(rel_conn_threshold),
                    required => false,
                    validator => [fun(Value) -> Value > 1.0 end]
                }
            )},
        {"abs_sess_threshold",
            mk(
                pos_integer(),
                #{
                    desc => ?DESC(abs_sess_threshold),
                    required => false
                }
            )},
        {"rel_sess_threshold",
            mk(
                number(),
                #{
                    desc => ?DESC(rel_sess_threshold),
                    required => false,
                    validator => [fun(Value) -> Value > 1.0 end]
                }
            )},
        {"wait_takeover",
            mk(
                emqx_schema:duration_s(),
                #{
                    desc => ?DESC(wait_takeover),
                    required => false
                }
            )},
        {"nodes",
            mk(
                list(binary()),
                #{
                    desc => ?DESC(rebalance_nodes),
                    required => false,
                    validator => [fun(Values) -> length(Values) > 0 end]
                }
            )}
    ];
fields(rebalance_evacuation_start) ->
    [
        {"conn_evict_rate",
            mk(
                pos_integer(),
                #{
                    desc => ?DESC(conn_evict_rate),
                    required => false
                }
            )},
        {"sess_evict_rate",
            mk(
                pos_integer(),
                #{
                    desc => ?DESC(sess_evict_rate),
                    required => false
                }
            )},
        {"redirect_to",
            mk(
                binary(),
                #{
                    desc => ?DESC(redirect_to),
                    required => false
                }
            )},
        {"wait_takeover",
            mk(
                pos_integer(),
                #{
                    desc => ?DESC(wait_takeover),
                    required => false
                }
            )},
        {"migrate_to",
            mk(
                list(binary()),
                #{
                    desc => ?DESC(migrate_to),
                    required => false,
                    validator => [fun(Values) -> length(Values) > 0 end]
                }
            )}
    ];
fields(local_status_disabled) ->
    [
        {"status",
            mk(
                disabled,
                #{
                    desc => ?DESC(local_status_enabled),
                    required => true
                }
            )}
    ];
fields(local_status_enabled) ->
    [
        {"status",
            mk(
                enabled,
                #{
                    desc => ?DESC(local_status_enabled),
                    required => true
                }
            )},
        {"process",
            mk(
                hoconsc:union([rebalance, evacuation]),
                #{
                    desc => ?DESC(local_status_process),
                    required => true
                }
            )},
        {"state",
            mk(
                atom(),
                #{
                    desc => ?DESC(local_status_state),
                    required => true
                }
            )},
        {"coordinator_node",
            mk(
                binary(),
                #{
                    desc => ?DESC(local_status_coordinator_node),
                    required => false
                }
            )},
        {"connection_eviction_rate",
            mk(
                pos_integer(),
                #{
                    desc => ?DESC(local_status_connection_eviction_rate),
                    required => false
                }
            )},
        {"session_eviction_rate",
            mk(
                pos_integer(),
                #{
                    desc => ?DESC(local_status_session_eviction_rate),
                    required => false
                }
            )},
        {"connection_goal",
            mk(
                non_neg_integer(),
                #{
                    desc => ?DESC(local_status_connection_goal),
                    required => false
                }
            )},
        {"session_goal",
            mk(
                non_neg_integer(),
                #{
                    desc => ?DESC(local_status_session_goal),
                    required => false
                }
            )},
        {"disconnected_session_goal",
            mk(
                non_neg_integer(),
                #{
                    desc => ?DESC(local_status_disconnected_session_goal),
                    required => false
                }
            )},
        {"session_recipients",
            mk(
                list(binary()),
                #{
                    desc => ?DESC(local_status_session_recipients),
                    required => false
                }
            )},
        {"recipients",
            mk(
                list(binary()),
                #{
                    desc => ?DESC(local_status_recipients),
                    required => false
                }
            )},
        {"stats",
            mk(
                ref(status_stats),
                #{
                    desc => ?DESC(local_status_stats),
                    required => false
                }
            )}
    ];
fields(status_stats) ->
    [
        {"initial_connected",
            mk(
                non_neg_integer(),
                #{
                    desc => ?DESC(status_stats_initial_connected),
                    required => true
                }
            )},
        {"current_connected",
            mk(
                non_neg_integer(),
                #{
                    desc => ?DESC(status_stats_current_connected),
                    required => true
                }
            )},
        {"initial_sessions",
            mk(
                non_neg_integer(),
                #{
                    desc => ?DESC(status_stats_initial_sessions),
                    required => true
                }
            )},
        {"current_sessions",
            mk(
                non_neg_integer(),
                #{
                    desc => ?DESC(status_stats_current_sessions),
                    required => true
                }
            )},
        {"current_disconnected_sessions",
            mk(
                non_neg_integer(),
                #{
                    desc => ?DESC(status_stats_current_disconnected_sessions),
                    required => false
                }
            )}
    ];
fields(global_coordinator_status) ->
    without(
        ["status", "process", "session_goal", "session_recipients", "stats"],
        fields(local_status_enabled)
    ) ++
        [
            {"donors",
                mk(
                    list(binary()),
                    #{
                        desc => ?DESC(coordinator_status_donors),
                        required => false
                    }
                )},
            {"donor_conn_avg",
                mk(
                    non_neg_integer(),
                    #{
                        desc => ?DESC(coordinator_status_donor_conn_avg),
                        required => false
                    }
                )},
            {"donor_sess_avg",
                mk(
                    non_neg_integer(),
                    #{
                        desc => ?DESC(coordinator_status_donor_sess_avg),
                        required => false
                    }
                )},
            {"node",
                mk(
                    binary(),
                    #{
                        desc => ?DESC(coordinator_status_node),
                        required => true
                    }
                )}
        ];
fields(global_evacuation_status) ->
    without(["status", "process"], fields(local_status_enabled)) ++
        [
            {"node",
                mk(
                    binary(),
                    #{
                        desc => ?DESC(evacuation_status_node),
                        required => true
                    }
                )}
        ];
fields(global_status) ->
    [
        {"evacuations",
            mk(
                hoconsc:array(ref(global_evacuation_status)),
                #{
                    desc => ?DESC(global_status_evacuations),
                    required => false
                }
            )},
        {"rebalances",
            mk(
                hoconsc:array(ref(global_coordinator_status)),
                #{
                    desc => ?DESC(global_status_rebalances),
                    required => false
                }
            )}
    ].

rebalance_example() ->
    #{
        wait_health_check => 10,
        conn_evict_rate => 10,
        sess_evict_rate => 20,
        abs_conn_threshold => 10,
        rel_conn_threshold => 1.5,
        abs_sess_threshold => 10,
        rel_sess_threshold => 1.5,
        wait_takeover => 10,
        nodes => [<<"othernode@127.0.0.1">>]
    }.

rebalance_evacuation_example() ->
    #{
        conn_evict_rate => 100,
        sess_evict_rate => 100,
        redirect_to => <<"othernode:1883">>,
        wait_takeover => 10,
        migrate_to => [<<"othernode@127.0.0.1">>]
    }.

local_status_response_schema() ->
    hoconsc:union([ref(local_status_disabled), ref(local_status_enabled)]).

response_schema() ->
    mk(
        map(),
        #{
            desc => ?DESC(empty_response)
        }
    ).

roots() -> [].
