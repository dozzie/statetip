%%%---------------------------------------------------------------------------
%%% @doc
%%%   Handler for {@link error_logger} to write events to a text file.
%%% @end
%%%---------------------------------------------------------------------------

-module(statip_disk_h).

-behaviour(gen_event).

%% gen_event callbacks
-export([init/1, terminate/2]).
-export([handle_event/2, handle_call/2, handle_info/2]).
-export([code_change/3]).

-export([format_error/1]).

-export_type([event/0]).

%%%---------------------------------------------------------------------------

-define(MAX_LINE_LENGTH, 16#ffffffff). % 4GB should be enough for a log line

-record(state, {
  filename :: file:filename(),
  handle :: file:io_device()
}).

-type type_message() :: error | warning_msg | info_msg.
-type type_report() :: error_report | warning_report | info_report.

-type report_type() :: std_error | std_warning | std_info | term().
-type report() :: [{Tag :: term(), Data :: term()} | term()]
                  | string() | term().

-type event_message() :: {pid(), Format :: string(), Args :: [term()]}.
-type event_report()  :: {pid(), report_type(), report()}.

-type event() ::
    {type_message(), GroupLeader :: pid(), event_message()}
  | {type_report(), GroupLeader :: pid(), event_report()}.

%%%---------------------------------------------------------------------------
%%% gen_event callbacks
%%%---------------------------------------------------------------------------

%%----------------------------------------------------------
%% initialization/termination {{{

%% @private
%% @doc Initialize event handler.

init([File] = _Args) ->
  case file:open(File, [append, raw, delayed_write]) of
    {ok, Handle} ->
      State = #state{
        filename = File,
        handle = Handle
      },
      {ok, State};
    {error, Reason} ->
      {error, Reason}
  end.

%% @private
%% @doc Clean up after event handler.

terminate(_Arg, _State = #state{handle = Handle}) ->
  file:close(Handle),
  ok.

%% }}}
%%----------------------------------------------------------
%% communication {{{

%% @private
%% @doc Handle {@link gen_event:notify/2}.

handle_event({LogType, _GroupLeader, LogData} = _Event,
             State = #state{handle = Handle}) ->
  case format_event(LogType, LogData) of
    {ok, Line} ->
      % XXX: don't die on write errors (e.g. no space left on device), so the
      % handler can recover without much intervention from (some) errors
      file:write(Handle, [Line, $\n]);
    skip ->
      skip
  end,
  {ok, State};

%% unknown events
handle_event(_Event, State) ->
  {ok, State}.

%% @private
%% @doc Handle {@link gen_event:call/2}.

handle_call(reopen = _Request,
            State = #state{filename = File, handle = Handle}) ->
  file:close(Handle),
  case file:open(File, [append, raw, delayed_write]) of
    {ok, NewHandle} ->
      NewState = State#state{handle = NewHandle},
      {ok, ok, NewState};
    {error, Reason} ->
      % TODO: log this?
      {remove_handler, {error, Reason}}
  end;

%% unknown calls
handle_call(_Request, State) ->
  {ok, {error, unknown_call}, State}.

%% @private
%% @doc Handle incoming messages.

%% unknown messages
handle_info(_Message, State) ->
  {ok, State}.

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
%%% helpers
%%%---------------------------------------------------------------------------

%%----------------------------------------------------------
%% event formatting {{{

%% @doc Format {@link error_logger} event for writing in a log file.

-spec format_event(type_message() | type_report(),
                   event_message() | event_report()) ->
  {ok, iolist()} | skip.

format_event(LogType, LogData) ->
  Timestamp = timestamp(),
  case level_type(LogType) of
    {Level, format = _Type} ->
      case format(LogData) of
        {ok, Pid, Line} ->
          LogPrefix = log_prefix(Timestamp, Level, Pid),
          {ok, [LogPrefix, " ", Line]};
        {error, _Reason} ->
          skip
      end;
    {Level, report = _Type} ->
      case report(LogData) of
        {ok, Pid, Line} ->
          LogPrefix = log_prefix(Timestamp, Level, Pid),
          {ok, [LogPrefix, " ", Line]};
        {error, _Reason} ->
          skip
      end;
    {error, badarg} ->
      skip
  end.

%% @doc Build a prefix for a log line.

-spec log_prefix(integer(), error | warning | info, pid()) ->
  iolist().

log_prefix(Time, Level, Pid) ->
  [integer_to_list(Time), " ", atom_to_list(Level), " ",
    "[", os:getpid(), "] ", pid_to_list(Pid)].

%% @doc Convert a tag to a log level and its type.

-spec level_type(type_message() | type_report()) ->
  {Level, Type} | {error, badarg}
  when Level :: error | warning | info,
       Type :: format | report.

level_type(error)          -> {error, format};
level_type(error_report)   -> {error, report};
level_type(warning_msg)    -> {warning, format};
level_type(warning_report) -> {warning, report};
level_type(info_msg)       -> {info, format};
level_type(info_report)    -> {info, report};
level_type(_) -> {error, badarg}.

%% @doc Fill a format string with data, making it a log line.

-spec format(event_message()) ->
  {ok, pid(), iolist()} | {error, badarg | term()}.

format({Pid, Format, Args} = _LogData) ->
  try
    Line = io_lib:format(Format, Args),
    {ok, Pid, Line}
  catch
    error:Reason ->
      {error, Reason}
  end;
format(_LogData) ->
  {error, badarg}.

%% @doc Format a report, making it a log line.

-spec report(event_report()) ->
  {ok, pid(), iolist()} | {error, badarg}.

report({Pid, Type, Report} = _LogData) ->
  Line = [
    io_lib:print(Type, 1, ?MAX_LINE_LENGTH, -1),
    " ",
    io_lib:print(Report, 1, ?MAX_LINE_LENGTH, -1)
  ],
  {ok, Pid, Line};
report(_LogData) ->
  {error, badarg}.

%% @doc Get a log timestamp.

-spec timestamp() ->
  integer().

timestamp() ->
  {MS, S, _US} = os:timestamp(), % good enough for logging
  MS * 1000 * 1000 + S.

%% }}}
%%----------------------------------------------------------
%% format errors {{{

%% @doc Format an error reported by this module.

-spec format_error(term()) ->
  string().

format_error(Reason) ->
  file:format_error(Reason).

%% }}}
%%----------------------------------------------------------

%%%---------------------------------------------------------------------------
%%% vim:ft=erlang:foldmethod=marker
