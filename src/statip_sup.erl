%%%---------------------------------------------------------------------------
%%% @private
%%% @doc
%%%   Application's top-level supervisor.
%%% @end
%%%---------------------------------------------------------------------------

-module(statip_sup).

-behaviour(supervisor).

%% supervision tree API
-export([start_link/0]).

%% supervisor callbacks
-export([init/1]).

-include("statip_boot.hrl").

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
    %{statip_log,
    %  {statip_log, start_link, []},
    %  permanent, 5000, worker, [statip_log]},
    {statip_registry,
      {statip_registry, start_link, []},
      permanent, 5000, worker, [statip_registry]},
    {statip_value_sup,
      {statip_value_sup, start_link, []},
      permanent, 5000, supervisor, [statip_value_sup]},
    {statip_state_log,
      {statip_state_log, start_link, []},
      permanent, 5000, worker, [statip_state_log]},
    {statip_input_sup,
      {statip_input_sup, start_link, []},
      permanent, 5000, supervisor, [statip_input_sup]},
    {statip_http_sup,
      {statip_http_sup, start_link, []},
      permanent, 5000, supervisor, [statip_http_sup]}
  ],
  ?ETS_BOOT_TABLE = ets:new(?ETS_BOOT_TABLE, [
    named_table, public, set,
    {read_concurrency, true}
  ]),
  {ok, {Strategy, Children}}.

%%%---------------------------------------------------------------------------
%%% vim:ft=erlang:foldmethod=marker
