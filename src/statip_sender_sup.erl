%%%---------------------------------------------------------------------------
%%% @private
%%% @doc
%%%   Sender clients subsystem supervisor.
%%% @end
%%%---------------------------------------------------------------------------

-module(statip_sender_sup).

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
  {ok, Addrs} = application:get_env(input),
  Strategy = {one_for_one, 5, 10},
  Children = [
    {statip_sender_client_sup,
      {statip_sender_client_sup, start_link, []},
      permanent, 5000, supervisor, [statip_sender_client_sup]} |
    [listen_child(Addr, Port) || {Addr, Port} <- Addrs]
  ],
  {ok, {Strategy, Children}}.

%%%---------------------------------------------------------------------------

listen_child(Address, Port) ->
  {{statip_sender_listen, Address, Port},
    {statip_sender_listen, start_link, [Address, Port]},
    permanent, 5000, worker, [statip_sender_listen]}.

%%%---------------------------------------------------------------------------
%%% vim:ft=erlang:foldmethod=marker
