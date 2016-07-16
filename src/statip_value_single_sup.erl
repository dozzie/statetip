%%%---------------------------------------------------------------------------
%%% @private
%%% @doc
%%%   Single value (non-burst) keeper processes supervisor.
%%% @end
%%%---------------------------------------------------------------------------

-module(statip_value_single_sup).

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

spawn_keeper(ValueName, ValueOrigin) ->
  supervisor:start_child(?MODULE, [ValueName, ValueOrigin]).

%%%---------------------------------------------------------------------------
%%% supervisor callbacks
%%%---------------------------------------------------------------------------

%% @private
%% @doc Initialize supervisor.

init([] = _Args) ->
  Strategy = {simple_one_for_one, 5, 10},
  Children = [
    {statip_value_single,
      {statip_value_single, start_link, []},
      transient, 5000, worker, [statip_value_single]}
  ],
  {ok, {Strategy, Children}}.

%%%---------------------------------------------------------------------------
%%% vim:ft=erlang:foldmethod=marker
