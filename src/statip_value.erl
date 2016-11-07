%%%---------------------------------------------------------------------------
%%% @doc
%%%   Data types and functions for stored values.
%%%
%%% @todo `-include("statip_value.hrl").'
%%% @see statip_keeper
%%% @end
%%%---------------------------------------------------------------------------

-module(statip_value).

%% general-purpose interface
-export([timestamp/0]).
%% data access interface
-export([add/4, restore/4]).
-export([list_names/0, list_origins/1]).
-export([list_keys/2, list_values/2, get_value/3]).

-export_type([name/0, origin/0, key/0]).
-export_type([state/0, severity/0, info/0]).
-export_type([timestamp/0, expiry/0]).

%%%---------------------------------------------------------------------------
%%% type specification/documentation {{{

-include("statip_value.hrl").

-type name() :: binary().
%% Value group name.

-type origin() :: binary() | undefined.
%% Value group's origin.

-type key() :: binary().
%% Value's key, which identifies a particular value in a value group of
%% specific origin.

-type state() :: binary() | undefined.
%% State of a monitored object recorded in the value.

-type severity() :: expected | warning | error.
%% Value's severity.

-type info() :: statip_json:struct().
%% Additional data associated with the value.

-type timestamp() :: integer().
%% Time (unix timestamp) when the value was collected.

-type expiry() :: pos_integer().
%% Number of seconds after {@type timestamp()} when the value is valid. After
%% this time, the value is deleted.

%%% }}}
%%%---------------------------------------------------------------------------

%%%---------------------------------------------------------------------------
%%% data access interface
%%%---------------------------------------------------------------------------

%% @doc Restore a value group keeper after application reboot.

-spec restore(name(), origin(), [#value{}], related | unrelated) ->
  ok | {error, exists}.

restore(GroupName, GroupOrigin, Values, GroupType) ->
  case start_keeper(GroupName, GroupOrigin, GroupType) of
    {Pid, Module} -> Module:restore(Pid, Values);
    none -> {error, exists}
  end.

%% @doc Remember a value.
%%
%%   If a value's type ("related" or "unrelated") doesn't match the type of
%%   value group, the value is ignored.

-spec add(name(), origin(), #value{}, related | unrelated) ->
  ok.

add(GroupName, GroupOrigin, Value = #value{key = Key, sort_key = undefined},
    GroupType) ->
  NewValue = Value#value{sort_key = Key},
  add(GroupName, GroupOrigin, NewValue, GroupType);
add(GroupName, GroupOrigin, Value, GroupType) ->
  case get_keeper(GroupName, GroupOrigin, GroupType) of
    {Pid, Module} -> Module:add(Pid, Value);
    none -> ok % TODO: log this event
  end.

%% @doc List names of value groups.

-spec list_names() ->
  [name()].

list_names() ->
  statip_registry:list_names().

%% @doc List all origins in a value group.

-spec list_origins(name()) ->
  [origin()].

list_origins(GroupName) ->
  statip_registry:list_origins(GroupName).

%% @doc List the keys in an origin of a value group.

-spec list_keys(name(), origin()) ->
  [key()].

list_keys(GroupName, GroupOrigin) ->
  case get_keeper(GroupName, GroupOrigin) of
    {Pid, Module} ->
      try
        Module:list_keys(Pid)
      catch
        exit:{noproc, {gen_server, call, _Args}} -> []
      end;
    none ->
      []
  end.

%% @doc List the values from specific origin in a value group.

-spec list_values(name(), origin()) ->
  [#value{}] | none.

list_values(GroupName, GroupOrigin) ->
  case get_keeper(GroupName, GroupOrigin) of
    {Pid, Module} ->
      try
        Module:list_values(Pid)
      catch
        exit:{noproc, {gen_server, call, _Args}} -> none
      end;
    none ->
      none
  end.

%% @doc Get a specific value.

-spec get_value(name(), origin(), key()) ->
  #value{} | none.

get_value(GroupName, GroupOrigin, Key) ->
  case get_keeper(GroupName, GroupOrigin) of
    {Pid, Module} ->
      try
        Module:get_value(Pid, Key)
      catch
        exit:{noproc, {gen_server, call, _Args}} -> none
      end;
    none ->
      none
  end.

%%----------------------------------------------------------
%% helpers
%%----------------------------------------------------------

%% @doc Get a keeper process and its communication module.
%%
%%   This function does not start a new process.

-spec get_keeper(name(), origin()) ->
  {pid(), module()} | none.

get_keeper(GroupName, GroupOrigin) ->
  statip_registry:find_process(GroupName, GroupOrigin).

%% @doc Get a keeper process (possibly starting it) and its communication
%%   module.
%%
%%   This function tries first to find an already started keeper process. If
%%   no keeper is started, it tries to start one and use that. If starting
%%   failed, it means somebody else already started one, so the function tries
%%   to find and use that one instead. If all that fails, function gives up
%%   and returns `none'.
%%
%%   If the value group's type expected and running are mismatched (incoming
%%   "related" value while "unrelated" keeper is running or the reverse),
%%   function returns `none'.

-spec get_keeper(name(), origin(), related | unrelated) ->
  {pid(), module()} | none.

get_keeper(GroupName, GroupOrigin, GroupType) ->
  case statip_registry:find_process(GroupName, GroupOrigin) of
    {Pid, statip_keeper_related = Module} when GroupType == related ->
      {Pid, Module};
    {Pid, statip_keeper_unrelated = Module} when GroupType == unrelated ->
      {Pid, Module};
    {_Pid, _Module} ->
      % mismatched incoming value type and registered value type
      none;
    none ->
      case start_keeper(GroupName, GroupOrigin, GroupType) of
        {Pid, Module} -> {Pid, Module};
        none -> statip_registry:find_process(GroupName, GroupOrigin)
      end
  end.

%% @doc Start a new value group keeper process, depending on value group's
%%   type.

-spec start_keeper(name(), origin(), related | unrelated) ->
  {pid(), module()} | none.

start_keeper(GroupName, GroupOrigin, related = _GroupType) ->
  case statip_keeper_related:spawn_keeper(GroupName, GroupOrigin) of
    {ok, Pid} when is_pid(Pid) -> {Pid, statip_keeper_related};
    {ok, undefined} -> none
  end;
start_keeper(GroupName, GroupOrigin, unrelated = _GroupType) ->
  case statip_keeper_unrelated:spawn_keeper(GroupName, GroupOrigin) of
    {ok, Pid} when is_pid(Pid) -> {Pid, statip_keeper_unrelated};
    {ok, undefined} -> none
  end.

%%%---------------------------------------------------------------------------
%%% general-purpose interface
%%%---------------------------------------------------------------------------

%% @doc Return current time as a unix timestamp.

-spec timestamp() ->
  timestamp().

timestamp() ->
  {MS,S,_US} = os:timestamp(),
  MS * 1000 * 1000 + S.

%%%---------------------------------------------------------------------------
%%% vim:ft=erlang:foldmethod=marker
