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

%% interface for xapp_cli
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

handle_command([{<<"command">>, <<"dist_start">>}] = _Command, _Args) ->
  case indira_app:distributed_start() of
    ok ->
      [{result, ok}];
    {error, _Reason} ->
      % TODO: log this event
      [{result, error}, {message, <<"Erlang networking error">>}]
  end;

handle_command([{<<"command">>, <<"dist_stop">>}] = _Command, _Args) ->
  case indira_app:distributed_stop() of
    ok ->
      [{result, ok}];
    {error, _Reason} ->
      % TODO: log this event
      [{result, error}, {message, <<"Erlang networking error">>}]
  end;

handle_command(_Command, _Args) ->
  [{result, error}, {message, <<"unrecognized command">>}].

%%%---------------------------------------------------------------------------
%%% interface for xapp_cli
%%%---------------------------------------------------------------------------

%% @doc Encode administrative command as a serializable structure.

-spec format_request(gen_indira_cli:command()) ->
  gen_indira_cli:request().

format_request(status        = Command) -> [{command, Command}, {wait, false}];
format_request(status_wait   = Command) -> [{command, Command}, {wait, true}];
format_request(stop          = Command) -> [{command, Command}];
format_request(reload_config = Command) -> [{command, Command}];
format_request(dist_start    = Command) -> [{command, Command}];
format_request(dist_stop     = Command) -> [{command, Command}].

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

%% unrecognized reply
parse_reply(_Reply, _Command) ->
  {error, unrecognized_reply}.

%% @doc Artificial replies for `xapp_cli' when no reply was received.

-spec hardcoded_reply(generic_ok | daemon_stopped) ->
  gen_indira_cli:reply().

hardcoded_reply(daemon_stopped = _Event) -> [{<<"result">>, <<"stopped">>}];
hardcoded_reply(generic_ok     = _Event) -> [{<<"result">>, <<"ok">>}].

%%%---------------------------------------------------------------------------

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

%%%---------------------------------------------------------------------------
%%% vim:ft=erlang:foldmethod=marker
