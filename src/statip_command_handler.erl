%%%---------------------------------------------------------------------------
%%% @doc
%%%   Administrative commands handler for Indira.
%%%
%%% @see statip_cli_handler
%%% @end
%%%---------------------------------------------------------------------------

-module(statip_command_handler).

-behaviour(gen_indira_command).

%% gen_indira_command callbacks
-export([handle_command/2]).

%% interface for statip_cli_handler
-export([format_request/1, parse_reply/2, hardcoded_reply/1]).

%%%---------------------------------------------------------------------------
%%% gen_indira_command callbacks
%%%---------------------------------------------------------------------------

%% @private
%% @doc Handle administrative commands sent to the daemon.

handle_command([{<<"command">>, <<"status">>}, {<<"wait">>, false}] = _Command,
               _Args) ->
  case is_started() of
    true  -> [{result, running}];
    false -> [{result, stopped}]
  end;
handle_command([{<<"command">>, <<"status">>}, {<<"wait">>, true}] = _Command,
               _Args) ->
  wait_for_start(),
  [{result, running}];

handle_command([{<<"command">>, <<"stop">>}] = _Command, _Args) ->
  log_info(stop, "stopping StateTip daemon", []),
  init:stop(),
  [{result, ok}, {pid, list_to_binary(os:getpid())}];

handle_command([{<<"command">>, <<"reload_config">>}] = _Command, _Args) ->
  case reload_config() of
    ok ->
      case [{N, format_term(E)} || {N, {error, E}} <- reload_processes()] of
        [] ->
          [{result, ok}];
        Errors ->
          [{result, error}, {errors, Errors}]
      end;
    {error, Message} ->
      [{result, error}, {message, Message}]
  end;

handle_command([{<<"command">>, <<"compact_statelog">>}] = _Command, _Args) ->
  log_info(compact_statelog, "log compaction requested", []),
  case statip_state_log:compact() of
    ok ->
      [{result, ok}];
    {error, already_running} ->
      log_info(compact_statelog, "compaction already started", []),
      [{result, ok}]
  end;

handle_command([{<<"command">>, <<"reopen_logs">>}] = _Command, _Args) ->
  log_info(reopen_logs, "reopening log files", []),
  case reopen_state_log_file() of
    ok ->
      log_info(reopen_logs, "state log reopened", []),
      case reopen_error_logger_file() of
        ok ->
          log_info(reopen_logs, "reopened log for error_logger", []),
          [{result, ok}];
        {error, Message} ->
          log_error(reopen_logs, "error_logger reopen error",
                    [{error, Message}]),
          [{result, error}, {message, Message}]
      end;
    {error, Message} ->
      log_error(reopen_logs, "state log reopen error",
                [{error, Message}]),
      [{result, error}, {message, Message}]
  end;

handle_command([{<<"command">>, <<"dist_start">>}] = _Command, _Args) ->
  log_info(dist_start, "starting Erlang networking", []),
  case indira_app:distributed_start() of
    ok ->
      [{result, ok}];
    {error, Reason} ->
      log_error(dist_start, "can't setup Erlang networking",
                [{error, {term, Reason}}]),
      [{result, error}, {message, <<"Erlang networking error">>}]
  end;

handle_command([{<<"command">>, <<"dist_stop">>}] = _Command, _Args) ->
  log_info(dist_start, "stopping Erlang networking", []),
  case indira_app:distributed_stop() of
    ok ->
      [{result, ok}];
    {error, Reason} ->
      log_error(dist_start, "can't shutdown Erlang networking",
                [{error, {term, Reason}}]),
      [{result, error}, {message, <<"Erlang networking error">>}]
  end;

handle_command([{<<"command">>, <<"list">>}, {<<"query">>, Query}] = _Command,
               _Args) ->
  case Query of
    [{}] ->
      Names = statip_value:list_names(),
      [{result, ok}, {names, Names}];
    [{<<"name">>, Name}] ->
      Origins = [undef_to_null(O) || O <- statip_value:list_origins(Name)],
      [{result, ok}, {origins, Origins}];
    [{<<"name">>, Name}, {<<"origin">>, Origin}] ->
      Keys = statip_value:list_keys(Name, null_to_undef(Origin)),
      [{result, ok}, {keys, Keys}];
    [{<<"key">>, Key}, {<<"name">>, Name}, {<<"origin">>, Origin}] ->
      case statip_value:get_value(Name, null_to_undef(Origin), Key) of
        none ->
          [{result, ok}, {value, null}];
        Value ->
          Result = statip_value:to_struct(Name, null_to_undef(Origin), Value),
          [{result, ok}, {value, Result}]
      end
  end;
handle_command([{<<"command">>,<<"delete">>}, {<<"query">>,Query}] = _Command,
               _Args) ->
  case Query of
    [{<<"name">>, Name}] ->
      statip_value:delete(Name),
      [{result, ok}];
    [{<<"name">>, Name}, {<<"origin">>, Origin}] ->
      statip_value:delete(Name, Origin),
      [{result, ok}];
    [{<<"key">>, Key}, {<<"name">>, Name}, {<<"origin">>, Origin}] ->
      statip_value:delete(Name, Origin, Key),
      [{result, ok}]
  end;

handle_command(Command, _Args) ->
  % `Command' is a structure coming from JSON, so it's safe to log it as it is
  statip_log:warn(unknown_command, "unknown command", [{command, Command}]),
  [{result, error}, {message, <<"unrecognized command">>}].

%%%---------------------------------------------------------------------------
%%% interface for statip_cli_handler
%%%---------------------------------------------------------------------------

%% @doc Encode administrative command as a serializable structure.

-spec format_request(gen_indira_cli:command()) ->
  gen_indira_cli:request().

format_request(status        = Command) -> [{command, Command}, {wait, false}];
format_request(status_wait   = Command) -> [{command, Command}, {wait, true}];
format_request(stop          = Command) -> [{command, Command}];
format_request(reload_config = Command) -> [{command, Command}];
format_request(compact_statelog = Command) -> [{command, Command}];
format_request(reopen_logs   = Command) -> [{command, Command}];
format_request(dist_start    = Command) -> [{command, Command}];
format_request(dist_stop     = Command) -> [{command, Command}];

format_request({list, Args} = _Command) when is_list(Args) ->
  [{command, list}, {<<"query">>, make_query(Args)}];
format_request({delete, Args = [_|_]} = _Command) ->
  [{command, delete}, {<<"query">>, make_query(Args)}].

%%----------------------------------------------------------
%% make_query() {{{

make_query([]) ->
  [{}];
make_query([Name]) ->
  [{name, list_to_binary(Name)}];
make_query([Name, "" = _Origin]) ->
  [{name, list_to_binary(Name)},
    {origin, null}];
make_query([Name, Origin]) ->
  [{name, list_to_binary(Name)},
    {origin, list_to_binary(Origin)}];
make_query([Name, "" = _Origin, Key]) ->
  [{name, list_to_binary(Name)},
    {origin, null},
    {key, list_to_binary(Key)}];
make_query([Name, Origin, Key]) ->
  [{name, list_to_binary(Name)},
    {origin, list_to_binary(Origin)},
    {key, list_to_binary(Key)}].

%% }}}
%%----------------------------------------------------------

%% @doc Decode a reply to an administrative command.

-spec parse_reply(gen_indira_cli:reply(), gen_indira_cli:command()) ->
  term().

%% generic replies
parse_reply([{<<"result">>, <<"ok">>}] = _Reply, _Command) ->
  ok;
parse_reply([{<<"result">>, <<"todo">>}] = _Reply, _Command) ->
  {error, 'TODO'};
parse_reply([{<<"message">>, Message}, {<<"result">>, <<"error">>}] = _Reply,
            _Command) ->
  {error, Message};

parse_reply([{<<"errors">>, Errors}, {<<"result">>, <<"error">>}] = _Reply,
            reload_config = _Command) ->
  {error, Errors};

parse_reply([{<<"pid">>, Pid}, {<<"result">>, <<"ok">>}] = _Reply,
            stop = _Command) ->
  {ok, Pid};

parse_reply([{<<"result">>, <<"running">>}]  = _Reply, status = _Command) ->
  running;
parse_reply([{<<"result">>, <<"stopped">>}]  = _Reply, status = _Command) ->
  stopped;

parse_reply([{<<"names">>, Objects}, {<<"result">>, <<"ok">>}]  = _Reply,
            list = _Command) ->
  {ok, names, Objects};
parse_reply([{<<"origins">>, Objects}, {<<"result">>, <<"ok">>}]  = _Reply,
            list = _Command) ->
  {ok, origins, Objects};
parse_reply([{<<"keys">>, Objects}, {<<"result">>, <<"ok">>}]  = _Reply,
            list = _Command) ->
  {ok, keys, Objects};
parse_reply([{<<"result">>, <<"ok">>}, {<<"value">>, Objects}]  = _Reply,
            list = _Command) ->
  {ok, value, Objects};

%% unrecognized reply
parse_reply(_Reply, _Command) ->
  {error, unrecognized_reply}.

%% @doc Artificial replies for `statip_cli_handler' when no reply was
%%   received.

-spec hardcoded_reply(generic_ok | daemon_stopped) ->
  gen_indira_cli:reply().

hardcoded_reply(daemon_stopped = _Event) -> [{<<"result">>, <<"stopped">>}];
hardcoded_reply(generic_ok     = _Event) -> [{<<"result">>, <<"ok">>}].

%%%---------------------------------------------------------------------------

%%----------------------------------------------------------
%% waiting for/checking daemon's start {{{

wait_for_start() ->
  case is_started() of
    true -> true;
    false -> timer:sleep(100), wait_for_start()
  end.

is_started() ->
  % TODO: replace this with better check (there could be a problem with
  % booting)
  case whereis(statip_sup) of
    Pid when is_pid(Pid) -> true;
    _ -> false
  end.

%% }}}
%%----------------------------------------------------------
%% reopening log files {{{

-spec reopen_state_log_file() ->
  ok | {error, binary()}.

reopen_state_log_file() ->
  case statip_state_log:reopen() of
    ok ->
      ok;
    {error, Reason} ->
      Message = ["can't open state log: ", statip_flog:format_error(Reason)],
      {error, iolist_to_binary(Message)}
  end.

-spec reopen_error_logger_file() ->
  ok | {error, binary()}.

reopen_error_logger_file() ->
  case application:get_env(statip, error_logger_file) of
    {ok, File} ->
      case reopen_error_logger_file(File) of
        ok ->
          ok;
        {error, bad_logger_module} ->
          {error, <<"can't load `statip_disk_h' module">>};
        {error, {open, Reason}} -> % `Reason' is a string
          {error, iolist_to_binary(["can't open ", File, ": ", Reason])}
      end;
    undefined ->
      % it's OK not to find this handler
      gen_event:delete_handler(error_logger, statip_disk_h, []),
      ok
  end.

-spec reopen_error_logger_file(file:filename()) ->
  ok | {error, bad_logger_module | {open, string()}}.

reopen_error_logger_file(File) ->
  case gen_event:call(error_logger, statip_disk_h, {reopen, File}) of
    ok ->
      ok;
    {error, bad_module} ->
      % possibly removed in previous attempt to reopen the log file
      case error_logger:add_report_handler(statip_disk_h, [File]) of
        ok ->
          ok;
        {error, Reason} ->
          {error, {open, statip_disk_h:format_error(Reason)}};
        {'EXIT', _Reason} ->
          % missing module? should not happen
          {error, bad_logger_module}
      end;
    {error, Reason} ->
      {error, {open, statip_disk_h:format_error(Reason)}}
  end.

%% }}}
%%----------------------------------------------------------
%% null <-> undefined conversion {{{

null_to_undef(null) -> undefined;
null_to_undef(Value) -> Value.

undef_to_null(undefined) -> null;
undef_to_null(Value) -> Value.

%% }}}
%%----------------------------------------------------------

%%%---------------------------------------------------------------------------

-spec reload_config() ->
  ok | {error, binary()}.

reload_config() ->
  case application:get_env(statip, configure) of
    {ok, {Module, Function, Args}} ->
      case apply(Module, Function, Args) of
        ok -> ok;
        {error, Message} when is_binary(Message) -> {error, Message};
        % in case some error slipped in in raw form
        {error, Reason} -> {error, format_term(Reason)}
      end;
    undefined ->
      {error, <<"not configured from file">>}
  end.

-spec reload_processes() ->
  [{Part, Result}]
  when Part :: dist_erl | error_logger | logger
             | sender_listen | reader_listen | state_logger,
       Result :: ok | {error, term()}.

reload_processes() ->
  _Results = [
    %{dist_erl, ...}, % already reloaded when config was applied
    {error_logger,  reopen_error_logger_file()},
    {logger,        statip_log:reload()},
    {sender_listen, statip_sender_listen:reload()},
    {reader_listen, statip_reader_listen:reload()},
    {state_logger,  statip_state_log:reload()}
  ].

%%%---------------------------------------------------------------------------

-spec log_info(atom(), statip_log:event_message(), statip_log:event_info()) ->
  ok.

log_info(Command, Message, Context) ->
  statip_log:info(command, Message, Context ++ [{command, {term, Command}}]).

-spec log_error(atom(), statip_log:event_message(), statip_log:event_info()) ->
  ok.

log_error(Command, Message, Context) ->
  statip_log:warn(command, Message, Context ++ [{command, {term, Command}}]).

-spec format_term(any()) ->
  binary().

format_term(Term) when is_binary(Term) ->
  Term;
format_term(Term) ->
  iolist_to_binary(io_lib:print(Term, 1, 16#ffffffff, -1)).

%%%---------------------------------------------------------------------------
%%% vim:ft=erlang:foldmethod=marker
