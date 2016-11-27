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

%% config reloading
-export([reload/0]).

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
%%% config reloading
%%%---------------------------------------------------------------------------

%% @doc Reload configuration (start missing children, stop excessive ones,
%%   instruct all the rest to re-bind themselves).

-spec reload() ->
  ok | {error, [term()]}.

reload() ->
  {ok, NewAddrs} = application:get_env(statip, readers),
  NewChildren = lists:sort([child_name(A, P) || {A, P} <- NewAddrs]),
  OldChildren = lists:sort([
    {Name, Pid} ||
    {Name, Pid, worker, _} <- supervisor:which_children(?MODULE)
  ]),
  Errors = [R || R <- converge(NewChildren, OldChildren), R /= ok],
  case Errors of
    [] -> ok;
    _ -> {error, Errors}
  end.

%% @doc Reload workhorse for {@link reload/0}.

converge([] = _New, [] = _Old) ->
  [];
converge([NewName | NewRest] = _New, [] = Old) ->
  [start_child(NewName) | converge(NewRest, Old)];
converge([] = New, [{OldName, _Pid} | OldRest] = _Old) ->
  [stop_child(OldName) | converge(New, OldRest)];
converge([NewName | NewRest] = _New, [{OldName, Pid} | OldRest] = _Old)
when NewName == OldName ->
  [reload_child(OldName, Pid) | converge(NewRest, OldRest)];
converge([NewName | NewRest] = _New, [{OldName, _Pid} | _OldRest] = Old)
when NewName < OldName ->
  [start_child(NewName) | converge(NewRest, Old)];
converge([NewName | _NewRest] = New, [{OldName, _Pid} | OldRest] = _Old)
when OldName < NewName ->
  [stop_child(OldName) | converge(New, OldRest)].

%% @doc Start a missing child.

start_child({_, Address, Port} = Name) ->
  case supervisor:start_child(?MODULE, listen_child(Address, Port)) of
    {ok, _Pid} -> ok;
    {error, Reason} -> {start, Name, Reason}
  end.

%% @doc Stop an excessive child.

stop_child(Name) ->
  supervisor:terminate_child(?MODULE, Name),
  supervisor:delete_child(?MODULE, Name),
  ok.

%% @doc Instruct the child to re-bind its listening socket.

reload_child(Name, Pid) ->
  case statip_reader_listen:reload(Pid) of
    ok -> ok;
    {error, Reason} -> {reload, Name, Reason}
  end.

%%%---------------------------------------------------------------------------
%%% supervisor callbacks
%%%---------------------------------------------------------------------------

%% @private
%% @doc Initialize supervisor.

init([] = _Args) ->
  {ok, Addrs} = application:get_env(readers),
  Strategy = {one_for_one, 5, 10},
  Children = [
    {statip_reader_client_sup,
      {statip_reader_client_sup, start_link, []},
      permanent, 5000, supervisor, [statip_reader_client_sup]} |
    [listen_child(Addr, Port) || {Addr, Port} <- Addrs]
  ],
  {ok, {Strategy, Children}}.

%%%---------------------------------------------------------------------------

listen_child(Address, Port) ->
  {child_name(Address, Port),
    {statip_reader_listen, start_link, [Address, Port]},
    permanent, 5000, worker, [statip_reader_listen]}.

child_name(Address, Port) ->
  {statip_reader_listen, Address, Port}.

%%%---------------------------------------------------------------------------
%%% vim:ft=erlang:foldmethod=marker
