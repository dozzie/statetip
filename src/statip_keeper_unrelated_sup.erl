%%%---------------------------------------------------------------------------
%%% @private
%%% @doc
%%%   Keepers supervisor for unrelated values.
%%% @end
%%%---------------------------------------------------------------------------

-module(statip_keeper_unrelated_sup).

-behaviour(supervisor).

%% public interface
-export([spawn_keeper/2]).

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
%%% public interface
%%%---------------------------------------------------------------------------

spawn_keeper(GroupName, GroupOrigin) ->
  supervisor:start_child(?MODULE, [GroupName, GroupOrigin]).

%%%---------------------------------------------------------------------------
%%% supervisor callbacks
%%%---------------------------------------------------------------------------

%% @private
%% @doc Initialize supervisor.

init([] = _Args) ->
  Strategy = {simple_one_for_one, 5, 10},
  Children = [
    {statip_keeper_unrelated,
      {statip_keeper_unrelated, start_link, []},
      transient, 5000, worker, [statip_keeper_unrelated]}
  ],
  {ok, {Strategy, Children}}.

%%%---------------------------------------------------------------------------
%%% vim:ft=erlang:foldmethod=marker
