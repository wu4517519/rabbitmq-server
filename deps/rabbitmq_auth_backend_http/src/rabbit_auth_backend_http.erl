%% This Source Code Form is subject to the terms of the Mozilla Public
%% License, v. 2.0. If a copy of the MPL was not distributed with this
%% file, You can obtain one at https://mozilla.org/MPL/2.0/.
%%
%% Copyright (c) 2007-2023 VMware, Inc. or its affiliates.  All rights reserved.
%%

-module(rabbit_auth_backend_http).

-include_lib("rabbit.hrl").

-behaviour(rabbit_authn_backend).
-behaviour(rabbit_authz_backend).

-export([description/0, p/1, q/1, join_tags/1]).
-export([user_login_authentication/2, user_login_authorization/2,
         check_vhost_access/3, check_resource_access/4, check_topic_access/4,
         state_can_expire/0]).

%% If keepalive connection is closed, retry N times before failing.
-define(RETRY_ON_KEEPALIVE_CLOSED, 3).

-define(RESOURCE_REQUEST_PARAMETERS, [username, vhost, resource, name, permission]).

-define(SUCCESSFUL_RESPONSE_CODES, [200, 201]).

%%--------------------------------------------------------------------

description() ->
    [{name, <<"HTTP">>},
     {description, <<"HTTP authentication / authorisation">>}].

%%--------------------------------------------------------------------

user_login_authentication(Username, AuthProps) ->

    case http_req(p(user_path), q([{username, Username}|extractPassword(AuthProps)])) of
        {error, _} = E  -> E;
        "deny"          -> {refused, "Denied by the backing HTTP service", []};
        "allow" ++ Rest -> Tags = [rabbit_data_coercion:to_atom(T) ||
                                   T <- string:tokens(Rest, " ")],

                           {ok, #auth_user{username = Username,
                                           tags     = Tags,
                                           impl     = fun() -> proplists:get_value(password, AuthProps, none) end}};
        Other           -> {error, {bad_response, Other}}
    end.

%% Credentials (i.e. password) maybe directly in the password attribute in AuthProps
%% or as a Function with the attribute rabbit_auth_backend_http if the user was already authenticated with http backend
%% or as a Function with the attribute rabbit_auth_backend_cache if the user was already authenticated via cache backend
extractPassword(AuthProps) ->
    case proplists:get_value(password, AuthProps, none) of
        none ->
            case proplists:get_value(rabbit_auth_backend_http, AuthProps, none) of
                none -> case proplists:get_value(rabbit_auth_backend_cache, AuthProps, none) of
                            none -> [];
                            PasswordFun -> [{password, PasswordFun()}]
                        end;
                PasswordFun -> [{password, PasswordFun()}]
            end;
        Password -> [{password, Password}]
    end.

user_login_authorization(Username, AuthProps) ->
    case user_login_authentication(Username, AuthProps) of
        {ok, #auth_user{impl = Impl}} -> {ok, Impl};
        Else                          -> Else
    end.

check_vhost_access(#auth_user{username = Username, tags = Tags}, VHost, undefined) ->
    do_check_vhost_access(Username, Tags, VHost, "", undefined);
check_vhost_access(#auth_user{username = Username, tags = Tags}, VHost,
                   AuthzData = #{peeraddr := PeerAddr}) when is_map(AuthzData) ->
    AuthzData1 = maps:remove(peeraddr, AuthzData),
    Ip = parse_peeraddr(PeerAddr),
    do_check_vhost_access(Username, Tags, VHost, Ip, AuthzData1).

do_check_vhost_access(Username, Tags, VHost, Ip, AuthzData) ->
    OptionsParameters = context_as_parameters(AuthzData),
    bool_req(vhost_path, [{username, Username},
                          {vhost,    VHost},
                          {ip,       Ip},
                          {tags,     join_tags(Tags)}] ++ OptionsParameters).

check_resource_access(#auth_user{username = Username, tags = Tags},
                      #resource{virtual_host = VHost, kind = Type, name = Name},
                      Permission,
                      AuthzContext) ->
    OptionsParameters = context_as_parameters(AuthzContext),
    bool_req(resource_path, [{username,   Username},
                             {vhost,      VHost},
                             {resource,   Type},
                             {name,       Name},
                             {permission, Permission},
                             {tags, join_tags(Tags)}] ++ OptionsParameters).

check_topic_access(#auth_user{username = Username, tags = Tags},
                   #resource{virtual_host = VHost, kind = topic = Type, name = Name},
                   Permission,
                   Context) ->
    OptionsParameters = context_as_parameters(Context),
    bool_req(topic_path, [{username,   Username},
        {vhost,      VHost},
        {resource,   Type},
        {name,       Name},
        {permission, Permission},
        {tags, join_tags(Tags)}] ++ OptionsParameters).

state_can_expire() -> false.

%%--------------------------------------------------------------------

context_as_parameters(Options) when is_map(Options) ->
    % filter keys that would erase fixed parameters
    [{rabbit_data_coercion:to_atom(Key), maps:get(Key, Options)}
        || Key <- maps:keys(Options),
        lists:member(
            rabbit_data_coercion:to_atom(Key),
            ?RESOURCE_REQUEST_PARAMETERS) =:= false];
context_as_parameters(_) ->
    [].

bool_req(PathName, Props) ->
    case http_req(p(PathName), q(Props)) of
        "deny"  -> false;
        "allow" -> true;
        E       -> E
    end.

http_req(Path, Query) -> http_req(Path, Query, ?RETRY_ON_KEEPALIVE_CLOSED).

http_req(Path, Query, Retry) ->
    case do_http_req(Path, Query) of
        {error, socket_closed_remotely} ->
            %% HTTP keepalive connection can no longer be used. Retry the request.
            case Retry > 0 of
                true  -> http_req(Path, Query, Retry - 1);
                false -> {error, socket_closed_remotely}
            end;
        Other -> Other
    end.


do_http_req(Path0, Query) ->
    URI = uri_parser:parse(Path0, [{port, 80}]),
    {host, Host} = lists:keyfind(host, 1, URI),
    {port, Port} = lists:keyfind(port, 1, URI),
    HostHdr = rabbit_misc:format("~ts:~b", [Host, Port]),
    {ok, Method} = application:get_env(rabbitmq_auth_backend_http, http_method),
    Request = case rabbit_data_coercion:to_atom(Method) of
        get  ->
            Path = Path0 ++ "?" ++ Query,
            rabbit_log:debug("auth_backend_http: GET ~ts", [Path]),
            {Path, [{"Host", HostHdr}]};
        post ->
            rabbit_log:debug("auth_backend_http: POST ~ts", [Path0]),
            {Path0, [{"Host", HostHdr}], "application/x-www-form-urlencoded", Query}
    end,
    RequestTimeout =
        case application:get_env(rabbitmq_auth_backend_http, request_timeout) of
            {ok, Val1} -> Val1;
            _ -> infinity
        end,
    ConnectionTimeout =
        case application:get_env(rabbitmq_auth_backend_http, connection_timeout) of
            {ok, Val2} -> Val2;
            _ -> RequestTimeout
        end,
    rabbit_log:debug("auth_backend_http: request timeout: ~tp, connection timeout: ~tp", [RequestTimeout, ConnectionTimeout]),
    HttpOpts = case application:get_env(rabbitmq_auth_backend_http, ssl_options) of
        {ok, Opts} when is_list(Opts) ->
            [
                {ssl, Opts},
                {timeout, RequestTimeout},
                {connect_timeout, ConnectionTimeout}];
        _                             ->
            [
                {timeout, RequestTimeout},
                {connect_timeout, ConnectionTimeout}
            ]
    end,

    case httpc:request(Method, Request, HttpOpts, []) of
        {ok, {{_HTTP, Code, _}, _Headers, Body}} ->
            rabbit_log:debug("auth_backend_http: response code is ~tp, body: ~tp", [Code, Body]),
            case lists:member(Code, ?SUCCESSFUL_RESPONSE_CODES) of
                true  -> parse_resp(Body);
                false -> {error, {Code, Body}}
            end;
        {error, _} = E ->
            E
    end.

p(PathName) ->
    {ok, Path} = application:get_env(rabbitmq_auth_backend_http, PathName),
    Path.

q(Args) ->
    string:join([escape(K, V) || {K, V} <- Args, not is_function(V)], "&").

escape(K, Map) when is_map(Map) ->
    string:join([escape(rabbit_data_coercion:to_list(K) ++ "." ++ rabbit_data_coercion:to_list(Key), Value)
        || {Key, Value} <- maps:to_list(Map), not is_function(Value)], "&");
escape(K, V) ->
    rabbit_data_coercion:to_list(K) ++ "=" ++ rabbit_http_util:quote_plus(V).

parse_resp(Resp) -> string:to_lower(string:strip(Resp)).

join_tags([])   -> "";
join_tags(Tags) ->
  Strings = [rabbit_data_coercion:to_list(T) || T <- Tags],
  string:join(Strings, " ").

-spec parse_peeraddr(inet:ip_address() | unknown) -> string().
parse_peeraddr(unknown) ->
    rabbit_data_coercion:to_list(unknown);
parse_peeraddr(PeerAddr) ->
    handle_inet_ntoa_peeraddr(inet:ntoa(PeerAddr), PeerAddr).

-spec handle_inet_ntoa_peeraddr({'error', term()} | string(), inet:ip_address() | unknown) -> string().
handle_inet_ntoa_peeraddr({error, einval}, PeerAddr) ->
    rabbit_data_coercion:to_list(PeerAddr);
handle_inet_ntoa_peeraddr(PeerAddrStr, _PeerAddr0) ->
    PeerAddrStr.
