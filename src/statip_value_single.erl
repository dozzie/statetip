%%%---------------------------------------------------------------------------
%%% @doc
%%%   Single (non-burst) value keeper process.
%%%
%%% @todo `list_records(Pid) -> [#value{}]' (not really `#value{}')
%%% @todo `get_record(Pid, Key) -> #value{} | none' (not really `#value{}')
%%% @todo update disk state that fills things after restart
%%% @end
%%%---------------------------------------------------------------------------

-module(statip_value_single).

-behaviour(gen_server).

%% public interface
-export([add/7, list_keys/1]).

%% supervision tree API
-export([start/2, start_link/2]).

%% gen_server callbacks
-export([init/1, terminate/2]).
-export([handle_call/3, handle_cast/2, handle_info/2]).
-export([code_change/3]).

%%%---------------------------------------------------------------------------
%%% types {{{

-record(value, {
  key      :: statip_value:key(),
  sort_key :: statip_value:key(),
  value    :: statip_value:value(),
  severity :: statip_value:severity(),
  info     :: statip_value:info(),
  created  :: statip_value:timestamp(),
  expires  :: statip_value:timestamp()
}).

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

%% @doc Add/update record to a value registry.

-spec add(pid(), statip_value:key(), statip_value:value(),
          statip_value:severity(), statip_value:info(),
          statip_value:timestamp(), statip_value:expiry()) ->
  ok.

add(Pid, Key, Value, Severity, Info, Created, Expiry) ->
  Record = #value{
    key = Key,
    sort_key = Key,
    value = Value,
    severity = Severity,
    info = Info,
    created = Created,
    expires = Created + Expiry
  },
  gen_server:cast(Pid, {add, Record}).

%% @doc List all keys from value registry.

-spec list_keys(pid()) ->
  [statip_value:key()].

list_keys(Pid) ->
  gen_server:call(Pid, list_keys).

%%%---------------------------------------------------------------------------
%%% gen_server callbacks
%%%---------------------------------------------------------------------------

%%----------------------------------------------------------
%% initialization/termination {{{

%% @private
%% @doc Initialize event handler.

init([ValueName, ValueOrigin] = _Args) ->
  State = #state{
    value_name = ValueName,
    value_origin = ValueOrigin,
    entries = gb_trees:empty(),
    expiry = statip_pqueue:new()
  },
  {ok, State, 1000}.

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

%% delete expired records
handle_info(timeout = _Message,
            State = #state{entries = Entries, expiry = ExpiryQ}) ->
  {NewEntries, NewExpiryQ} = prune_expired_records(Entries, ExpiryQ),
  NewState = State#state{
    entries = NewEntries,
    expiry = NewExpiryQ
  },
  {noreply, NewState, 1000};

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

-spec add_record(#value{}, gb_tree(), statip_pqueue:pqueue()) ->
  {gb_tree(), statip_pqueue:pqueue()}.

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

%% @doc Retrieve keys for the records from record store.

-spec get_record_keys(gb_tree()) ->
  [statip_value:key()].

get_record_keys(Entries) ->
  gb_trees:keys(Entries).

%%%---------------------------------------------------------------------------
%%% vim:ft=erlang:foldmethod=marker
