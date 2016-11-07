%%%---------------------------------------------------------------------------
%%% @doc
%%%   Value registry.
%%% @end
%%%---------------------------------------------------------------------------

-module(statip_registry).

-behaviour(gen_server).

%% public interface
-export([add/4, find_process/2]).
-export([list_names/0, list_origins/1]).

%% supervision tree API
-export([start/0, start_link/0]).

%% gen_server callbacks
-export([init/1, terminate/2]).
-export([handle_call/3, handle_cast/2, handle_info/2]).
-export([code_change/3]).

%%%---------------------------------------------------------------------------
%%% types {{{

-include_lib("stdlib/include/ms_transform.hrl"). % ets:fun2ms()

-define(ETS_VALUES, statip_registry_values).

-type ms() :: '$1' | '$2' | '_'.
%% Type to add to the record to make Dialyzer happy about ets:select()

-record(value, {
  key :: {statip_value:name() | ms(), statip_value:origin() | ms()},
  pid :: pid() | ms(),
  module :: module() | ms()
}).

-record(state, {
  monitor :: ets:tab()
}).

%%% }}}
%%%---------------------------------------------------------------------------
%%% supervision tree API
%%%---------------------------------------------------------------------------

%% @private
%% @doc Start registry process.

start() ->
  gen_server:start({local, ?MODULE}, ?MODULE, [], []).

%% @private
%% @doc Start registry process.

start_link() ->
  gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%%%---------------------------------------------------------------------------
%%% public interface
%%%---------------------------------------------------------------------------

%% @doc Register a value keeper process.
%%
%%   `Module' is a module that implements interface described in {@link
%%   statip_value} which should be used for communication with the process.

-spec add(statip_value:name(), statip_value:origin(), pid(), module()) ->
  ok | {error, name_taken}.

add(GroupName, GroupOrigin, Pid, Module) ->
  gen_server:call(?MODULE, {add, GroupName, GroupOrigin, Pid, Module}).

%% @doc Find a keeper process for a given value.
%%
%% @see add/4

-spec find_process(statip_value:name(), statip_value:origin()) ->
  {pid(), module()} | none.

find_process(GroupName, GroupOrigin) ->
  case ets:lookup(?ETS_VALUES, {GroupName, GroupOrigin}) of
    [#value{pid = Pid, module = Module}] ->
      _Result = {Pid, Module};
    [] ->
      _Result = none
  end.

-spec list_names() ->
  [statip_value:name()].

list_names() ->
  MatchSpec = ets:fun2ms(fun(#value{key = {Name, _}}) -> Name end),
  lists:usort(ets:select(?ETS_VALUES, MatchSpec)).

-spec list_origins(statip_value:name()) ->
  [statip_value:origin()].

list_origins(GroupName) ->
  MatchSpec = ets:fun2ms(
    fun(#value{key = {Name, Origin}}) when Name == GroupName -> Origin end
  ),
  ets:select(?ETS_VALUES, MatchSpec).

%%%---------------------------------------------------------------------------
%%% gen_server callbacks
%%%---------------------------------------------------------------------------

%%----------------------------------------------------------
%% initialization/termination {{{

%% @private
%% @doc Initialize {@link gen_server} state.

init(_Args) ->
  Monitor = ets:new(statip_registry_monitor, [set]),
  ?ETS_VALUES = ets:new(?ETS_VALUES, [named_table, set, {keypos, #value.key},
                                      protected, {read_concurrency, true}]),
  State = #state{
    monitor = Monitor
  },
  {ok, State}.

%% @private
%% @doc Clean up {@link gen_server} state.

terminate(_Arg, _State = #state{monitor = Monitor}) ->
  ets:delete(?ETS_VALUES),
  ets:delete(Monitor),
  ok.

%% }}}
%%----------------------------------------------------------
%% communication {{{

%% @private
%% @doc Handle {@link gen_server:call/2}.

handle_call({add, GroupName, GroupOrigin, Pid, Module} = _Request, _From,
            State = #state{monitor = Monitor}) ->
  RegKey = {GroupName, GroupOrigin},
  RegRecord = #value{key = RegKey, pid = Pid, module = Module},
  case ets:insert_new(?ETS_VALUES, RegRecord) of
    true ->
      Ref = erlang:monitor(process, Pid),
      ets:insert(Monitor, {Ref, RegKey}),
      Result = ok;
    false ->
      Result = {error, name_taken}
  end,
  {reply, Result, State};

%% unknown calls
handle_call(_Request, _From, State) ->
  {reply, {error, unknown_call}, State}.

%% @private
%% @doc Handle {@link gen_server:cast/2}.

%% unknown casts
handle_cast(_Request, State) ->
  {noreply, State}.

%% @private
%% @doc Handle incoming messages.

handle_info({'DOWN', Ref, process, _Pid, _Reason} = _Message,
            State = #state{monitor = Monitor}) ->
  case ets:lookup(Monitor, Ref) of
    [{Ref, RegKey}] ->
      ets:delete(Monitor, Ref),
      ets:delete(?ETS_VALUES, RegKey);
    [] ->
      ignore
  end,
  {noreply, State};

%% unknown messages
handle_info(_Message, State) ->
  {noreply, State}.

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
%%% vim:ft=erlang:foldmethod=marker
