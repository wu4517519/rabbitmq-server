%% This Source Code Form is subject to the terms of the Mozilla Public
%% License, v. 2.0. If a copy of the MPL was not distributed with this
%% file, You can obtain one at https://mozilla.org/MPL/2.0/.
%%
%% Copyright (c) 2017-2023 VMware, Inc. or its affiliates.  All rights reserved.
%%

-module(rabbit_vhost_sup).

-include_lib("rabbit.hrl").

%% Each vhost gets an instance of this supervisor that supervises
%% message stores and queues (via rabbit_amqqueue_sup_sup).
-behaviour(supervisor).
-export([init/1]).
-export([start_link/1]).

start_link(VHost) ->
    supervisor:start_link(?MODULE, [VHost]).

init([_VHost]) ->
    {ok, {#{strategy => one_for_all, intensity => 0, period => 1}, []}}.
