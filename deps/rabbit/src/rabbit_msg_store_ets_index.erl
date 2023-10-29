%% This Source Code Form is subject to the terms of the Mozilla Public
%% License, v. 2.0. If a copy of the MPL was not distributed with this
%% file, You can obtain one at https://mozilla.org/MPL/2.0/.
%%
%% Copyright (c) 2007-2023 VMware, Inc. or its affiliates.  All rights reserved.
%%

-module(rabbit_msg_store_ets_index).

-include_lib("../../rabbit_common/include/rabbit_msg_store.hrl").

-behaviour(rabbit_msg_store_index).

-export([new/1, recover/1,
         lookup/2, select_from_file/3, select_all_from_file/2, insert/2, update/2, update_fields/3, delete/2,
         delete_object/2, clean_up_temporary_reference_count_entries_without_file/1, terminate/1]).

-define(MSG_LOC_NAME, rabbit_msg_store_ets_index).
-define(FILENAME, "msg_store_index.ets").

-record(state,
        {table,
         %% Stored as binary() as opposed to file:filename() to save memory.
         dir :: binary()}).

new(Dir) ->
    _ = file:delete(filename:join(Dir, ?FILENAME)),
    Tid = ets:new(?MSG_LOC_NAME, [set, public, {keypos, #msg_location.msg_id}]),
    #state { table = Tid, dir = rabbit_file:filename_to_binary(Dir) }.

recover(Dir) ->
    Path = filename:join(Dir, ?FILENAME),
    case ets:file2tab(Path) of
        {ok, Tid}  -> _ = file:delete(Path),
                      {ok, #state { table = Tid, dir = rabbit_file:filename_to_binary(Dir) }};
        Error      -> Error
    end.

lookup(Key, State) ->
    case ets:lookup(State #state.table, Key) of
        []      -> not_found;
        [Entry] -> Entry
    end.

%% @todo We currently fetch all and then filter by file.
%% This might lead to too many lookups... How to best
%% optimize this? ets:select didn't seem great.
select_from_file(MsgIds, File, State) ->
    All = [lookup(Id, State) || Id <- MsgIds],
    [MsgLoc || MsgLoc=#msg_location{file=MsgFile} <- All, MsgFile =:= File].

%% Note that this function is not terribly efficient and should only be
%% used for compaction or similar.
select_all_from_file(File, State) ->
    ets:match_object(State #state.table, #msg_location { file = File, _ = '_' }).

insert(Obj, State) ->
    true = ets:insert_new(State #state.table, Obj),
    ok.

update(Obj, State) ->
    true = ets:insert(State #state.table, Obj),
    ok.

update_fields(Key, Updates, State) ->
    true = ets:update_element(State #state.table, Key, Updates),
    ok.

delete(Key, State) ->
    true = ets:delete(State #state.table, Key),
    ok.

delete_object(Obj, State) ->
    true = ets:delete_object(State #state.table, Obj),
    ok.

clean_up_temporary_reference_count_entries_without_file(State) ->
    MatchHead = #msg_location { file = undefined, _ = '_' },
    ets:select_delete(State #state.table, [{MatchHead, [], [true]}]),
    ok.

terminate(#state { table = MsgLocations, dir = DirBin }) ->
    Dir = rabbit_file:binary_to_filename(DirBin),
    case ets:tab2file(MsgLocations, filename:join(Dir, ?FILENAME),
                      [{extended_info, [object_count]}]) of
        ok           -> ok;
        {error, Err} ->
            rabbit_log:error("Unable to save message store index"
                             " for directory ~tp.~nError: ~tp",
                             [Dir, Err])
    end,
    ets:delete(MsgLocations).
