%%%---------------------------------------------------------------------------
%%% @private
%%% @doc
%%%   Reader clients subsystem supervisor.
%%% @end
%%%---------------------------------------------------------------------------

-module(statip_reader_sup).

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
    {statip_reader_client_sup,
      {statip_reader_client_sup, start_link, []},
      permanent, 5000, supervisor, [statip_reader_client_sup]},
    {statip_reader_listen,
      {statip_reader_listen, start_link, []},
      permanent, 5000, worker, [statip_reader_listen]}
  ],
  {ok, {Strategy, Children}}.

%%%---------------------------------------------------------------------------
%%% vim:ft=erlang:foldmethod=marker
