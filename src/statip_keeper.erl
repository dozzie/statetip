%%%---------------------------------------------------------------------------
%%% @doc
%%%   Value group keeper interface.
%%%
%%% @todo describe required callbacks
%%% @end
%%%---------------------------------------------------------------------------

-module(statip_keeper).

-include("statip_value.hrl").

%%%---------------------------------------------------------------------------
%%% value keepers callbacks
%%%---------------------------------------------------------------------------

-callback spawn_keeper(GroupName :: statip_value:name(),
                       GroupOrigin :: statip_value:origin()) ->
  {ok, pid()} | ignore | {error, term()}.

%% only called on boot, may ignore any previous internal state
%% `Values' has no two values with the same key
-callback restore(Pid :: pid(), Values :: [#value{}, ...]) ->
  ok.

%% should not die on noproc
-callback add(Pid :: pid(), Value :: #value{}) ->
  ok.

%% may die on noproc
-callback shutdown(Pid :: pid()) ->
  ok.

%% may die on noproc
-callback delete(Pid :: pid(), Key :: statip_value:key()) ->
  ok.

%% may die on noproc
-callback list_keys(Pid :: pid()) ->
  [statip_value:key()].

%% may die on noproc
-callback list_values(Pid :: pid()) ->
  [#value{}] | none.

%% may die on noproc
-callback get_value(Pid :: pid(), Key :: statip_value:key()) ->
  #value{} | none.

%%%---------------------------------------------------------------------------
%%% vim:ft=erlang:foldmethod=marker
