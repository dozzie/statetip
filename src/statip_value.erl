%%%---------------------------------------------------------------------------
%%% @doc
%%%   Value records access functions.
%%%
%%%   <b>TODO</b>: What do I call "value"? What do I call "record"? What is
%%%   "name", "origin", and "key"?
%%%
%%%   <b>TODO</b>: `-include("statip_value.hrl").'
%%%
%%%   <b>TODO</b>: describe required callbacks (`spawn_keeper(ValueName,
%%%   ValueOrigin)', `add(Pid, Record)' (should not die on noproc),
%%%   `list_keys(Pid)' (may die on noproc), `list_records(Pid)' (may die on
%%%   noproc), `get_record(Pid, Key)' (may die on noproc))
%%% @end
%%%---------------------------------------------------------------------------

-module(statip_value).

%% general-purpose interface
-export([timestamp/0]).
%% data access interface
-export([add/4, restore/4]).
-export([list_names/0, list_origins/1]).
-export([list_keys/2, list_records/2, get_record/3]).

-export_type([name/0, origin/0, key/0]).
-export_type([value/0, severity/0, info/0]).
-export_type([timestamp/0, expiry/0]).

%%%---------------------------------------------------------------------------
%%% type specification/documentation {{{

-include("statip_value.hrl").

-type name() :: binary().
%% Value name.

-type origin() :: binary() | undefined.
%% Record's origin.

-type key() :: binary().
%% Record's key, which identifies particular record. @{type @{name(),
%% origin(), key@}} is an address for {@type value()}, {@type severity()}, and
%% {@type info()}.

-type value() :: binary() | undefined.
%% Value to be remembered.in the record.

-type severity() :: expected | warning | error.
%% Value's severity.

-type info() :: statip_json:struct().
%% Additional data associated with the record.

-type timestamp() :: integer().
%% Time (unix timestamp) when the record was collected.

-type expiry() :: pos_integer().
%% Number of seconds after {@type timestamp()} when the record is valid. After
%% this time, the record is deleted.

%%% }}}
%%%---------------------------------------------------------------------------

%%%---------------------------------------------------------------------------
%%% value keepers callbacks
%%%---------------------------------------------------------------------------

-callback spawn_keeper(ValueName :: name(), ValueOrigin :: origin()) ->
  {ok, pid()} | ignore | {error, term()}.

-callback restore(Pid :: pid(), Records :: [#value{}]) ->
  ok.

-callback add(Pid :: pid(), Record :: #value{}) ->
  ok.

-callback list_keys(Pid :: pid()) ->
  [key()].

-callback list_records(Pid :: pid()) ->
  [#value{}] | none.

-callback get_record(Pid :: pid(), Key :: statip_value:key()) ->
  #value{} | none.

%%%---------------------------------------------------------------------------
%%% data access interface
%%%---------------------------------------------------------------------------

%% @doc Restore a value keeper process after application reboot.

-spec restore(name(), origin(), [#value{}], burst | single) ->
  ok | {error, exists}.

restore(ValueName, ValueOrigin, Records, ValueType) ->
  case start_keeper(ValueName, ValueOrigin, ValueType) of
    {Pid, Module} -> Module:restore(Pid, Records);
    none -> {error, exists}
  end.

%% @doc Remember a value in appropriate keeper.
%%   If a value's type (single or burst) mismatches what is already
%%   remembered, the value is dropped.

-spec add(name(), origin(), #value{}, burst | single) ->
  ok.

add(ValueName, ValueOrigin, Record = #value{key = Key, sort_key = undefined},
    ValueType) ->
  NewRecord = Record#value{sort_key = Key},
  add(ValueName, ValueOrigin, NewRecord, ValueType);
add(ValueName, ValueOrigin, Record, ValueType) ->
  case get_keeper(ValueName, ValueOrigin, ValueType) of
    {Pid, Module} -> Module:add(Pid, Record);
    none -> ok % TODO: log this event
  end.

%% @doc List names of registered values.

-spec list_names() ->
  [name()].

list_names() ->
  statip_registry:list_names().

%% @doc List all origins that were recorded for a value.

-spec list_origins(name()) ->
  [origin()].

list_origins(ValueName) ->
  statip_registry:list_origins(ValueName).

%% @doc List the keys remembered for an origin of a value.

-spec list_keys(name(), origin()) ->
  [key()].

list_keys(ValueName, ValueOrigin) ->
  case get_keeper(ValueName, ValueOrigin) of
    {Pid, Module} ->
      try
        Module:list_keys(Pid)
      catch
        exit:{noproc, {gen_server, call, _Args}} -> []
      end;
    none ->
      []
  end.

%% @doc List the records remembered for an origin of a value.

-spec list_records(name(), origin()) ->
  [#value{}] | none.

list_records(ValueName, ValueOrigin) ->
  case get_keeper(ValueName, ValueOrigin) of
    {Pid, Module} ->
      try
        Module:list_records(Pid)
      catch
        exit:{noproc, {gen_server, call, _Args}} -> none
      end;
    none ->
      none
  end.

%% @doc Get the record for a specific key.

-spec get_record(name(), origin(), key()) ->
  #value{} | none.

get_record(ValueName, ValueOrigin, Key) ->
  case get_keeper(ValueName, ValueOrigin) of
    {Pid, Module} ->
      try
        Module:get_record(Pid, Key)
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

get_keeper(ValueName, ValueOrigin) ->
  statip_registry:find_process(ValueName, ValueOrigin).

%% @doc Get a keeper process (possibly starting it) and its communication
%%   module.
%%
%%   This function tries first to find an already started keeper process. If
%%   no keeper is started, it tries to start one and use that. If starting
%%   failed, it means somebody else already started one, so the function tries
%%   to find and use that one instead. If all that fails, function gives up
%%   and returns `none'.
%%
%%   If the value type expected and running are mismatched (incoming single
%%   value while burst keeper is running or the reverse), function returns
%%   `none'.

-spec get_keeper(name(), origin(), burst | single) ->
  {pid(), module()} | none.

get_keeper(ValueName, ValueOrigin, ValueType) ->
  case statip_registry:find_process(ValueName, ValueOrigin) of
    {Pid, statip_value_burst = Module} when ValueType == burst ->
      {Pid, Module};
    {Pid, statip_value_single = Module} when ValueType == single ->
      {Pid, Module};
    {_Pid, _Module} ->
      % mismatched incoming value type and registered value type
      none;
    none ->
      case start_keeper(ValueName, ValueOrigin, ValueType) of
        {Pid, Module} -> {Pid, Module};
        none -> statip_registry:find_process(ValueName, ValueOrigin)
      end
  end.

%% @doc Start a new value keeper process, depending on value's type.

-spec start_keeper(name(), origin(), burst | single) ->
  {pid(), module()} | none.

start_keeper(ValueName, ValueOrigin, burst = _ValueType) ->
  case statip_value_burst:spawn_keeper(ValueName, ValueOrigin) of
    {ok, Pid} when is_pid(Pid) -> {Pid, statip_value_burst};
    {ok, undefined} -> none
  end;
start_keeper(ValueName, ValueOrigin, single = _ValueType) ->
  case statip_value_single:spawn_keeper(ValueName, ValueOrigin) of
    {ok, Pid} when is_pid(Pid) -> {Pid, statip_value_single};
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
