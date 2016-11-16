%%%---------------------------------------------------------------------------
%%% @doc
%%%   Value group keeper process for related values.
%%% @end
%%%---------------------------------------------------------------------------

-module(statip_keeper_related).

-behaviour(gen_server).
-behaviour(statip_keeper).

%% public interface
-export([spawn_keeper/2, restore/2, add/2]).
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
  current_entries  :: gb_tree(), % statip_value:key() -> #value{}
  previous_entries :: gb_tree(), % statip_value:key() -> #value{}
  expires :: statip_value:timestamp()
}).

%%% }}}
%%%---------------------------------------------------------------------------
%%% supervision tree API
%%%---------------------------------------------------------------------------

%% @private
%% @doc Start keeper process.

start(GroupName, GroupOrigin) ->
  gen_server:start(?MODULE, [GroupName, GroupOrigin], []).

%% @private
%% @doc Start keeper process.

start_link(GroupName, GroupOrigin) ->
  gen_server:start_link(?MODULE, [GroupName, GroupOrigin], []).

%%%---------------------------------------------------------------------------
%%% public interface
%%%---------------------------------------------------------------------------

%% @doc Spawn a new value keeper.

-spec spawn_keeper(statip_value:name(), statip_value:origin()) ->
  {ok, pid()} | ignore.

spawn_keeper(GroupName, GroupOrigin) ->
  statip_keeper_related_sup:spawn_keeper(GroupName, GroupOrigin).

%% @doc Restore values remembered by value group keeper.
%%
%%   Unlike {@link add/2}, keeper doesn't send an update to {@link
%%   statip_state_log}.
%%
%%   Values list is expected not to contain two values with the same key.

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

handle_call({restore, Values} = _Request, _From, State) ->
  % TODO: send "rotate" record on first value that comes later
  NewState = restore_values(Values, State),
  {reply, ok, NewState, 1000};

handle_call(list_keys = _Request, _From,
            State = #state{current_entries = CurEntries,
                           previous_entries = OldEntries}) ->
  Result = get_value_keys(CurEntries, OldEntries),
  {reply, Result, State, 1000};

handle_call(list_values = _Request, _From,
            State = #state{current_entries = CurEntries,
                           previous_entries = OldEntries}) ->
  Result = get_all_values(CurEntries, OldEntries),
  {reply, Result, State, 1000};

handle_call({get_value, Key} = _Request, _From,
            State = #state{current_entries = CurEntries,
                           previous_entries = OldEntries}) ->
  Result = get_value(Key, CurEntries, OldEntries),
  {reply, Result, State, 1000};

%% unknown calls
handle_call(_Request, _From, State) ->
  {reply, {error, unknown_call}, State}.

%% @private
%% @doc Handle {@link gen_server:cast/2}.

handle_cast({add, Value = #value{}} = _Request,
            State = #state{group_name = GroupName,
                           group_origin = GroupOrigin}) ->
  % XXX: `add_value()' can send a "rotate" record, so `set()' goes after that
  NewState = add_value(Value, State),
  statip_state_log:set(GroupName, GroupOrigin, related, Value),
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

restore_values(Values, State = #state{}) ->
  % TODO: honour expiry time of the values
  Entries = lists:foldl(
    fun(V = #value{key = K}, Tree) -> gb_trees:insert(K, V, Tree) end,
    gb_trees:empty(),
    Values
  ),
  _NewState = State#state{
    current_entries = gb_trees:empty(),
    previous_entries = Entries,
    expires = undefined
  }.

add_value(Value = #value{key = Key, expires = NewExpiryTime},
          State = #state{current_entries = Entries, expires = ExpiryTime,
                         group_name = GroupName,
                         group_origin = GroupOrigin}) ->
  case gb_trees:is_defined(Key, Entries) of
    true ->
      statip_state_log:rotate(GroupName, GroupOrigin),
      % key that occurred in last burst, so it's a new burst apparently;
      % rotate and take the new value's expiry time
      _NewState = State#state{
        previous_entries = Entries,
        current_entries = gb_trees:insert(Key, Value, gb_trees:empty()),
        expires = NewExpiryTime
      };
    false ->
      % a yet-unknown key, so it's probably the same burst as the last one
      NewState = State#state{
        current_entries = gb_trees:insert(Key, Value, Entries)
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

get_value(Key, CurEntries, OldEntries) ->
  case gb_trees:lookup(Key, CurEntries) of
    {value, Value} ->
      Value;
    none ->
      case gb_trees:lookup(Key, OldEntries) of
        {value, Value} -> Value;
        none -> none
      end
  end.

get_all_values(CurEntries, OldEntries) ->
  CurValues = gb_trees:values(CurEntries),
  All = tree_walk(CurEntries, CurValues, gb_trees:iterator(OldEntries)),
  lists:keysort(#value.sort_key, All).

tree_walk(SkipMap, Acc, Iterator) ->
  case gb_trees:next(Iterator) of
    {Key, Value, NewIterator} ->
      case gb_trees:is_defined(Key, SkipMap) of
        true  -> tree_walk(SkipMap, Acc,            NewIterator);
        false -> tree_walk(SkipMap, [Value | Acc], NewIterator)
      end;
    none ->
      Acc
  end.

get_value_keys(CurEntries, OldEntries) ->
  % `gb_trees:keys()' returns the entries ordered by `key' field, and we need
  % `sort_key' field order; `get_all_values()' does that, so let's just
  % extract the appropriate field from that list
  [Key || #value{key = Key} <- get_all_values(CurEntries, OldEntries)].

%%%---------------------------------------------------------------------------
%%% vim:ft=erlang:foldmethod=marker
