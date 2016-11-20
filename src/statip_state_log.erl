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
-export([compact/0, reopen/0]).

%% internal interface
-export([compact/4]).

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
  ok | {error, already_running}.

compact() ->
  gen_server:call(?MODULE, compact).

%% @doc Reopen state log file.

-spec reopen() ->
  ok | {error, file:posix()}.

reopen() ->
  gen_server:call(?MODULE, reopen).

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
  statip_log:set_context(state_log, []),
  % TODO: read the values of read block and read retries
  case application:get_env(state_dir) of
    {ok, LogDir} ->
      statip_log:append_context([{log_dir, {str, LogDir}}]),
      case prepare_logfile(LogDir) of
        {ok, Entries} ->
          statip_log:info("starting state logger"),
          ok = dump_logfile(Entries, LogDir), % TODO: error handling
          ok = start_keepers(Entries),
          erlang:send_after(?COMPACT_DECISION_INTERVAL, self(), check_log_size),
          LogFile = filename:join(LogDir, ?LOG_FILE),
          {ok, LogH} = statip_flog:open(LogFile, [write]),
          {ok, CompactionSize} = application:get_env(compaction_size),
          State = #state{
            log_dir = LogDir,
            log_handle = LogH,
            compaction_size = CompactionSize
          },
          {ok, State};
        {error, Reason} ->
          statip_log:err("can't compact log file", [{error, {term, Reason}}]),
          {stop, {replay, Reason}}
      end;
    undefined ->
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
  statip_log:info("compaction request ignored, state log not configured"),
  {reply, ok, State};
handle_call(compact = _Request, _From, State = #state{compaction = {_,_}}) ->
  statip_log:info("compaction already in progress, request ignored"),
  {reply, {error, already_running}, State};
handle_call(compact = _Request, _From, State = #state{log_dir = LogDir}) ->
  statip_log:info("compaction request"),
  {ok, {_Ref, _Handle} = CompactHandle} = start_compaction(LogDir),
  NewState = State#state{compaction = CompactHandle},
  {reply, ok, NewState};

handle_call(reopen = _Request, _From, State = #state{log_dir = undefined}) ->
  % no log to (re)open, ignore the request
  {reply, ok, State};
handle_call(reopen = _Request, _From, State = #state{compaction = {_,_}}) ->
  {reply, ok, State};
handle_call(reopen = _Request, _From, State = #state{log_dir = LogDir}) ->
  case State of
    #state{log_handle = undefined} -> ok;
    #state{log_handle = Handle} -> statip_flog:close(Handle)
  end,
  LogFile = filename:join(LogDir, ?LOG_FILE),
  case statip_flog:open(LogFile, [write]) of
    {ok, NewHandle} ->
      NewState = State#state{log_handle = NewHandle},
      {reply, ok, NewState};
    {error, Reason} ->
      NewState = State#state{log_handle = undefined},
      {reply, {error, Reason}, NewState}
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
      statip_log:info("state log too big, starting compaction"),
      {ok, {_Ref, _Handle} = CompactHandle} = start_compaction(LogDir),
      NewState = State#state{compaction = CompactHandle},
      {noreply, NewState};
    false ->
      {noreply, State}
  end;

handle_info({compaction_finished, Ref, Result} = _Message,
            State = #state{compaction = {Ref, CompactHandle},
                           log_dir = LogDir, log_handle = LogH}) ->
  case finish_compaction(Result, CompactHandle) of
    {ok, Records} ->
      {ok, OldSize} = statip_flog:file_size(LogH),
      ok = dump_logfile(Records, LogDir), % TODO: error handling
      statip_flog:close(LogH),
      % XXX: `dump_logfile()' has just succeeded, so another `open()' should
      % work as well
      LogFile = filename:join(LogDir, ?LOG_FILE),
      {ok, NewLogH} = statip_flog:open(LogFile, [write]),
      {ok, NewSize} = statip_flog:file_size(NewLogH),
      statip_log:info("log compacted", [
        {old_size, OldSize},
        {new_size, NewSize}
      ]),
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
%%% state logger's additional logic

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

%% @doc Prepare log file for writing.
%%
%%   The process differs a little between booting (log gets replayed) and
%%   crash recovery.

-spec prepare_logfile(file:filename()) ->
    {ok, statip_flog:records() | none}
  | {error, bad_file | damaged_file | file:posix()}.

prepare_logfile(LogDir) ->
  case ets:lookup(?ETS_BOOT_TABLE, booted) of
    [] -> % application boot
      {ok, {Ref, Handle}} = start_compaction(LogDir),
      receive
        {compaction_finished, Ref, Result} ->
          ets:insert(?ETS_BOOT_TABLE, {booted, true}),
          case finish_compaction(Result, Handle) of
            {ok, Records}   -> {ok, Records};
            {error, enoent} -> {ok, none};
            {error, Reason} -> {error, Reason}
          end
      end;
    [{booted, true}] -> % crash recovery
      {ok, none}
  end.

%%%---------------------------------------------------------------------------

%% @doc Write a compacted version of the previously read log file.

-spec dump_logfile(statip_flog:records() | none, file:filename()) ->
  ok | {error, file:posix()}.

dump_logfile(none = _Entries, _LogDir) ->
  ok;
dump_logfile(Entries, LogDir) ->
  LogFile = filename:join(LogDir, ?LOG_FILE_COMPACT_TEMP),
  ok = remove_file(LogFile), % TODO: error handling
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
%% remove_file() {{{

%% @doc Ensure the specified file doesn't exist.

-spec remove_file(file:filename()) ->
  ok | {error, file:posix()}.

remove_file(Filename) ->
  case file:delete(Filename) of
    ok -> ok;
    {error, enoent} -> ok;
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
%%%---------------------------------------------------------------------------

%% @doc Log compaction process' main procedure.
%%
%% @see start_compaction/1

-spec compact(file:filename(), pid(), reference(),
              {statip_log:event_type(), statip_log:event_info()}) ->
  any().

compact(LogFile, ResultTo, Ref, {LogType, LogContext}) ->
  statip_log:set_context(LogType, LogContext),
  statip_log:append_context([{log_file, LogFile}]),
  case statip_flog:open(LogFile, [read]) of
    {ok, Handle} ->
      TimeStart = wall_clock(),
      statip_log:info("starting replaying events"),
      case statip_flog:replay(Handle, ?READ_BLOCK, ?READ_RETRIES) of
        {ok, Records} ->
          TimeSync = wall_clock(),
          statip_log:info("synchronizing with logger"),
          ResultTo ! {compaction_finished, Ref, sync},
          receive
            {sync, Ref} ->
              TimeCont = wall_clock(),
              Result = statip_flog:replay(Handle, ?READ_BLOCK, ?READ_RETRIES,
                                          Records),
              case Result of
                {ok, _} ->
                  TimeEnd = wall_clock(),
                  TotalTime = TimeEnd - TimeStart,
                  SyncDelay = TimeCont - TimeSync,
                  statip_log:info("log replay complete", [
                    {compaction_time, TotalTime},
                    {sync_delay, SyncDelay},
                    {time_unit, <<"milliseconds">>}
                  ]);
                {error, Reason} ->
                  statip_log:warn("log replay failed", [
                    {error, {term, Reason}}
                  ])
              end,
              statip_flog:close(Handle),
              ResultTo ! {compaction_finished, Ref, Result}
          end;
        {error, Reason} ->
          statip_flog:close(Handle),
          statip_log:warn("log replay failed", [{error, {term, Reason}}]),
          ResultTo ! {compaction_finished, Ref, {error, Reason}}
      end;
    {error, Reason} ->
      statip_log:warn("can't open log file for replaying", [
        {error, {term, Reason}}
      ]),
      ResultTo ! {compaction_finished, Ref, {error, Reason}}
  end.

%% @doc Start asynchronous process of compacting a log file.
%%
%%   At the end, the calling process receives
%%   {@type @{compaction_finished, Ref :: reference(), Result :: term()@}} and
%%   should call {@link finish_compaction/2}.
%%
%% @see finish_compaction/2
%% @see abort_compaction/1

-spec start_compaction(file:filename()) ->
  {ok, {Ref :: reference(), CompactHandle :: term()}}.

start_compaction(LogDir) ->
  LogFile = filename:join(LogDir, ?LOG_FILE),
  Ref = make_ref(),
  {_,_} = Logger = statip_log:get_context(),
  Pid = spawn_link(?MODULE, compact, [LogFile, self(), Ref, Logger]),
  CompactHandle = {compact, Ref, Pid},
  {ok, {Ref, CompactHandle}}.

%% @doc Finalize the log compaction.
%%
%%   This function should be called upon receiving {@type
%%   @{compaction_finished, _Ref :: reference(), Result :: term()@}}.
%%
%% @see start_compaction/1
%% @see abort_compaction/1

-spec finish_compaction(Result :: term(), CompactHandle :: term()) ->
    {ok, statip_flog:records()}
  | {error, bad_file | damaged_file | file:posix()}.

finish_compaction({error, Reason}, {compact, _Ref, _Pid}) ->
  {error, Reason};
finish_compaction(sync, {compact, Ref, Pid}) ->
  Pid ! {sync, Ref},
  receive
    {compaction_finished, Ref, {ok, Records}} ->
      {ok, Records};
    {compaction_finished, Ref, {error, Reason}} ->
      {error, Reason}
  end.

%% @doc Abort an already running log compaction process.
%%
%% @see start_compaction/1
%% @see finish_compaction/2

-spec abort_compaction(term()) ->
  ok.

abort_compaction({compact, _Ref, Pid} = _CompactHandle) ->
  unlink(Pid),
  exit(Pid, shutdown),
  ok.

%% @doc Read wall clock time, in milliseconds.
%%
%%   This function is intended for calculating how much time it took to
%%   compact the state log. It takes into an account possible clock wrap
%%   on 32-bit machines.
%%
%%   The function should never be used in processes with life span counted in
%%   days.

-spec wall_clock() ->
  non_neg_integer().

wall_clock() ->
  {TotalTime, _SinceLastCall} = erlang:statistics(wall_clock),
  % XXX: using process dictionary (especially this way) is cheating, but this
  % function will only be used by relatively short-lived compaction process,
  % which certainly shouldn't take *days* to complete
  case get('$wall_clock') of
    undefined ->
      put('$wall_clock', {TotalTime, 0}),
      TotalTime;
    {OldTime, Correction} when TotalTime >= OldTime ->
      put('$wall_clock', {TotalTime, Correction}),
      TotalTime + Correction;
    {OldTime, Correction} when TotalTime < OldTime ->
      % wall clock is a number of milliseconds stored as an integer of
      % machine's native size, so on 32-bit machine, it wraps every 49.7 days
      put('$wall_clock', {TotalTime, Correction + (1 bsl 32)}),
      TotalTime + Correction + (1 bsl 32)
  end.

%%%---------------------------------------------------------------------------
%%% vim:ft=erlang:foldmethod=marker
