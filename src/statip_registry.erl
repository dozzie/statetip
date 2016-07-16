%%%---------------------------------------------------------------------------
%%% @doc
%%%   Value registry.
%%%
%%% @todo `list_names() -> [statip_value:name()]'
%%% @todo `list_origins(ValueName) -> [statip_value:origin()]'
%%% @end
%%%---------------------------------------------------------------------------

-module(statip_registry).

-behaviour(gen_server).

%% public interface
-export([add/4, find_process/2]).

%% supervision tree API
-export([start/0, start_link/0]).

%% gen_server callbacks
-export([init/1, terminate/2]).
-export([handle_call/3, handle_cast/2, handle_info/2]).
-export([code_change/3]).

%%%---------------------------------------------------------------------------
%%% types {{{

-define(ETS_VALUES, statip_registry_values).

-record(value, {
  key :: {statip_value:name(), statip_value:origin()},
  pid :: pid(),
  module :: module()
}).

-record(state, {
  monitor :: ets:tab()
}).

%%% }}}
%%%---------------------------------------------------------------------------
%%% supervision tree API
%%%---------------------------------------------------------------------------

%% @private
%% @doc Start example process.

start() ->
  gen_server:start({local, ?MODULE}, ?MODULE, [], []).

%% @private
%% @doc Start example process.

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

add(ValueName, ValueOrigin, Pid, Module) ->
  gen_server:call(?MODULE, {add, ValueName, ValueOrigin, Pid, Module}).

%% @doc Find a keeper process for a given value.
%%
%% @see add/4

-spec find_process(statip_value:name(), statip_value:origin()) ->
  {pid(), module()} | none.

find_process(ValueName, ValueOrigin) ->
  case ets:lookup(?ETS_VALUES, {ValueName, ValueOrigin}) of
    [#value{pid = Pid, module = Module}] ->
      _Result = {Pid, Module};
    [] ->
      _Result = none
  end.

%-spec list_names() ->
%  [statip_value:name()].

%-spec list_origins(statip_value:name()) ->
%  [statip_value:origin()].

%%%---------------------------------------------------------------------------
%%% gen_server callbacks
%%%---------------------------------------------------------------------------

%%----------------------------------------------------------
%% initialization/termination {{{

%% @private
%% @doc Initialize event handler.

init(_Args) ->
  Monitor = ets:new(statip_registry_monitor, [set]),
  ?ETS_VALUES = ets:new(?ETS_VALUES, [named_table, set, {keypos, #value.key},
                                      protected, {read_concurrency, true}]),
  State = #state{
    monitor = Monitor
  },
  {ok, State}.

%% @private
%% @doc Clean up after event handler.

terminate(_Arg, _State = #state{monitor = Monitor}) ->
  ets:delete(?ETS_VALUES),
  ets:delete(Monitor),
  ok.

%% }}}
%%----------------------------------------------------------
%% communication {{{

%% @private
%% @doc Handle {@link gen_server:call/2}.

handle_call({add, ValueName, ValueOrigin, Pid, Module} = _Request, _From,
            State = #state{monitor = Monitor}) ->
  RegKey = {ValueName, ValueOrigin},
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
