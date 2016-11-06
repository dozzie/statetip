%%%---------------------------------------------------------------------------
%%% @private
%%% @doc
%%%   Value keeper processes supervisor.
%%% @end
%%%---------------------------------------------------------------------------

-module(statip_value_sup).

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
    {statip_value_single_sup,
      {statip_value_single_sup, start_link, []},
      permanent, 5000, supervisor, [statip_value_single_sup]},
    {statip_value_burst_sup,
      {statip_value_burst_sup, start_link, []},
      permanent, 5000, supervisor, [statip_value_burst_sup]}
  ],
  {ok, {Strategy, Children}}.

%%%---------------------------------------------------------------------------
%%% vim:ft=erlang:foldmethod=marker
