%%%---------------------------------------------------------------------------
%%% @doc
%%%   Value group keeper process for unrelated values.
%%% @end
%%%---------------------------------------------------------------------------

-module(statip_keeper_unrelated).

-behaviour(gen_server).
-behaviour(statip_keeper).

%% public interface
-export([spawn_keeper/2, add/2, restore/2]).
-export([list_keys/1, list_values/1, get_value/2]).

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
  group_name :: statip_value:name(),
  group_origin :: statip_value:origin(),
  entries :: gb_tree(), % statip_value:key() -> #value{}
  expiry :: statip_pqueue:pqueue() % {ValueExpiryTime, ValueKey}
}).

%%% }}}
%%%---------------------------------------------------------------------------
%%% supervision tree API
%%%---------------------------------------------------------------------------

%% @private
%% @doc Start value keeper process.

start(GroupName, GroupOrigin) ->
  gen_server:start(?MODULE, [GroupName, GroupOrigin], []).

%% @private
%% @doc Start value keeper process.

start_link(GroupName, GroupOrigin) ->
  gen_server:start_link(?MODULE, [GroupName, GroupOrigin], []).

%%%---------------------------------------------------------------------------
%%% public interface
%%%---------------------------------------------------------------------------

%% @doc Spawn a new value keeper.

-spec spawn_keeper(statip_value:name(), statip_value:origin()) ->
  {ok, pid()} | ignore.

spawn_keeper(GroupName, GroupOrigin) ->
  statip_keeper_unrelated_sup:spawn_keeper(GroupName, GroupOrigin).

%% @doc Restore values remembered by value group keeper.
%%
%%   Unlike {@link add/2}, keeper doesn't send an update to {@link
%%   statip_state_log}.

-spec restore(pid(), [#value{}, ...]) ->
  ok.

restore(Pid, Values) ->
  gen_server:call(Pid, {restore, Values}).

%% @doc Add a new value or update remembered one by the keeper.

-spec add(pid(), #value{}) ->
  ok.

add(Pid, Value = #value{}) ->
  gen_server:cast(Pid, {add, Value}).

%% @doc List keys of all values remembered by the keeper.

-spec list_keys(pid()) ->
  [statip_value:key()].

list_keys(Pid) ->
  gen_server:call(Pid, list_keys).

%% @doc Retrieve all values remembered by the keeper.

-spec list_values(pid()) ->
  [#value{}].

list_values(Pid) ->
  gen_server:call(Pid, list_values).

%% @doc Get a specific value from keeper.

-spec get_value(pid(), statip_value:key()) ->
  #value{} | none.

get_value(Pid, Key) ->
  gen_server:call(Pid, {get_value, Key}).

%%%---------------------------------------------------------------------------
%%% gen_server callbacks
%%%---------------------------------------------------------------------------

%%----------------------------------------------------------
%% initialization/termination {{{

%% @private
%% @doc Initialize {@link gen_server} state.

init([GroupName, GroupOrigin] = _Args) ->
  case statip_registry:add(GroupName, GroupOrigin, self(), ?MODULE) of
    ok ->
      State = #state{
        group_name = GroupName,
        group_origin = GroupOrigin,
        entries = undefined,
        expiry = undefined
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

handle_call({restore, Values} = _Request, _From, State = #state{}) ->
  % XXX: expiry time of the values will be taken care of by the regular
  % mechanisms, additionally producing `{clear, Key}' log records, which is
  % desired for next restart
  {NewEntries, NewExpiryQ} = lists:foldl(
    fun(V, {E,Q}) -> store_add(V, E, Q) end,
    {undefined, undefined},
    Values
  ),
  NewState = State#state{
    entries = NewEntries,
    expiry = NewExpiryQ
  },
  {reply, ok, NewState, 1000};

handle_call(list_keys = _Request, _From, State = #state{entries = Entries}) ->
  Result = store_get_keys(Entries),
  {reply, Result, State, 1000};

handle_call(list_values = _Request, _From,
            State = #state{entries = Entries}) ->
  Result = store_get_all_values(Entries),
  {reply, Result, State, 1000};

handle_call({get_value, Key} = _Request, _From,
            State = #state{entries = Entries}) ->
  Result = store_get_value(Key, Entries),
  {reply, Result, State, 1000};

%% unknown calls
handle_call(_Request, _From, State) ->
  {reply, {error, unknown_call}, State, 1000}.

%% @private
%% @doc Handle {@link gen_server:cast/2}.

handle_cast({add, Value = #value{}} = _Request,
            State = #state{entries = Entries, expiry = ExpiryQ,
                           group_name = GroupName,
                           group_origin = GroupOrigin}) ->
  statip_state_log:set(GroupName, GroupOrigin, unrelated, Value),
  {NewEntries, NewExpiryQ} = store_add(Value, Entries, ExpiryQ),
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

%% delete expired values
handle_info(timeout = _Message,
            State = #state{entries = Entries, expiry = ExpiryQ,
                           group_name = GroupName,
                           group_origin = GroupOrigin}) ->
  ValueGroup = {GroupName, GroupOrigin},
  {NewEntries, NewExpiryQ} = store_prune_expired(Entries, ExpiryQ, ValueGroup),
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

%% @doc Add a new value to value store and to expiry queue.

-spec store_add(#value{}, gb_tree() | undefined,
                statip_pqueue:pqueue() | undefined) ->
  {gb_tree(), statip_pqueue:pqueue()}.

store_add(Value, undefined = _Entries, ExpiryQ) ->
  store_add(Value, gb_trees:empty(), ExpiryQ);

store_add(Value, Entries, undefined = _ExpiryQ) ->
  store_add(Value, Entries, statip_pqueue:new());

store_add(Value = #value{key = Key, expires = Expires}, Entries, ExpiryQ) ->
  NewExpiryQ = case gb_trees:lookup(Key, Entries) of
    {value, #value{expires = OldExpires}} ->
      statip_pqueue:update(Key, OldExpires, Expires, ExpiryQ);
    none ->
      statip_pqueue:add(Key, Expires, ExpiryQ)
  end,
  NewEntries = gb_trees:enter(Key, Value, Entries),
  {NewEntries, NewExpiryQ}.

%% @doc Remove expired values from value store and expiry queue.

-spec store_prune_expired(gb_tree(), statip_pqueue:pqueue(),
                          {statip_value:name(), statip_value:origin()}) ->
  {gb_tree(), statip_pqueue:pqueue()}.

store_prune_expired(Entries, ExpiryQ, ValueGroup) ->
  store_prune_expired(statip_value:timestamp(), Entries, ExpiryQ, ValueGroup).

%% @doc Workhorse for {@link store_prune_expired/2}.

store_prune_expired(Now, Entries, ExpiryQ, {Name, Origin} = ValueGroup) ->
  case statip_pqueue:peek(ExpiryQ) of
    none ->
      % queue empty, so nothing more could expire
      {Entries, ExpiryQ};
    {_, ExpiryTime} when ExpiryTime > Now ->
      % the earliest expiration time is in the future
      {Entries, ExpiryQ};
    {Key, ExpiryTime} when ExpiryTime =< Now ->
      % another entry expired; pop it from the priority queue, remove from
      % entries set, and check if another value expired
      {Key, ExpiryTime, NewExpiryQ} = statip_pqueue:pop(ExpiryQ),
      NewEntries = gb_trees:delete(Key, Entries),
      statip_state_log:clear(Name, Origin, Key),
      store_prune_expired(Now, NewEntries, NewExpiryQ, ValueGroup)
  end.

%% @doc Retrieve specific value from value store.

-spec store_get_value(statip_value:key(), gb_tree()) ->
  #value{} | none.

store_get_value(Key, Entries) ->
  case gb_trees:lookup(Key, Entries) of
    {value, Value} -> Value;
    none -> none
  end.

%% @doc Retrieve all records from record store.

-spec store_get_all_values(gb_tree()) ->
  [#value{}].

store_get_all_values(Entries) ->
  Values = gb_trees:values(Entries),
  lists:keysort(#value.sort_key, Values).

%% @doc Retrieve keys for the records from record store.

-spec store_get_keys(gb_tree()) ->
  [statip_value:key()].

store_get_keys(Entries) ->
  gb_trees:keys(Entries).

%%%---------------------------------------------------------------------------
%%% vim:ft=erlang:foldmethod=marker
