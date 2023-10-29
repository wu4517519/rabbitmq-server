%% This Source Code Form is subject to the terms of the Mozilla Public
%% License, v. 2.0. If a copy of the MPL was not distributed with this
%% file, You can obtain one at https://mozilla.org/MPL/2.0/.
%%
%% Copyright (c) 2007-2023 VMware, Inc. or its affiliates.  All rights reserved.
%%

-module(rabbit_db).

-include_lib("kernel/include/logger.hrl").
-include_lib("stdlib/include/assert.hrl").

-include_lib("../../rabbit_common/include/logging.hrl").

-export([init/0,
         reset/0,
         force_reset/0,
         force_load_on_next_boot/0,
         is_virgin_node/0, is_virgin_node/1,
         dir/0,
         ensure_dir_exists/0]).
-export([run/1]).

%% Exported to be used by various rabbit_db_* modules
-export([
         list_in_mnesia/2
        ]).

%% Default timeout for operations on remote nodes.
-define(TIMEOUT, 60000).

%% -------------------------------------------------------------------
%% DB initialization.
%% -------------------------------------------------------------------

-spec init() -> Ret when
      Ret :: ok | {error, any()}.
%% @doc Initializes the DB layer.

init() ->
    IsVirgin = is_virgin_node(),
    ?LOG_DEBUG(
       "DB: this node is virgin: ~ts", [IsVirgin],
       #{domain => ?RMQLOG_DOMAIN_DB}),

    ensure_dir_exists(),
    rabbit_peer_discovery:log_configured_backend(),
    rabbit_peer_discovery:maybe_init(),

    pre_init(IsVirgin),

    Ret = run(
            #{mnesia => fun init_using_mnesia/0}),
    case Ret of
        ok ->
            ?LOG_DEBUG(
               "DB: initialization successeful",
               #{domain => ?RMQLOG_DOMAIN_DB}),

            post_init(IsVirgin),

            ok;
        Error ->
            ?LOG_DEBUG(
               "DB: initialization failed: ~0p", [Error],
               #{domain => ?RMQLOG_DOMAIN_DB}),
            Error
    end.

pre_init(IsVirgin) ->
    Members = rabbit_db_cluster:members(),
    OtherMembers = rabbit_nodes:nodes_excl_me(Members),
    rabbit_db_cluster:ensure_feature_flags_are_in_sync(OtherMembers, IsVirgin).

post_init(false = _IsVirgin) ->
    rabbit_peer_discovery:maybe_register();
post_init(true = _IsVirgin) ->
    %% Registration handled by rabbit_peer_discovery.
    ok.

init_using_mnesia() ->
    ?LOG_DEBUG(
      "DB: initialize Mnesia",
      #{domain => ?RMQLOG_DOMAIN_DB}),
    ok = rabbit_mnesia:init(),
    ?assertEqual(rabbit:data_dir(), mnesia_dir()),
    rabbit_sup:start_child(mnesia_sync).

-spec reset() -> Ret when
      Ret :: ok.
%% @doc Resets the database and the node.

reset() ->
    Ret = run(
            #{mnesia => fun reset_using_mnesia/0}),
    post_reset(Ret).

reset_using_mnesia() ->
    ?LOG_INFO(
      "DB: resetting node (using Mnesia)",
      #{domain => ?RMQLOG_DOMAIN_DB}),
    rabbit_mnesia:reset().

-spec force_reset() -> Ret when
      Ret :: ok.
%% @doc Resets the database and the node.

force_reset() ->
    Ret = run(
            #{mnesia => fun force_reset_using_mnesia/0}),
    post_reset(Ret).

force_reset_using_mnesia() ->
    ?LOG_DEBUG(
      "DB: resetting node forcefully (using Mnesia)",
      #{domain => ?RMQLOG_DOMAIN_DB}),
    rabbit_mnesia:force_reset().

-spec force_load_on_next_boot() -> Ret when
      Ret :: ok.
%% @doc Requests that the database to be forcefully loaded during next boot.
%%
%% This is necessary when a node refuses to boot when the cluster is in a bad
%% state, like if critical members are MIA.

force_load_on_next_boot() ->
    run(
      #{mnesia => fun force_load_on_next_boot_using_mnesia/0}).

force_load_on_next_boot_using_mnesia() ->
    ?LOG_DEBUG(
      "DB: force load on next boot (using Mnesia)",
      #{domain => ?RMQLOG_DOMAIN_DB}),
    rabbit_mnesia:force_load_next_boot().

post_reset(ok) ->
    rabbit_feature_flags:reset_registry(),
    ok;
post_reset({error, _} = Error) ->
    Error.

%% -------------------------------------------------------------------
%% is_virgin_node().
%% -------------------------------------------------------------------

-spec is_virgin_node() -> IsVirgin when
      IsVirgin :: boolean().
%% @doc Indicates if this RabbitMQ node is virgin.
%%
%% @returns `true' if the node is virgin, `false' if it is not.
%%
%% @see is_virgin_node/1.

is_virgin_node() ->
    run(
      #{mnesia => fun is_virgin_node_using_mnesia/0}).

is_virgin_node_using_mnesia() ->
    rabbit_mnesia:is_virgin_node().

-spec is_virgin_node(Node) -> IsVirgin | undefined when
      Node :: node(),
      IsVirgin :: boolean().
%% @doc Indicates if the given RabbitMQ node is virgin.
%%
%% A virgin node is a node starting for the first time. It could be a brand
%% new node or a node having been reset.
%%
%% @returns `true' if the node is virgin, `false' if it is not, or `undefined'
%% if the given node is remote and we couldn't determine it.

is_virgin_node(Node) when Node =:= node() ->
    is_virgin_node();
is_virgin_node(Node) when is_atom(Node) ->
    try
        erpc:call(Node, ?MODULE, is_virgin_node, [], ?TIMEOUT)
    catch
        _:_ ->
            undefined
    end.

-spec dir() -> DBDir when
      DBDir :: file:filename().
%% @doc Returns the directory where the database stores its data.
%%
%% @returns the directory path.

dir() ->
    run(
      #{mnesia => fun mnesia_dir/0}).

mnesia_dir() ->
    rabbit_mnesia:dir().

-spec ensure_dir_exists() -> ok | no_return().
%% @doc Ensures the database directory exists.
%%
%% @returns `ok' if it exists or throws an exception if it does not.

ensure_dir_exists() ->
    DBDir = dir() ++ "/",
    case filelib:ensure_dir(DBDir) of
        ok ->
            ok;
        {error, Reason} ->
            throw({error, {cannot_create_db_dir, DBDir, Reason}})
    end.

%% -------------------------------------------------------------------
%% run().
%% -------------------------------------------------------------------

-spec run(Funs) -> Ret when
      Funs :: #{mnesia := Fun},
      Fun :: fun(() -> Ret),
      Ret :: any().
%% @doc Runs the function corresponding to the used database engine.
%%
%% @returns the return value of `Fun'.

run(Funs)
  when is_map(Funs) andalso is_map_key(mnesia, Funs) ->
    #{mnesia := MnesiaFun} = Funs,
    run_using_mnesia(MnesiaFun).

run_using_mnesia(Fun) ->
    Fun().

list_in_mnesia(Table, Match) ->
    %% Not dirty_match_object since that would not be transactional when used in a
    %% tx context
    mnesia:async_dirty(fun () -> mnesia:match_object(Table, Match, read) end).
