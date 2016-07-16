%%%---------------------------------------------------------------------------
%%% @doc
%%%   Burst value keeper process.
%%%
%%% @todo `list_records(Pid) -> [#value{}]' (not really `#value{}')
%%% @todo `get_record(Pid, Key) -> #value{} | none' (not really `#value{}')
%%% @todo update disk state that fills things after restart
%%% @end
%%%---------------------------------------------------------------------------

-module(statip_value_burst).

-behaviour(gen_server).

%% public interface
-export([add/2, list_keys/1]).

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

-spec add(pid(), #value{}) ->
  ok.

add(Pid, Record = #value{}) ->
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
%% @doc Clean up after event handler.

terminate(_Arg, _State) ->
  ok.

%% }}}
%%----------------------------------------------------------
%% communication {{{

%% @private
%% @doc Handle {@link gen_server:call/2}.

handle_call(list_keys = _Request, _From,
            State = #state{current_entries = CurEntries,
                           previous_entries = OldEntries}) ->
  Result = get_record_keys(CurEntries, OldEntries),
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

get_record_keys(CurEntries, OldEntries) ->
  % TODO: honour `sort_key' field from the records
  lists:umerge(gb_trees:keys(CurEntries), gb_trees:keys(OldEntries)).

%%%---------------------------------------------------------------------------
%%% vim:ft=erlang:foldmethod=marker
