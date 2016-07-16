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
    {statip_input_sup,
      {statip_input_sup, start_link, []},
      permanent, 5000, supervisor, [statip_input_sup]}
  ],
  {ok, {Strategy, Children}}.

%%%---------------------------------------------------------------------------
%%% vim:ft=erlang:foldmethod=marker
