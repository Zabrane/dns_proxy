-module(dns_proxy).

-behaviour(application).

%% Application callbacks
-export([start/2, stop/1, start/0, sync/0, stat/0]).

%% ===================================================================
%% Application callbacks
%% ===================================================================
start(_StartType, _StartArgs) ->
    dns_proxy_sup:start_link().

stop(_State) ->
    ok.

%% start()
start() ->
    application:start(?MODULE).

%% ===================================================================
%% Other APIs
%% ===================================================================
sync() ->
    dns_proxy_srv:sync().

stat() ->
    dns_proxy_srv:stat().
