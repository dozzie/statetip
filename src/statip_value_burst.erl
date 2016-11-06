%%%---------------------------------------------------------------------------
%%% @doc
%%%   Burst value keeper process.
%%%
%%% @todo update disk state that fills things after restart
%%% @end
%%%---------------------------------------------------------------------------

-module(statip_value_burst).

-behaviour(gen_server).
-behaviour(statip_value).

%% public interface
-export([spawn_keeper/2, restore/2, add/2]).
-export([list_keys/1, list_records/1, get_record/2]).

%% supervision tree API
-export([start/2, start_link/2]).

%% gen_server callbacks
-export([init/1, terminate/2]).
-export([handle_call/3, handle_cast/2, handle_info/2]).
-export([code_change/3]).

%%%---------------------------------------------------------------------------
%%% types {{{

-include("statip_value.hrl").

-record(state, {
  value_name :: statip_value:name(),
  value_origin :: statip_value:origin(),
  current_entries  :: gb_tree(), % statip_value:key() -> #value{}
  previous_entries :: gb_tree(), % statip_value:key() -> #value{}
  expires :: statip_value:timestamp()
}).

%%% }}}
%%%---------------------------------------------------------------------------
%%% supervision tree API
%%%---------------------------------------------------------------------------

%% @private
%% @doc Start value keeper process.

start(ValueName, ValueOrigin) ->
  gen_server:start(?MODULE, [ValueName, ValueOrigin], []).

%% @private
%% @doc Start value keeper process.

start_link(ValueName, ValueOrigin) ->
  gen_server:start_link(?MODULE, [ValueName, ValueOrigin], []).

%%%---------------------------------------------------------------------------
%%% public interface
%%%---------------------------------------------------------------------------

%% @doc Spawn a new value keeper.

-spec spawn_keeper(statip_value:name(), statip_value:origin()) ->
  {ok, pid()} | ignore.

spawn_keeper(ValueName, ValueOrigin) ->
  statip_value_burst_sup:spawn_keeper(ValueName, ValueOrigin).

%% @doc Restore all the records in a value registry.
%%
%%   Unlike with {@link add/2}, value keeper doesn't send an update to {@link
%%   statip_state_log}.

-spec restore(pid(), [#value{}]) ->
  ok.

restore(Pid, Records) ->
  gen_server:call(Pid, {restore, Records}).

%% @doc Add/update record to a value registry.

-spec add(pid(), #value{}) ->
  ok.

add(Pid, Record = #value{}) ->
  gen_server:cast(Pid, {add, Record}).

%% @doc List all keys from value registry.

-spec list_keys(pid()) ->
  [statip_value:key()].

list_keys(Pid) ->
  gen_server:call(Pid, list_keys).

%% @doc Retrieve all records from value registry.

-spec list_records(pid()) ->
  [#value{}].

list_records(Pid) ->
  gen_server:call(Pid, list_records).

%% @doc Get a record for a specific key.

-spec get_record(pid(), statip_value:key()) ->
  #value{} | none.

get_record(Pid, Key) ->
  gen_server:call(Pid, {get_record, Key}).

%%%---------------------------------------------------------------------------
%%% gen_server callbacks
%%%---------------------------------------------------------------------------

%%----------------------------------------------------------
%% initialization/termination {{{

%% @private
%% @doc Initialize {@link gen_server} state.

init([ValueName, ValueOrigin] = _Args) ->
  case statip_registry:add(ValueName, ValueOrigin, self(), ?MODULE) of
    ok ->
      State = #state{
        value_name = ValueName,
        value_origin = ValueOrigin,
        current_entries  = gb_trees:empty(),
        previous_entries = gb_trees:empty(),
        expires = undefined
      },
      {ok, State, 1000};
    {error, name_taken} ->
      ignore
  end.

%% @private
%% @doc Clean up {@link gen_server} state.

terminate(_Arg, _State) ->
  ok.

%% }}}
%%----------------------------------------------------------
%% communication {{{

%% @private
%% @doc Handle {@link gen_server:call/2}.

handle_call({restore, Records} = _Request, _From, State = #state{}) ->
  {reply, 'TODO', State, 1000};

handle_call(list_keys = _Request, _From,
            State = #state{current_entries = CurEntries,
                           previous_entries = OldEntries}) ->
  Result = get_record_keys(CurEntries, OldEntries),
  {reply, Result, State, 1000};

handle_call(list_records = _Request, _From,
            State = #state{current_entries = CurEntries,
                           previous_entries = OldEntries}) ->
  Result = get_all_records(CurEntries, OldEntries),
  {reply, Result, State, 1000};

handle_call({get_record, Key} = _Request, _From,
            State = #state{current_entries = CurEntries,
                           previous_entries = OldEntries}) ->
  Result = get_record(Key, CurEntries, OldEntries),
  {reply, Result, State, 1000};

%% unknown calls
handle_call(_Request, _From, State) ->
  {reply, {error, unknown_call}, State}.

%% @private
%% @doc Handle {@link gen_server:cast/2}.

handle_cast({add, Record = #value{}} = _Request, State) ->
  NewState = add_record(Record, State),
  {noreply, NewState, 1000};

%% unknown casts
handle_cast(_Request, State) ->
  {noreply, State, 1000}.

%% @private
%% @doc Handle incoming messages.

handle_info(timeout = _Message, State = #state{expires = ExpiryTime}) ->
  % XXX: `undefined > integer()', so initial empty state won't die
  % accidentally
  case statip_value:timestamp() of
    Now when Now >= ExpiryTime -> {stop, normal, State};
    Now when Now <  ExpiryTime -> {noreply, State, 1000}
  end;

%% unknown messages
handle_info(_Message, State) ->
  {noreply, State, 1000}.

%% }}}
%%----------------------------------------------------------
%% code change {{{

%% @private
%% @doc Handle code change.

code_change(_OldVsn, State, _Extra) ->
  {ok, State}.

%% }}}
%%----------------------------------------------------------

%%%---------------------------------------------------------------------------

add_record(Record = #value{key = Key, expires = NewExpiryTime},
           State = #state{current_entries = Entries, expires = ExpiryTime}) ->
  case gb_trees:is_defined(Key, Entries) of
    true ->
      % key that occurred in last burst, so it's a new burst apparently;
      % rotate and take the new record's expiry time
      _NewState = State#state{
        previous_entries = Entries,
        current_entries = gb_trees:insert(Key, Record, gb_trees:empty()),
        expires = NewExpiryTime
      };
    false ->
      % a yet-unknown key, so it's probably the same burst as the last one
      NewState = State#state{
        current_entries = gb_trees:insert(Key, Record, Entries)
      },
      % keep the expiry time that is later from the two (`undefined' is always
      % the earlier one)
      case ExpiryTime of
        undefined ->
          NewState#state{expires = NewExpiryTime};
        _ when ExpiryTime < NewExpiryTime ->
          NewState#state{expires = NewExpiryTime};
        _ when ExpiryTime >= NewExpiryTime ->
          NewState
      end
  end.

get_record(Key, CurEntries, OldEntries) ->
  case gb_trees:lookup(Key, CurEntries) of
    {value, Record} ->
      Record;
    none ->
      case gb_trees:lookup(Key, OldEntries) of
        {value, Record} -> Record;
        none -> none
      end
  end.

get_all_records(CurEntries, OldEntries) ->
  CurRecords = gb_trees:values(CurEntries),
  All = records_walk(CurEntries, CurRecords, gb_trees:iterator(OldEntries)),
  lists:keysort(#value.sort_key, All).

records_walk(SkipMap, Acc, Iterator) ->
  case gb_trees:next(Iterator) of
    {Key, Record, NewIterator} ->
      case gb_trees:is_defined(Key, SkipMap) of
        true  -> records_walk(SkipMap, Acc,            NewIterator);
        false -> records_walk(SkipMap, [Record | Acc], NewIterator)
      end;
    none ->
      Acc
  end.

get_record_keys(CurEntries, OldEntries) ->
  % `gb_trees:keys()' returns the entries ordered by `key' field, and we need
  % `sort_key' field order; `get_all_records()' does that, so let's just
  % extract the appropriate field from that list
  [Key || #value{key = Key} <- get_all_records(CurEntries, OldEntries)].

%%%---------------------------------------------------------------------------
%%% vim:ft=erlang:foldmethod=marker
