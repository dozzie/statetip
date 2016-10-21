%%%---------------------------------------------------------------------------
%%% @doc
%%%   Module that handles command line operations.
%%%   This includes parsing provided arguments and either starting the daemon
%%%   or sending it various administrative commands.
%%%
%%% @see statip_command_handler
%%% @end
%%%---------------------------------------------------------------------------

-module(statip_cli_handler).

-behaviour(gen_indira_cli).

%% interface for daemonizing script
-export([format_error/1]).
-export([help/1]).

%% gen_indira_cli callbacks
-export([parse_arguments/2]).
-export([handle_command/2, format_request/2, handle_reply/3]).

%%%---------------------------------------------------------------------------
%%% types {{{

-define(APPLICATION, statip).
-define(ADMIN_COMMAND_MODULE, statip_command_handler).
% XXX: `status' and `stop' commands are bound to few specific errors this
% module returns; this can't be easily moved to a config/option
-define(ADMIN_SOCKET_TYPE, indira_unix).

-type config_value() :: binary() | number() | boolean().
-type config_key() :: binary().
-type config() :: [{config_key(), config_value() | config()}].

-record(opts, {
  op :: start | status | stop | reload_config | reopen_logs
      | dist_start | dist_stop,
  admin_socket :: file:filename(),
  options :: [{atom(), term()}]
}).

%%% }}}
%%%---------------------------------------------------------------------------
%%% gen_indira_cli callbacks
%%%---------------------------------------------------------------------------

%%----------------------------------------------------------
%% parse_arguments() {{{

%% @private
%% @doc Parse command line arguments and decode opeartion from them.

parse_arguments(Args, [DefAdminSocket, DefConfig] = _Defaults) ->
  EmptyOptions = #opts{
    admin_socket = DefAdminSocket,
    options = [
      {config, DefConfig}
    ]
  },
  case indira_cli:folds(fun cli_opt/2, EmptyOptions, Args) of
    {ok, Options = #opts{op = start }} -> {ok, start,  Options};
    {ok, Options = #opts{op = status}} -> {ok, status, Options};
    {ok, Options = #opts{op = stop  }} -> {ok, stop,   Options};

    {ok, _Options = #opts{op = undefined}} ->
      help;

    {ok, Options = #opts{op = Command, admin_socket = AdminSocket}} ->
      {send, {?ADMIN_SOCKET_TYPE, AdminSocket}, Command, Options};

    {error, {help, _Arg}} ->
      help;

    {error, {Reason, Arg}} ->
      {error, {Reason, Arg}}
  end.

%% }}}
%%----------------------------------------------------------
%% handle_command() {{{

%% @private
%% @doc Execute commands more complex than "request -> reply -> print".

handle_command(start = _Command,
               Options = #opts{admin_socket = Socket, options = CLIOpts}) ->
  ConfigFile = proplists:get_value(config, CLIOpts),
  case read_config_file(ConfigFile) of
    {ok, Config} ->
      case setup_applications(Config, Options) of
        {ok, IndiraOptions} ->
          indira_app:daemonize(?APPLICATION, [
            {listen, [{?ADMIN_SOCKET_TYPE, Socket}]},
            {command, {?ADMIN_COMMAND_MODULE, []}} |
            IndiraOptions
          ]);
        {error, Reason} ->
          {error, {configure, Reason}}
      end;
    {error, Reason} ->
      {error, {config_read, Reason}}
  end;

handle_command(status = Command,
               Options = #opts{admin_socket = Socket, options = CLIOpts}) ->
  Timeout = proplists:get_value(timeout, CLIOpts, infinity),
  Opts = case proplists:get_bool(wait, CLIOpts) of
    true  = Wait -> [{timeout, Timeout}, retry];
    false = Wait -> [{timeout, Timeout}]
  end,
  {ok, Request} = format_request(Command, Options),
  case indira_cli:send_one_command(?ADMIN_SOCKET_TYPE, Socket, Request, Opts) of
    {ok, Reply} ->
      handle_reply(Reply, Command, Options);
    {error, timeout} when Wait ->
      % FIXME: what to do when a command got sent, but no reply was received?
      Reply = ?ADMIN_COMMAND_MODULE:hardcoded_reply(daemon_stopped),
      handle_reply(Reply, Command, Options);
    {error, econnrefused} -> % NOTE: specific to `indira_unix' sockets
      Reply = ?ADMIN_COMMAND_MODULE:hardcoded_reply(daemon_stopped),
      handle_reply(Reply, Command, Options);
    {error, enoent} -> % NOTE: specific to `indira_unix' sockets
      Reply = ?ADMIN_COMMAND_MODULE:hardcoded_reply(daemon_stopped),
      handle_reply(Reply, Command, Options);
    {error, Reason} ->
      {error, {send, Reason}} % mimic what `indira_cli:execute()' returns
  end;

handle_command(stop = Command,
               Options = #opts{admin_socket = Socket, options = CLIOpts}) ->
  Timeout = proplists:get_value(timeout, CLIOpts, infinity),
  Opts = [{timeout, Timeout}],
  {ok, Request} = format_request(Command, Options),
  case indira_cli:send_one_command(?ADMIN_SOCKET_TYPE, Socket, Request, Opts) of
    {ok, Reply} ->
      handle_reply(Reply, Command, Options);
    {error, closed} ->
      % AF_UNIX socket exists, but nothing listens there (stale socket)
      Reply = ?ADMIN_COMMAND_MODULE:hardcoded_reply(generic_ok),
      handle_reply(Reply, Command, Options);
    {error, econnrefused} -> % NOTE: specific to `indira_unix' sockets
      Reply = ?ADMIN_COMMAND_MODULE:hardcoded_reply(generic_ok),
      handle_reply(Reply, Command, Options);
    {error, enoent} -> % NOTE: specific to `indira_unix' sockets
      Reply = ?ADMIN_COMMAND_MODULE:hardcoded_reply(generic_ok),
      handle_reply(Reply, Command, Options);
    {error, Reason} ->
      {error, {send, Reason}} % mimic what `indira_cli:execute()' returns
  end.

%% }}}
%%----------------------------------------------------------
%% format_request() + handle_reply() {{{

%% @private
%% @doc Format a request to send to daemon.

format_request(status = _Command, _Options = #opts{options = CLIOpts}) ->
  Request = case proplists:get_bool(wait, CLIOpts) of
    true  -> ?ADMIN_COMMAND_MODULE:format_request(status_wait);
    false -> ?ADMIN_COMMAND_MODULE:format_request(status)
  end,
  {ok, Request};
format_request(Command, _Options) ->
  Request = ?ADMIN_COMMAND_MODULE:format_request(Command),
  {ok, Request}.

%% @private
%% @doc Handle a reply to a command sent to daemon.

handle_reply(Reply, status = Command, _Options) ->
  % `status' and `status_wait' have the same `Command' and replies
  case ?ADMIN_COMMAND_MODULE:parse_reply(Reply, Command) of
    {ok, <<"running">> = _Status} ->
      io:fwrite("statetipd is running~n"),
      ok;
    {ok, <<"stopped">> = _Status} ->
      io:fwrite("statetipd is stopped~n"),
      {error, 1};
    % for future changes in status detection
    {ok, Status} ->
      {error, {unknown_status, Status}}
  end;

handle_reply(Reply, stop = Command, _Options = #opts{options = CLIOpts}) ->
  PrintPid = proplists:get_bool(print_pid, CLIOpts),
  case ?ADMIN_COMMAND_MODULE:parse_reply(Reply, Command) of
    {ok, Pid} when PrintPid -> io:fwrite("~s~n", [Pid]), ok;
    {ok, _Pid} when not PrintPid -> ok;
    ok -> ok;
    {error, Reason} -> {error, Reason}
  end;

handle_reply(Reply, Command, _Options) ->
  ?ADMIN_COMMAND_MODULE:parse_reply(Reply, Command).

%% }}}
%%----------------------------------------------------------

%%%---------------------------------------------------------------------------
%%% interface for daemonizing script
%%%---------------------------------------------------------------------------

%% @doc Convert an error to a printable form.

-spec format_error(term()) ->
  iolist().

%% command line parsing
format_error({bad_command, Command} = _Reason) ->
  ["invalid command: ", Command];
format_error({bad_option, Option} = _Reason) ->
  ["invalid option: ", Option];
format_error({bad_timeout, _Value} = _Reason) ->
  "invalid timeout value";

%% config file handling (`start')
format_error({config_read, Error} = _Reason) ->
  io_lib:format("error while reading config file: ~1024p", [Error]);
format_error({config_format, Error} = _Reason) ->
  io_lib:format("config file parsing error: ~1024p", [Error]);
format_error({configure, {[Section, Option] = _Key, _Env, _Error}} = _Reason) ->
  % `Error' is what `config_check()' returned, `Key' is which key was it;
  % see `configure_statip()' for used keys
  io_lib:format("invalid config option: ~s.~s", [Section, Option]);
format_error({configure, {app_load, Error}} = _Reason) ->
  io_lib:format("application loading error: ~1024p", [Error]);
format_error({configure, bad_config} = _Reason) ->
  % TODO: be more precise
  "invalid [erlang] section in config";
format_error({configure, {log_file, Error}} = _Reason) ->
  ["error opening log file: ", file:format_error(Error)];
format_error({configure, bad_logger_module} = _Reason) ->
  "can't load `statip_disk_h' module";

%% TODO: `indira_app:daemonize()' errors

%% request sending errors
format_error({send, bad_request_format} = _Reason) ->
  "unserializable request format";
format_error({send, bad_reply_format} = _Reason) ->
  "invalid reply format";
format_error({send, timeout} = _Reason) ->
  "operation timed out";
format_error({send, Error} = _Reason) ->
  io_lib:format("request sending error: ~1024p", [Error]);

format_error(unrecognized_reply = _Reason) ->
  "unrecognized daemon's reply";
format_error('TODO' = _Reason) ->
  "operation not implemented yet (daemon side)";
format_error(Reason) when is_binary(Reason) ->
  Reason;
format_error(Reason) ->
  io_lib:format("unknown error: ~1024p", [Reason]).

%% @doc Return a printable help message.

-spec help(string()) ->
  iolist().

help(ScriptName) ->
  _Usage = [
    "StateTip daemon.\n",
    "Controlling daemon:\n",
    "  ", ScriptName, " [--socket <path>] start [--debug] [--config <path>] [--pidfile <path>]\n",
    "  ", ScriptName, " [--socket <path>] status [--wait [--timeout <seconds>]]\n",
    "  ", ScriptName, " [--socket <path>] stop [--timeout <seconds>] [--print-pid]\n",
    "  ", ScriptName, " [--socket <path>] reload-config\n",
    "  ", ScriptName, " [--socket <path>] reopen-logs\n",
    "Distributed Erlang support:\n",
    "  ", ScriptName, " [--socket <path>] dist-erl-start\n",
    "  ", ScriptName, " [--socket <path>] dist-erl-stop\n",
    ""
  ].

%%%---------------------------------------------------------------------------
%%% config file related helpers
%%%---------------------------------------------------------------------------

%% @doc Load configuration from TOML file.

-spec read_config_file(file:filename()) ->
  {ok, config()} | {error, {config_format | config_read, term()}}.

read_config_file(ConfigFile) ->
  case file:read_file(ConfigFile) of
    {ok, Content} ->
      case etoml:parse(Content) of
        {ok, Config} -> {ok, Config};
        {error, Reason} -> {error, {config_format, Reason}}
      end;
    {error, Reason} ->
      {error, {config_read, Reason}}
  end.

%% @doc Configure environment (Erlang, Indira, main app) from loaded config.
%%
%% @todo Configure logging.

-spec setup_applications(config(), #opts{}) ->
  ok | {error, term()}.

setup_applications(Config, Options) ->
  case configure_statip(Config, Options) of
    ok ->
      case setup_logging(Config, Options) of
        ok -> prepare_indira_options(Config, Options);
        {error, Reason} -> {error, Reason}
      end;
    {error, Reason} ->
      {error, Reason}
  end.

%%----------------------------------------------------------
%% configure_statip() {{{

%% @doc Configure the main application.

-spec configure_statip(config(), #opts{}) ->
  ok | {error, term()}.

configure_statip(GlobalConfig, _Options) ->
  SetSpecs = [
    {[<<"events">>, <<"listen">>], {statip, input}},
    {[<<"http">>,   <<"listen">>], {statip, http}},
    {[<<"store">>,  <<"directory">>], {statip, state_dir}},
    {[<<"events">>, <<"default_expiry">>], {statip, default_expiry}}
  ],
  indira_app:set_env(
    fun config_get/2,
    fun config_check/3,
    GlobalConfig,
    SetSpecs
  ).

%% @doc Extract specific value from proplist loaded from config file.
%%
%% @see indira_app:set_env/4

config_get([S, K] = _Key, Config) when is_binary(S), is_binary(K) ->
  case proplists:get_value(S, Config) of
    Section when is_list(Section) -> proplists:get_value(K, Section);
    _ -> undefined
  end.

%% @doc Validate values loaded from config file.
%%
%% @see indira_app:set_env/4

config_check(_Key, _EnvKey, undefined = _Value) ->
  ignore;
config_check([_Section, <<"listen">>] = _Key, _EnvKey, Value) ->
  try
    {ok, parse_listen_spec(Value)}
  catch
    error:_ -> {error, invalid_value}
  end;
config_check([<<"store">>, <<"directory">>] = _Key, _EnvKey, Value)
when is_binary(Value) ->
  ok;
config_check([<<"events">>, <<"default_expiry">>] = _Key, _EnvKey, Value)
when is_integer(Value), Value > 0 ->
  ok;
config_check(_Key, _EnvKey, _Value) ->
  {error, invalid_value}.

%% @doc Parse a listen address to a tuple suitable for HTTP or TCP listeners.
%%
%% @see config_check/3

parse_listen_spec(Spec) ->
  case binary:split(Spec, <<":">>) of
    [<<"*">>, Port] ->
      {any, list_to_integer(binary_to_list(Port))};
    [Host, Port] ->
      {binary_to_list(Host), list_to_integer(binary_to_list(Port))}
  end.

%% }}}
%%----------------------------------------------------------
%% setup_logging() {{{

setup_logging(Config, _Options = #opts{options = CLIOpts}) ->
  case proplists:get_bool(debug, CLIOpts) of
    true -> ok = application:start(sasl);
    false -> ok
  end,
  ErlangConfig = proplists:get_value(<<"erlang">>, Config, []),
  case proplists:get_value(<<"log_file">>, ErlangConfig) of
    File when is_binary(File) ->
      % XXX: see also `statip_command_handler:handle_command()'
      ok = indira_app:set_option(statip, error_logger_file, File),
      case error_logger:add_report_handler(statip_disk_h, [File]) of
        ok -> ok;
        {error, Reason} -> {error, {log_file, Reason}};
        {'EXIT', _Reason} -> {error, bad_logger_module}
      end;
    undefined ->
      ok;
    _ ->
      {error, bad_config}
  end.

%% }}}
%%----------------------------------------------------------
%% prepare_indira_options() {{{

%% @doc Prepare options for {@link indira_app:daemonize/2} from loaded config.

-spec prepare_indira_options(config(), #opts{}) ->
  {ok, [indira_app:daemon_option()]} | {error, term()}.

prepare_indira_options(GlobalConfig, _Options = #opts{options = CLIOpts}) ->
  % XXX: keep the code under `try..catch' simple, without calling complex
  % functions, otherwise a bug in such a complex function will be reported as
  % a config file error
  try
    ErlangConfig = proplists:get_value(<<"erlang">>, GlobalConfig, []),
    PidFile = proplists:get_value(pidfile, CLIOpts),
    % PidFile is already a string or undefined
    NodeName = proplists:get_value(<<"node_name">>, ErlangConfig),
    true = (is_binary(NodeName) orelse NodeName == undefined),
    NameType = proplists:get_value(<<"name_type">>, ErlangConfig),
    true = (NameType == undefined orelse
            NameType == <<"longnames">> orelse NameType == <<"shortnames">>),
    Cookie = case proplists:get_value(<<"cookie_file">>, ErlangConfig) of
      CookieFile when is_binary(CookieFile) -> {file, CookieFile};
      undefined -> none
    end,
    NetStart = proplists:get_bool(<<"distributed_immediate">>, ErlangConfig),
    true = is_boolean(NetStart),
    IndiraOptions = [
      {pidfile, PidFile},
      {node_name, ensure_atom(NodeName)},
      {name_type, ensure_atom(NameType)},
      {cookie, Cookie},
      {net_start, NetStart}
    ],
    {ok, IndiraOptions}
  catch
    error:_ ->
      {error, bad_config}
  end.

%% @doc Ensure a value is an atom.

-spec ensure_atom(binary() | atom()) ->
  atom().

ensure_atom(Value) when is_atom(Value) -> Value;
ensure_atom(Value) when is_binary(Value) -> binary_to_atom(Value, utf8).

%% }}}
%%----------------------------------------------------------

%%%---------------------------------------------------------------------------
%%% various helpers
%%%---------------------------------------------------------------------------

%%----------------------------------------------------------
%% parsing command line arguments {{{

%% @doc Command line argument parser for {@link indira_cli:folds/3}.

cli_opt("-h" = _Arg, _Opts) ->
  {error, help};
cli_opt("--help" = _Arg, _Opts) ->
  {error, help};

cli_opt("--socket=" ++ Socket = _Arg, Opts) ->
  cli_opt(["--socket", Socket], Opts);
cli_opt("--socket" = _Arg, _Opts) ->
  {need, 1};
cli_opt(["--socket", Socket] = _Arg, Opts) ->
  _NewOpts = Opts#opts{admin_socket = Socket};

cli_opt("--pidfile=" ++ PidFile = _Arg, Opts) ->
  cli_opt(["--pidfile", PidFile], Opts);
cli_opt("--pidfile" = _Arg, _Opts) ->
  {need, 1};
cli_opt(["--pidfile", PidFile] = _Arg, Opts = #opts{options = Options}) ->
  _NewOpts = Opts#opts{options = [{pidfile, PidFile} | Options]};

cli_opt("--config=" ++ Config = _Arg, Opts) ->
  cli_opt(["--config", Config], Opts);
cli_opt("--config" = _Arg, _Opts) ->
  {need, 1};
cli_opt(["--config", ConfigFile] = _Arg, Opts = #opts{options = Options}) ->
  _NewOpts = Opts#opts{options = [{config, ConfigFile} | Options]};

cli_opt("--timeout=" ++ Timeout = _Arg, Opts) ->
  cli_opt(["--timeout", Timeout], Opts);
cli_opt("--timeout" = _Arg, _Opts) ->
  {need, 1};
cli_opt(["--timeout", Timeout] = _Arg, Opts = #opts{options = Options}) ->
  try
    Seconds = list_to_integer(Timeout),
    true = (Seconds > 0),
    % NOTE: we need timeout in milliseconds
    _NewOpts = Opts#opts{options = [{timeout, Seconds * 1000} | Options]}
  catch
    _:_ ->
      {error, bad_timeout}
  end;

cli_opt("--debug" = _Arg, Opts = #opts{options = Options}) ->
  _NewOpts = Opts#opts{options = [{debug, true} | Options]};

cli_opt("--wait" = _Arg, Opts = #opts{options = Options}) ->
  _NewOpts = Opts#opts{options = [{wait, true} | Options]};

cli_opt("--print-pid" = _Arg, Opts = #opts{options = Options}) ->
  _NewOpts = Opts#opts{options = [{print_pid, true} | Options]};

cli_opt("-" ++ _ = _Arg, _Opts) ->
  {error, bad_option};

cli_opt(Arg, Opts = #opts{op = undefined}) ->
  case Arg of
    "start"  -> Opts#opts{op = start};
    "status" -> Opts#opts{op = status};
    "stop"   -> Opts#opts{op = stop};
    "reload-config"  -> Opts#opts{op = reload_config};
    "reopen-logs"    -> Opts#opts{op = reopen_logs};
    "dist-erl-start" -> Opts#opts{op = dist_start};
    "dist-erl-stop"  -> Opts#opts{op = dist_stop};
    _ -> {error, bad_command}
  end.

%% }}}
%%----------------------------------------------------------

%%%---------------------------------------------------------------------------
%%% vim:ft=erlang:foldmethod=marker
