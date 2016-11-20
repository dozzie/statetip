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
  init:stop(),
  [{result, ok}, {pid, list_to_binary(os:getpid())}];

handle_command([{<<"command">>, <<"reload_config">>}] = _Command, _Args) ->
  [{result, todo}];

handle_command([{<<"command">>, <<"compact_statelog">>}] = _Command, _Args) ->
  [{result, todo}];

handle_command([{<<"command">>, <<"reopen_logs">>}] = _Command, _Args) ->
  case reopen_state_log_file() of
    ok ->
      case reopen_error_logger_file() of
        ok -> [{result, ok}];
        {error, Message} -> [{result, error}, {message, Message}]
      end;
    {error, Message} ->
      [{result, error}, {message, Message}]
  end;

handle_command([{<<"command">>, <<"dist_start">>}] = _Command, _Args) ->
  case indira_app:distributed_start() of
    ok ->
      [{result, ok}];
    {error, Reason} ->
      statip_log:warn(command, "can't setup Erlang networking",
                      [{reason, {term, Reason}}]),
      [{result, error}, {message, <<"Erlang networking error">>}]
  end;

handle_command([{<<"command">>, <<"dist_stop">>}] = _Command, _Args) ->
  case indira_app:distributed_stop() of
    ok ->
      [{result, ok}];
    {error, Reason} ->
      statip_log:warn(command, "can't shutdown Erlang networking",
                      [{reason, {term, Reason}}]),
      [{result, error}, {message, <<"Erlang networking error">>}]
  end;

handle_command([{<<"command">>, <<"list">>}, {<<"query">>, Query}] = _Command,
               _Args) ->
  % [{result, ok}, {names | origins | keys | value, Result}]
  case Query of
    [{}] ->
      [{result, todo}];
    [{<<"name">>, _Name}] ->
      [{result, todo}];
    [{<<"name">>, _Name}, {<<"origin">>, _Origin}] ->
      [{result, todo}];
    [{<<"key">>, _Key}, {<<"name">>, _Name}, {<<"origin">>, _Origin}] ->
      [{result, todo}]
  end;
handle_command([{<<"command">>,<<"delete">>}, {<<"query">>,Query}] = _Command,
               _Args) ->
  case Query of
    [{<<"name">>, _Name}] ->
      [{result, todo}];
    [{<<"name">>, _Name}, {<<"origin">>, _Origin}] ->
      [{result, todo}];
    [{<<"key">>, _Key}, {<<"name">>, _Name}, {<<"origin">>, _Origin}] ->
      [{result, todo}]
  end;

handle_command(_Command, _Args) ->
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
      ok
  end.

-spec reopen_error_logger_file(file:filename()) ->
  ok | {error, bad_logger_module | {open, string()}}.

reopen_error_logger_file(File) ->
  case gen_event:call(error_logger, statip_disk_h, reopen) of
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

%%%---------------------------------------------------------------------------
%%% vim:ft=erlang:foldmethod=marker
