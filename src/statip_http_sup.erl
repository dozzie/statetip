%%%---------------------------------------------------------------------------
%%% @private
%%% @doc
%%%   HTTP subsystem supervisor.
%%% @end
%%%---------------------------------------------------------------------------

-module(statip_http_sup).

-behaviour(supervisor).

%% supervision tree API
-export([start_link/0]).

%% supervisor callbacks
-export([init/1]).

%%%---------------------------------------------------------------------------
%%% supervision tree API
%%%---------------------------------------------------------------------------

%% @private
%% @doc Start the supervisor process.

start_link() ->
  supervisor:start_link({local, ?MODULE}, ?MODULE, []).

%%%---------------------------------------------------------------------------
%%% supervisor callbacks
%%%---------------------------------------------------------------------------

%% @private
%% @doc Initialize supervisor.

init([] = _Args) ->
  Strategy = {one_for_one, 5, 10},
  Children = [
    {statip_http_client_sup,
      {statip_http_client_sup, start_link, []},
      permanent, 5000, supervisor, [statip_http_client_sup]},
    {statip_http_listener,
      {statip_http_listener, start_link, []},
      permanent, 5000, worker, [statip_http_listener]}
  ],
  {ok, {Strategy, Children}}.

%%%---------------------------------------------------------------------------
%%% vim:ft=erlang:foldmethod=marker