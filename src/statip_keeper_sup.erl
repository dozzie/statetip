%%%---------------------------------------------------------------------------
%%% @private
%%% @doc
%%%   Keepers subsystem supervisor.
%%% @end
%%%---------------------------------------------------------------------------

-module(statip_keeper_sup).

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
    {statip_keeper_unrelated_sup,
      {statip_keeper_unrelated_sup, start_link, []},
      permanent, 5000, supervisor, [statip_keeper_unrelated_sup]},
    {statip_keeper_related_sup,
      {statip_keeper_related_sup, start_link, []},
      permanent, 5000, supervisor, [statip_keeper_related_sup]}
  ],
  {ok, {Strategy, Children}}.

%%%---------------------------------------------------------------------------
%%% vim:ft=erlang:foldmethod=marker
