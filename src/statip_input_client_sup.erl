%%%---------------------------------------------------------------------------
%%% @private
%%% @doc
%%%   Input client handlers supervisor.
%%% @end
%%%---------------------------------------------------------------------------

-module(statip_input_client_sup).

-behaviour(supervisor).

%% public interface
-export([spawn_worker/1]).

%% supervision tree API
-export([start_link/0]).

%% supervisor callbacks
-export([init/1]).

%%%---------------------------------------------------------------------------
%%% public interface
%%%---------------------------------------------------------------------------

spawn_worker(Socket) ->
  supervisor:start_child(?MODULE, [Socket]).

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
  Strategy = {simple_one_for_one, 5, 10},
  Children = [
    {statip_input_client,
      {statip_input_client, start_link, []},
      temporary, 5000, worker, [statip_input_client]}
  ],
  {ok, {Strategy, Children}}.

%%%---------------------------------------------------------------------------
%%% vim:ft=erlang:foldmethod=marker
