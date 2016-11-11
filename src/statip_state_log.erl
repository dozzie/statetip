%%%---------------------------------------------------------------------------
%%% @doc
%%%   State logger process.
%%%
%%% @todo Size limit and compaction schedule
%%% @end
%%%---------------------------------------------------------------------------

-module(statip_state_log).

-behaviour(gen_server).

%% public interface
-export([set/4, clear/3, clear/2, rotate/2]).
-export([compact/0]).

%% internal interface
-export([compact/3]).

%% supervision tree API
-export([start/0, start_link/0]).

%% gen_server callbacks
-export([init/1, terminate/2]).
-export([handle_call/3, handle_cast/2, handle_info/2]).
-export([code_change/3]).

%%%---------------------------------------------------------------------------
%%% types {{{

-include("statip_value.hrl").
-include("statip_boot.hrl").

-define(LOG_FILE,              "state.log").
-define(LOG_FILE_COMPACT_TEMP, "state.log.compact").
-define(READ_BLOCK, 4096).
-define(READ_RETRIES, 3).
-define(COMPACT_DECISION_INTERVAL, timer:seconds(30)).

-record(state, {
  log_dir :: file:filename(),
  log_handle :: statip_flog:handle(),
  compaction :: {reference(), term()} | undefined,
  compaction_size :: pos_integer()
}).

%%% }}}
%%%---------------------------------------------------------------------------
%%% public interface
%%%---------------------------------------------------------------------------

%% @doc Append a value record to log file.

-spec set(statip_value:name(), statip_value:origin(), related | unrelated,
          #value{}) ->
  ok | {error, term()}.

set(GroupName, GroupOrigin, Type, Value = #value{})
when Type == related; Type == unrelated ->
  gen_server:call(?MODULE, {add, Type, GroupName, GroupOrigin, Value}).

%% @doc Append a "clear" record for specific key to log file.

-spec clear(statip_value:name(), statip_value:origin(), statip_value:key()) ->
  ok | {error, term()}.

clear(GroupName, GroupOrigin, Key) ->
  gen_server:call(?MODULE, {clear, GroupName, GroupOrigin, Key}).

%% @doc Append a "clear" record for a value group to state log file.

-spec clear(statip_value:name(), statip_value:origin()) ->
  ok | {error, term()}.

clear(GroupName, GroupOrigin) ->
  gen_server:call(?MODULE, {clear, GroupName, GroupOrigin}).

%% @doc Append a "rotate" record for related value group.

-spec rotate(statip_value:name(), statip_value:origin()) ->
  ok | {error, term()}.

rotate(GroupName, GroupOrigin) ->
  gen_server:call(?MODULE, {rotate, GroupName, GroupOrigin}).

%% @doc Start log compaction process outside of its schedule.

-spec compact() ->
  ok | {error, already_running | file:posix()}.

compact() ->
  gen_server:call(?MODULE, compact).

%%%---------------------------------------------------------------------------
%%% supervision tree API
%%%---------------------------------------------------------------------------

%% @private
%% @doc Start state logger process.

start() ->
  gen_server:start({local, ?MODULE}, ?MODULE, [], []).

%% @private
%% @doc Start state logger process.

start_link() ->
  gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%%%---------------------------------------------------------------------------
%%% gen_server callbacks
%%%---------------------------------------------------------------------------

%%----------------------------------------------------------
%% initialization/termination {{{

%% @private
%% @doc Initialize {@link gen_server} state.

init([] = _Args) ->
  % TODO: read the values of read block and read retries
  case logger_start_mode() of
    {boot, LogDir, CompactionSize} ->
      erlang:send_after(?COMPACT_DECISION_INTERVAL, self(), check_log_size),
      case replay_logfile(LogDir) of
        {ok, Entries} -> % may be []
          ok = dump_logfile(Entries, LogDir),
          ok = start_keepers(Entries),
          LogFile = filename:join(LogDir, ?LOG_FILE),
          {ok, LogH} = statip_flog:open(LogFile, [write]),
          set_booted_flag(),
          State = #state{
            log_dir = LogDir,
            log_handle = LogH,
            compaction_size = CompactionSize
          },
          {ok, State};
        %{error, bad_file = _Reason} ->
        %{error, damaged_file = _Reason} ->
        {error, Reason} ->
          {stop, {replay, Reason}}
      end;
    {crash_recovery, LogDir, CompactionSize} ->
      erlang:send_after(?COMPACT_DECISION_INTERVAL, self(), check_log_size),
      LogFile = filename:join(LogDir, ?LOG_FILE),
      case statip_flog:open(LogFile, [write]) of
        {ok, LogH} ->
          State = #state{
            log_dir = LogDir,
            log_handle = LogH,
            compaction_size = CompactionSize
          },
          {ok, State};
        {error, Reason} ->
          {stop, {reopen, Reason}}
      end;
    no_logging ->
      State = #state{
        log_dir = undefined,
        log_handle = undefined
      },
      {ok, State}
  end.

%% @private
%% @doc Clean up {@link gen_server} state.

terminate(_Arg, State) ->
  case State of
    #state{log_handle = undefined} -> ok;
    #state{log_handle = LogH} -> statip_flog:close(LogH)
  end,
  case State of
    #state{compaction = undefined} -> ok;
    #state{compaction = {_, CompactHandle}} -> abort_compaction(CompactHandle)
  end,
  ok.

%% }}}
%%----------------------------------------------------------
%% communication {{{

%% @private
%% @doc Handle {@link gen_server:call/2}.

handle_call({add, _Type, _GroupName, _GroupOrigin, _Value} = _Request, _From,
            State = #state{log_handle = undefined}) ->
  {reply, ok, State}; % ignore the entry
handle_call({add, Type, GroupName, GroupOrigin, Value} = _Request, _From,
            State = #state{log_handle = LogH}) ->
  % TODO: log any write errors (e.g. "disk full")
  statip_flog:append(LogH, GroupName, GroupOrigin, Value, Type),
  {reply, ok, State};

handle_call({clear, _GroupName, _GroupOrigin, _Key} = _Request, _From,
            State = #state{log_handle = undefined}) ->
  {reply, ok, State}; % ignore the entry
handle_call({clear, GroupName, GroupOrigin, Key} = _Request, _From,
            State = #state{log_handle = LogH}) ->
  % TODO: log any write errors (e.g. "disk full")
  statip_flog:append(LogH, GroupName, GroupOrigin, {clear, Key}, unrelated),
  {reply, ok, State};

handle_call({clear, _GroupName, _GroupOrigin} = _Request, _From,
            State = #state{log_handle = undefined}) ->
  {reply, ok, State}; % ignore the entry
handle_call({clear, GroupName, GroupOrigin} = _Request, _From,
            State = #state{log_handle = LogH}) ->
  % TODO: log any write errors (e.g. "disk full")
  statip_flog:append(LogH, GroupName, GroupOrigin, clear, related),
  {reply, ok, State};

handle_call({rotate, _GroupName, _GroupOrigin} = _Request, _From,
            State = #state{log_handle = undefined}) ->
  {reply, ok, State}; % ignore the entry
handle_call({rotate, GroupName, GroupOrigin} = _Request, _From,
            State = #state{log_handle = LogH}) ->
  % TODO: log any write errors (e.g. "disk full")
  statip_flog:append(LogH, GroupName, GroupOrigin, rotate, related),
  {reply, ok, State};

handle_call(compact = _Request, _From, State = #state{log_dir = undefined}) ->
  % ignore compaction requests
  {reply, ok, State};
handle_call(compact = _Request, _From, State = #state{compaction = {_,_}}) ->
  {reply, {error, already_running}, State};
handle_call(compact = _Request, _From, State = #state{log_dir = LogDir}) ->
  case start_compaction(LogDir) of
    {ok, {_Ref, _Handle} = CompactHandle} ->
      NewState = State#state{compaction = CompactHandle},
      {reply, ok, NewState};
    {error, Reason} ->
      % TODO: log this event
      {reply, {error, Reason}, State}
  end;

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

handle_info(check_log_size = _Message, State = #state{log_dir = undefined}) ->
  {noreply, State};
handle_info(check_log_size = _Message, State = #state{log_dir = LogDir}) ->
  erlang:send_after(?COMPACT_DECISION_INTERVAL, self(), check_log_size),
  case should_compaction_start(State) of
    true ->
      case start_compaction(LogDir) of
        {ok, {_Ref, _Handle} = CompactHandle} ->
          NewState = State#state{compaction = CompactHandle},
          {noreply, NewState};
        {error, _Reason} ->
          % TODO: log this event
          {noreply, State}
      end;
    false ->
      {noreply, State}
  end;

handle_info({compaction_finished, Ref, Result} = _Message,
            State = #state{compaction = {Ref, CompactHandle},
                           log_dir = LogDir, log_handle = LogH}) ->
  case finish_compaction(Result, CompactHandle, LogDir) of
    ok ->
      statip_flog:close(LogH),
      % TODO: handle open errors
      LogFile = filename:join(LogDir, ?LOG_FILE),
      {ok, NewLogH} = statip_flog:open(LogFile, [write]),
      NewState = State#state{
        compaction = undefined,
        log_handle = NewLogH
      },
      {noreply, NewState};
    {error, _Reason} ->
      % TODO: log this event
      % TODO: what to do now with `LogH'?
      NewState = State#state{compaction = undefined},
      {noreply, NewState}
  end;

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

%% @doc Read the log file from specified directory.

-spec replay_logfile(file:filename()) ->
  {ok, statip_flog:records() | none} | {error, Reason}
  when Reason :: bad_file | damaged_file | file:posix().

replay_logfile(LogDir) ->
  LogFile = filename:join(LogDir, ?LOG_FILE),
  case statip_flog:open(LogFile, [read]) of
    {ok, Handle} ->
      case statip_flog:replay(Handle, ?READ_BLOCK, ?READ_RETRIES) of
        {ok, Records} ->
          statip_flog:close(Handle),
          {ok, Records};
        {error, Reason} ->
          {error, Reason}
      end;
    {error, enoent} ->
      {ok, none};
    {error, Reason} ->
      {error, Reason}
  end.

%% @doc Write a compacted version of the previously read log file.

-spec dump_logfile(statip_flog:records() | none, file:filename()) ->
  ok | {error, file:posix()}.

dump_logfile(none = _Entries, _LogDir) ->
  ok;
dump_logfile(Entries, LogDir) ->
  LogFile = filename:join(LogDir, ?LOG_FILE_COMPACT_TEMP),
  _ = file:delete(LogFile),
  case statip_flog:open(LogFile, [write]) of
    {ok, Handle} ->
      try statip_flog:fold(fun write_records/4, Handle, Entries) of
        _ ->
          ok = statip_flog:close(Handle),
          file:rename(LogFile, filename:join(LogDir, ?LOG_FILE))
      catch
        throw:{error, Reason} ->
          statip_flog:close(Handle),
          {error, Reason}
      end;
    {error, Reason} ->
      {error, Reason}
  end.

%%----------------------------------------------------------
%% write replayed log entries to a log file {{{

%% @doc Write records to an opened log file.
%%
%%   Function throws {@type @{error, file:posix() | badarg@}} ({@link
%%   erlang:throw/1}) on error.
%%
%% @see statip_flog:fold/3

-spec write_records({statip_value:name(), statip_value:origin()},
                    related | unrelated, [#value{}], statip_flog:handle()) ->
  statip_flog:handle() | no_return().

write_records({GroupName, GroupOrigin} = _Key, Type, Values, Handle = Acc) ->
  case write_records(Handle, GroupName, GroupOrigin, Values, Type) of
    ok -> Acc;
    {error, Reason} -> throw({error, Reason})
  end.

%% @doc Workhorse for {@link write_records/4}.

-spec write_records(statip_flog:handle(),
                    statip_value:name(), statip_value:origin(),
                    [#value{}], related | unrelated) ->
  ok | {error, file:posix() | badarg}.

write_records(_Handle, _Name, _Origin, [] = _Values, _Type) ->
  ok;
write_records(Handle, Name, Origin, [Value | Rest] = _Values, Type) ->
  case statip_flog:append(Handle, Name, Origin, Value, Type) of
    ok -> write_records(Handle, Name, Origin, Rest, Type);
    {error, Reason} -> {error, Reason}
  end.

%% }}}
%%----------------------------------------------------------

%% @doc Start value group keeper processes for value groups replayed from log
%%   file.
%%
%% @see statip_keeper_related
%% @see statip_keeper_unrelated

-spec start_keepers(statip_flog:records() | none) ->
  ok.

start_keepers(none = _Entries) ->
  ok;
start_keepers(Entries) ->
  Acc = [],
  statip_flog:fold(fun start_keeper/4, Acc, Entries),
  ok.

%%----------------------------------------------------------
%% starting value keepers {{{

%% @doc Start a single keeper process with all the necessary values.
%%
%% @see statip_flog:fold/3

-spec start_keeper({statip_value:name(), statip_value:origin()},
                   related | unrelated, [#value{}], Acc) ->
  NewAcc
  when Acc :: any(), NewAcc :: any().

start_keeper({GroupName, GroupOrigin} = _Key, Type, Values, Acc)
when Type == related; Type == unrelated ->
  ok = statip_value:restore(GroupName, GroupOrigin, Values, Type),
  Acc.

%% }}}
%%----------------------------------------------------------

%%%---------------------------------------------------------------------------
%%% log compaction

%% @doc Log compaction process' main procedure.
%%
%% @see start_compaction/1

-spec compact(statip_flog:handle(), pid(), reference()) ->
  any().

compact(Handle, ResultTo, Ref) ->
  Result = statip_flog:replay(Handle, ?READ_BLOCK, ?READ_RETRIES),
  ResultTo ! {compaction_finished, Ref, Result}.

%% @doc Function to tell when the state logger should start compacting its
%%   log file.

-spec should_compaction_start(#state{}) ->
  true | false.

should_compaction_start(_State = #state{compaction = {_,_}}) ->
  % compaction in progress
  false;
should_compaction_start(_State = #state{log_handle = undefined}) ->
  % log file is not opened
  false;
should_compaction_start(_State = #state{compaction_size = CompactionSize,
                                        log_handle = LogH}) ->
  {ok, LogSize} = statip_flog:file_size(LogH),
  LogSize >= CompactionSize.

%% @doc Start asynchronous process of compacting a log file.
%%
%%   At the end, the calling process receives
%%   {@type @{compaction_finished, Ref :: reference(), Result :: term()@}} and
%%   should call {@link finish_compaction/3}.
%%
%% @see finish_compaction/3
%% @see abort_compaction/1

-spec start_compaction(file:filename()) ->
    {ok, {Ref :: reference(), CompactHandle :: term()}}
  | {error, file:posix()}.

start_compaction(LogDir) ->
  LogFile = filename:join(LogDir, ?LOG_FILE),
  case statip_flog:open(LogFile, [read]) of
    {ok, Handle} ->
      Ref = make_ref(),
      Pid = spawn_link(?MODULE, compact, [Handle, self(), Ref]),
      CompactHandle = {compact, Ref, Pid, Handle},
      {ok, {Ref, CompactHandle}};
    {error, Reason} ->
      {error, Reason}
  end.

%% @doc Finalize the log compaction.
%%
%%   This function should be called upon receiving {@type
%%   @{compaction_finished, _Ref :: reference(), Result :: term()@}}.
%%
%% @see start_compaction/1
%% @see abort_compaction/1

-spec finish_compaction(term(), CompactHandle :: term(), file:filename()) ->
  ok | {error, damaged_file | file:posix()}.

finish_compaction({error, Reason} = _Result, {_Ref, _Pid, Handle}, _LogDir) ->
  statip_flog:close(Handle),
  {error, Reason};

finish_compaction({ok, Records} = _Result, {_Ref, _Pid, Handle}, LogDir) ->
  case statip_flog:replay(Handle, ?READ_BLOCK, ?READ_RETRIES, Records) of
    {ok, AllRecords} ->
      statip_flog:close(Handle),
      dump_logfile(AllRecords, LogDir);
    {error, Reason} ->
      statip_flog:close(Handle),
      {error, Reason}
  end.

%% @doc Abort an already running log compaction process.
%%
%% @see start_compaction/1
%% @see finish_compaction/3

-spec abort_compaction(term()) ->
  ok.

abort_compaction({_Ref, Pid, Handle} = _CompactHandle) ->
  unlink(Pid),
  exit(Pid, shutdown),
  statip_flog:close(Handle),
  ok.

%%%---------------------------------------------------------------------------

%% @doc Detect how {@link init/1} should initialize the logger state.
%%
%%   The startup process differs a little when no file logging will be done,
%%   when events will be recorded to a log file, or when the process recovers
%%   from crash.

-spec logger_start_mode() ->
    {boot, LogDir, CompactionSize}
  | {crash_recovery, LogDir, CompactionSize}
  | no_logging
  when LogDir :: file:filename().

logger_start_mode() ->
  case application:get_env(state_dir) of
    {ok, LogDir} ->
      {ok, CompactionSize} = application:get_env(compaction_size),
      case ets:lookup(?ETS_BOOT_TABLE, booted) of
        [{booted, true}] -> {crash_recovery, LogDir, CompactionSize};
        [] -> {boot, LogDir, CompactionSize}
      end;
    undefined ->
      no_logging
  end.

%% @doc Leave the mark to indicate that booting was already finished, so any
%%   future {@link init/1} call is a crash recovery.
%%
%% @see logger_start_mode/0

-spec set_booted_flag() ->
  ok.

set_booted_flag() ->
  ets:insert(?ETS_BOOT_TABLE, {booted, true}),
  ok.

%%%---------------------------------------------------------------------------
%%% vim:ft=erlang:foldmethod=marker
