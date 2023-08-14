%%--------------------------------------------------------------------
%% Copyright (c) 2020-2023 EMQ Technologies Co., Ltd. All Rights Reserved.
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%%     http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.
%%--------------------------------------------------------------------

-module(emqx_node_rebalance_status_SUITE).

-compile(export_all).
-compile(nowarn_export_all).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

all() -> emqx_common_test_helpers:all(?MODULE).

suite() ->
    [{timetrap, {seconds, 90}}].

init_per_suite(Config) ->
    WorkDir = ?config(priv_dir, Config),
    Apps = [
        emqx_conf,
        emqx,
        emqx_node_rebalance
    ],
    Cluster = [
        {emqx_node_rebalance_status_SUITE1, #{
            role => core,
            apps => Apps
        }},
        {emqx_node_rebalance_status_SUITE2, #{
            role => replicant,
            apps => Apps
        }}
    ],
    Nodes = emqx_cth_cluster:start(Cluster, #{work_dir => WorkDir}),
    [{cluster_nodes, Nodes} | Config].

end_per_suite(Config) ->
    ok = emqx_cth_cluster:stop(?config(cluster_nodes, Config)),
    ok.

%%--------------------------------------------------------------------
%% Tests
%%--------------------------------------------------------------------

t_cluster_status(Config) ->
    [CoreNode, ReplicantNode] = ?config(cluster_nodes, Config),
    ok = emqx_node_rebalance_api_proto_v2:node_rebalance_evacuation_start(CoreNode, #{}),

    ?assertMatch(
        #{evacuations := [_], rebalances := []},
        rpc:call(ReplicantNode, emqx_node_rebalance_status, global_status, [])
    ).
