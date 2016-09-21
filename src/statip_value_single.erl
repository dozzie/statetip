%%%---------------------------------------------------------------------------
%%% @doc
%%%   Single (non-burst) value keeper process.
%%%
%%% @todo update disk state that fills things after restart
%%% @end
%%%---------------------------------------------------------------------------

-module(statip_value_single).

-behaviour(gen_server).
-behaviour(statip_value).

%% public interface
-export([spawn_keeper/2, add/2, list_keys/1, list_records/1, get_record/2]).

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
  entries :: gb_tree(), % statip_value:key() -> #value{}
  expiry :: statip_pqueue:pqueue() % {RecordExpiryTime, RecordKey}
}).

%%% }}}
%%%---------------------------------------------------------------------------
%%% supervision tree API
%%%---------------------------------------------------------------------------

%% @private
%% @doc Start example process.

start(ValueName, ValueOrigin) ->
  gen_server:start(?MODULE, [ValueName, ValueOrigin], []).

%% @private
%% @doc Start example process.

start_link(ValueName, ValueOrigin) ->
  gen_server:start_link(?MODULE, [ValueName, ValueOrigin], []).

%%%---------------------------------------------------------------------------
%%% public interface
%%%---------------------------------------------------------------------------

%% @doc Spawn a new value keeper.

-spec spawn_keeper(statip_value:name(), statip_value:origin()) ->
  {ok, pid()} | ignore.

spawn_keeper(ValueName, ValueOrigin) ->
  statip_value_single_sup:spawn_keeper(ValueName, ValueOrigin).

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
%% @doc Initialize event handler.

init([ValueName, ValueOrigin] = _Args) ->
  case statip_registry:add(ValueName, ValueOrigin, self(), ?MODULE) of
    ok ->
      State = #state{
        value_name = ValueName,
        value_origin = ValueOrigin,
        entries = undefined,
        expiry = undefined
      },
      {ok, State, 1000};
    {error, name_taken} ->
      ignore
  end.

%% @private
%% @doc Clean up after event handler.

terminate(_Arg, _State) ->
  ok.

%% }}}
%%----------------------------------------------------------
%% communication {{{

%% @private
%% @doc Handle {@link gen_server:call/2}.

handle_call(list_keys = _Request, _From, State = #state{entries = Entries}) ->
  Result = get_record_keys(Entries),
  {reply, Result, State, 1000};

handle_call(list_records = _Request, _From,
            State = #state{entries = Entries}) ->
  Result = get_all_records(Entries),
  {reply, Result, State, 1000};

handle_call({get_record, Key} = _Request, _From,
            State = #state{entries = Entries}) ->
  Result = get_record_1(Key, Entries),
  {reply, Result, State, 1000};

%% unknown calls
handle_call(_Request, _From, State) ->
  {reply, {error, unknown_call}, State, 1000}.

%% @private
%% @doc Handle {@link gen_server:cast/2}.

handle_cast({add, Record = #value{}} = _Request,
            State = #state{entries = Entries, expiry = ExpiryQ}) ->
  {NewEntries, NewExpiryQ} = add_record(Record, Entries, ExpiryQ),
  NewState = State#state{
    entries = NewEntries,
    expiry = NewExpiryQ
  },
  {noreply, NewState, 1000};

%% unknown casts
handle_cast(_Request, State) ->
  {noreply, State, 1000}.

%% @private
%% @doc Handle incoming messages.

handle_info(timeout = _Message,
            State = #state{entries = undefined, expiry = undefined}) ->
  {noreply, State, 1000};

%% delete expired records
handle_info(timeout = _Message,
            State = #state{entries = Entries, expiry = ExpiryQ}) ->
  {NewEntries, NewExpiryQ} = prune_expired_records(Entries, ExpiryQ),
  NewState = State#state{
    entries = NewEntries,
    expiry = NewExpiryQ
  },
  case gb_trees:is_empty(NewEntries) of
    true  -> {stop, normal, NewState};
    false -> {noreply, NewState, 1000}
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

%% @doc Add a new record to record store and to expiry queue.

-spec add_record(#value{},
                 gb_tree() | undefined, statip_pqueue:pqueue() | undefined) ->
  {gb_tree(), statip_pqueue:pqueue()}.

add_record(Record, undefined = _Entries, ExpiryQ) ->
  add_record(Record, gb_trees:empty(), ExpiryQ);

add_record(Record, Entries, undefined = _ExpiryQ) ->
  add_record(Record, Entries, statip_pqueue:new());

add_record(Record = #value{key = Key, expires = Expires}, Entries, ExpiryQ) ->
  NewExpiryQ = case gb_trees:lookup(Key, Entries) of
    {value, #value{expires = OldExpires}} ->
      statip_pqueue:update(Key, OldExpires, Expires, ExpiryQ);
    none ->
      statip_pqueue:add(Key, Expires, ExpiryQ)
  end,
  NewEntries = gb_trees:enter(Key, Record, Entries),
  {NewEntries, NewExpiryQ}.

%% @doc Remove expired records from record store and expiry queue.

-spec prune_expired_records(gb_tree(), statip_pqueue:pqueue()) ->
  {gb_tree(), statip_pqueue:pqueue()}.

prune_expired_records(Entries, ExpiryQ) ->
  prune_expired_records(statip_value:timestamp(), Entries, ExpiryQ).

%% @doc Workhorse for {@link prune_expired_records/2}.

prune_expired_records(Now, Entries, ExpiryQ) ->
  case statip_pqueue:peek(ExpiryQ) of
    none ->
      % queue empty, so nothing more could expire
      {Entries, ExpiryQ};
    {_, ExpiryTime} when ExpiryTime > Now ->
      % the earliest expiration time is in the future
      {Entries, ExpiryQ};
    {Key, ExpiryTime} when ExpiryTime =< Now ->
      % another entry expired; pop it from the priority queue, remove from
      % entries set, and check if another record expired
      {Key, ExpiryTime, NewExpiryQ} = statip_pqueue:pop(ExpiryQ),
      NewEntries = gb_trees:delete(Key, Entries),
      prune_expired_records(Now, NewEntries, NewExpiryQ)
  end.

%% @doc Retrieve the record for specified key from record store.

-spec get_record_1(statip_value:key(), gb_tree()) ->
  #value{} | none.

get_record_1(Key, Entries) ->
  case gb_trees:lookup(Key, Entries) of
    {value, Record} -> Record;
    none -> none
  end.

%% @doc Retrieve all records from record store.

-spec get_all_records(gb_tree()) ->
  [#value{}].

get_all_records(Entries) ->
  Records = gb_trees:values(Entries),
  lists:keysort(#value.sort_key, Records).

%% @doc Retrieve keys for the records from record store.

-spec get_record_keys(gb_tree()) ->
  [statip_value:key()].

get_record_keys(Entries) ->
  gb_trees:keys(Entries).

%%%---------------------------------------------------------------------------
%%% vim:ft=erlang:foldmethod=marker
