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

-export([load_app_config/2]).

%% gen_indira_cli callbacks
-export([parse_arguments/2]).
-export([handle_command/2, format_request/2, handle_reply/3]).

%%%---------------------------------------------------------------------------
%%% types {{{

-define(ADMIN_COMMAND_MODULE, statip_command_handler).
% XXX: `status' and `stop' commands are bound to few specific errors this
% module returns; this can't be easily moved to a config/option
-define(ADMIN_SOCKET_TYPE, indira_unix).

-define(EXIT_FORMAT, 1).
-define(EXIT_READ,   2).
-define(EXIT_WRITE,  3).

-type config_value() :: binary() | number() | boolean().
-type config_key() :: binary().
-type config() :: [{config_key(), config_value() | config()}].

-record(opts, {
  op :: start | status | stop | reload_config
      | compact_statelog | reopen_logs
      | dist_start | dist_stop
      | list | delete
      | log_dump | log_replay | log_restore | log_compact,
  admin_socket :: file:filename(),
  options :: [{atom(), term()}],
  args :: [string()]
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
    args = [],
    options = [
      {config, DefConfig},
      {read_block, 4096}, % the same as in `statip_state_log' module
      {read_tries, 3}     % the same as in `statip_state_log' module
    ]
  },
  case indira_cli:folds(fun cli_opt/2, EmptyOptions, Args) of
    {ok, Options = #opts{op = start }} -> {ok, start,  Options};
    {ok, Options = #opts{op = status}} -> {ok, status, Options};
    {ok, Options = #opts{op = stop  }} -> {ok, stop,   Options};

    {ok, _Options = #opts{op = undefined}} ->
      help;

    {ok, _Options = #opts{op = list, args = [_,_,_,_|_]}} ->
      {error, too_many_args};
    {ok, _Options = #opts{op = delete, args = []}} ->
      {error, too_little_args};
    {ok, _Options = #opts{op = delete, args = [_,_,_,_|_]}} ->
      {error, too_many_args};

    {ok, Options = #opts{op = log_dump, args = OpArgs}} ->
      case OpArgs of
        [_]     -> {ok, log_dump, Options};
        [_,_|_] -> {error, too_many_args};
        _       -> {error, too_little_args}
      end;
    {ok, Options = #opts{op = log_replay, args = OpArgs}} ->
      case OpArgs of
        [_]     -> {ok, log_replay, Options};
        [_,_|_] -> {error, too_many_args};
        _       -> {error, too_little_args}
      end;
    {ok, Options = #opts{op = log_restore, args = OpArgs}} ->
      case OpArgs of
        [_,_]     -> {ok, log_restore, Options};
        [_,_,_|_] -> {error, too_many_args};
        _         -> {error, too_little_args}
      end;
    {ok, Options = #opts{op = log_compact, args = OpArgs}} ->
      case OpArgs of
        [_]     -> {ok, log_compact, Options};
        [_,_|_] -> {error, too_many_args};
        _       -> {error, too_little_args}
      end;

    {ok, _Options = #opts{op = Command, args = [_|_]}}
    when Command /= list, Command /= delete ->
      {error, too_many_args};

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
      indira_app:set_option(statip, configure,
                            {?MODULE, load_app_config, [ConfigFile, Options]}),
      case setup_applications(Config, Options) of
        {ok, IndiraOptions} ->
          indira_app:daemonize(statip, [
            {listen, [{?ADMIN_SOCKET_TYPE, Socket}]},
            {command, {?ADMIN_COMMAND_MODULE, []}} |
            IndiraOptions
          ]);
        {error, Reason} ->
          {error, {configure, Reason}}
      end;
    {error, Reason} ->
      % Reason :: {config_format | config_read, term()}
      {error, Reason}
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
  end;

handle_command(log_dump = _Command,
               _Options = #opts{options = CLIOpts, args = [LogFile]}) ->
  % in older Erlang releases $ERL_CRASH_DUMP_SECONDS set to 0 doesn't disable
  % writing crash dump
  os:putenv("ERL_CRASH_DUMP_SECONDS", "0"),
  os:putenv("ERL_CRASH_DUMP", "/dev/null"),
  ReadBlock = proplists:get_value(read_block, CLIOpts),
  ReadTries = proplists:get_value(read_tries, CLIOpts),
  case statip_flog:open(LogFile, [read]) of
    {ok, Handle} ->
      % ok | {error, ExitCode}
      Result = log_dump(Handle, ReadBlock, ReadTries),
      statip_flog:close(Handle),
      Result;
    {error, Reason} -> % `Reason' is an atom
      printerr("can't open log file for reading", [{reason, Reason}]),
      {error, ?EXIT_READ}
  end;

handle_command(log_replay = _Command,
               _Options = #opts{options = CLIOpts, args = [LogFile]}) ->
  % in older Erlang releases $ERL_CRASH_DUMP_SECONDS set to 0 doesn't disable
  % writing crash dump
  os:putenv("ERL_CRASH_DUMP_SECONDS", "0"),
  os:putenv("ERL_CRASH_DUMP", "/dev/null"),
  ReadBlock = proplists:get_value(read_block, CLIOpts),
  ReadTries = proplists:get_value(read_tries, CLIOpts),
  case statip_flog:open(LogFile, [read]) of
    {ok, Handle} ->
      % ok | {error, ExitCode}
      Result = log_replay(Handle, ReadBlock, ReadTries),
      statip_flog:close(Handle),
      Result;
    {error, Reason} -> % `Reason' is an atom
      printerr("can't open log file for reading", [{reason, Reason}]),
      {error, ?EXIT_READ}
  end;

handle_command(log_restore = _Command,
               _Options = #opts{args = [LogFile, DumpFile]}) ->
  case file:open(DumpFile, [read, raw]) of
    {ok, ReadHandle} ->
      case statip_flog:open(LogFile, [write, truncate]) of
        {ok, WriteHandle} ->
          % ok | {error, ExitCode}
          Result = log_restore(ReadHandle, WriteHandle),
          file:close(ReadHandle),
          statip_flog:close(WriteHandle),
          Result;
        {error, Reason} -> % `Reason' is an atom
          printerr("can't open log file for writing", [{reason, Reason}]),
          file:close(ReadHandle),
          {error, ?EXIT_WRITE}
      end;
    {error, Reason} -> % `Reason' is an atom
      printerr("can't open dump file for reading", [{reason, Reason}]),
      {error, ?EXIT_READ}
  end;

handle_command(log_compact = _Command,
               _Options = #opts{options = CLIOpts, args = [LogFile]}) ->
  ReadBlock = proplists:get_value(read_block, CLIOpts),
  ReadTries = proplists:get_value(read_tries, CLIOpts),
  case statip_flog:open(LogFile, [read]) of
    {ok, ReadHandle} ->
      case replay(ReadHandle, ReadBlock, ReadTries) of
        {ok, Records} ->
          statip_flog:close(ReadHandle),
          % ok | {error, ExitCode}
          log_write_back(LogFile, Records);
        {error, ExitCode} ->
          statip_flog:close(ReadHandle),
          {error, ExitCode}
      end;
    {error, Reason} -> % `Reason' is an atom
      printerr("can't open log file for reading", [{reason, Reason}]),
      {error, ?EXIT_READ}
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
format_request(list = _Command, _Options = #opts{args = Args}) ->
  Request = ?ADMIN_COMMAND_MODULE:format_request({list, Args}),
  {ok, Request};
format_request(delete = _Command, _Options = #opts{args = Args}) ->
  Request = ?ADMIN_COMMAND_MODULE:format_request({delete, Args}),
  {ok, Request};
format_request(Command, _Options) ->
  Request = ?ADMIN_COMMAND_MODULE:format_request(Command),
  {ok, Request}.

%% @private
%% @doc Handle a reply to a command sent to daemon.

handle_reply(Reply, status = Command, _Options) ->
  % `status' and `status_wait' have the same `Command' and replies
  case ?ADMIN_COMMAND_MODULE:parse_reply(Reply, Command) of
    running ->
      println("statetipd is running"),
      ok;
    stopped ->
      println("statetipd is stopped"),
      {error, 1};
    % for future changes in status detection
    Status ->
      {error, {unknown_status, Status}}
  end;

handle_reply(Reply, stop = Command, _Options = #opts{options = CLIOpts}) ->
  PrintPid = proplists:get_bool(print_pid, CLIOpts),
  case ?ADMIN_COMMAND_MODULE:parse_reply(Reply, Command) of
    {ok, Pid} when PrintPid -> println(Pid), ok;
    {ok, _Pid} when not PrintPid -> ok;
    ok -> ok;
    {error, Reason} -> {error, Reason}
  end;

handle_reply(Reply, reload_config = Command, _Options) ->
  case ?ADMIN_COMMAND_MODULE:parse_reply(Reply, Command) of
    ok ->
      ok;
    {error, Message} when is_binary(Message) ->
      printerr(["reload error: ", Message]),
      {error, 1};
    {error, Errors} when is_list(Errors) ->
      printerr("reload errors:"),
      lists:foreach(
        fun({Part, Error}) -> printerr(["  ", Part, ": ", Error]) end,
        Errors
      ),
      {error, 1}
  end;

handle_reply(Reply, list = Command, _Options) ->
  case ?ADMIN_COMMAND_MODULE:parse_reply(Reply, Command) of
    {ok, names, Names} ->
      lists:foreach(fun println/1, Names),
      ok;
    {ok, origins, Origins} ->
      lists:foreach(fun (null) -> println("<null>"); (O) -> println(O) end,
                    Origins),
      ok;
    {ok, keys, Keys} ->
      lists:foreach(fun println/1, Keys),
      ok;
    {ok, value, null} ->
      ok;
    {ok, value, ValueStruct} ->
      {ok, JSON} = statip_json:encode(ValueStruct),
      println(JSON),
      ok;
    {error, Reason} ->
      {error, Reason}
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
  iolist() | binary().

%% command line parsing
format_error({bad_command, Command} = _Reason) ->
  ["invalid command: ", Command];
format_error({bad_option, Option} = _Reason) ->
  ["invalid option: ", Option];
format_error({bad_timeout, _Value} = _Reason) ->
  "invalid timeout value";
format_error({bad_read_block, _Value} = _Reason) ->
  "invalid read block size";
format_error({bad_read_tries, _Value} = _Reason) ->
  "invalid read tries number";
format_error({not_enough_args, Option} = _Reason) ->
  ["missing argument for option ", Option];
format_error(too_many_args = _Reason) ->
  "too many arguments for this operation";
format_error(too_little_args = _Reason) ->
  "too little arguments for this operation";

%% config file handling (`start')
format_error({config_read, Error} = _Reason) ->
  ["error while reading config file: ", file:format_error(Error)];
format_error({config_format, Error} = _Reason) ->
  ["config file parsing error: ", format_etoml_error(Error)];
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
  ["error opening log file: ", indira_disk_h:format_error(Error)];

%% TODO: `indira_app:daemonize()' errors

%% request sending errors
format_error({send, bad_request_format} = _Reason) ->
  "invalid request format (programmer's error)";
format_error({send, bad_reply_format} = _Reason) ->
  "invalid reply format (daemon's error)";
format_error({send, timeout} = _Reason) ->
  "operation timed out";
format_error({send, Error} = _Reason) ->
  io_lib:format("request sending error: ~1024p", [Error]);

format_error('TODO' = _Reason) ->
  "operation not implemented yet (daemon side)";

format_error(unrecognized_reply = _Reason) ->
  "unrecognized daemon's reply";
format_error({bad_return_value, Value} = _Reason) ->
  io_lib:format("invalid return value from callback: ~1024p", [Value]);

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
    "  ", ScriptName, " [--socket <path>] reload\n",
    "  ", ScriptName, " [--socket <path>] compact\n",
    "  ", ScriptName, " [--socket <path>] reopen-logs\n",
    "Distributed Erlang support:\n",
    "  ", ScriptName, " [--socket <path>] dist-erl-start\n",
    "  ", ScriptName, " [--socket <path>] dist-erl-stop\n",
    "Data management:\n",
    "  ", ScriptName, " [--socket <path>] list [<name> [<origin> [<key>]]]\n",
    "  ", ScriptName, " [--socket <path>] delete <name> [<origin> [<key>]]\n",
    "Log file management:\n",
    "  ", ScriptName, " log-dump <logfile> [--read-block <bytes>] [--read-tries <count>]\n",
    "  ", ScriptName, " log-replay <logfile> [--read-block <bytes>] [--read-tries <count>]\n",
    "  ", ScriptName, " log-restore <logfile> <dump-file>\n",
    "  ", ScriptName, " log-compact <logfile> [--read-block <bytes>] [--read-tries <count>]\n",
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

format_etoml_error({invalid_key, Line}) ->
  io_lib:format("line ~B: invalid key name", [Line]);
format_etoml_error({invalid_group, Line}) ->
  io_lib:format("line ~B: invalid group name", [Line]);
format_etoml_error({invalid_date, Line}) ->
  io_lib:format("line ~B: invalid date format", [Line]);
format_etoml_error({invalid_number, Line}) ->
  io_lib:format("line ~B: invalid number value or forgotten quotes", [Line]);
format_etoml_error({invalid_array, Line}) ->
  io_lib:format("line ~B: invalid array format", [Line]);
format_etoml_error({invalid_string, Line}) ->
  io_lib:format("line ~B: invalid string format", [Line]);
format_etoml_error({undefined_value, Line}) ->
  io_lib:format("line ~B: value not provided", [Line]);
format_etoml_error({duplicated_key, Key}) ->
  io_lib:format("duplicated key: ~s", [Key]).

%% @doc Configure environment (Erlang, Indira, main app) from loaded config.

-spec setup_applications(config(), #opts{}) ->
  {ok, [indira_app:daemon_option()]} | {error, term()}.

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
    {[<<"senders">>, <<"listen">>], {statip, senders}},
    {[<<"senders">>, <<"buffer_size">>], {statip, senders_tcp_buffer_size}},
    {[<<"readers">>, <<"listen">>], {statip, readers}},
    {[<<"state_log">>, <<"directory">>], {statip, state_dir}},
    {[<<"state_log">>, <<"compaction_size">>], {statip, compaction_size}},
    {[<<"events">>, <<"default_expiry">>], {statip, default_expiry}},
    {[<<"logging">>, <<"handlers">>], {statip, log_handlers}}
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
config_check([_Section, <<"listen">>] = _Key, _EnvKey, Values) ->
  try
    {ok, [parse_listen_spec(V) || V <- Values]}
  catch
    error:_ -> {error, invalid_value}
  end;
config_check([<<"senders">>, <<"buffer_size">>] = _Key, _EnvKey, Size)
when is_integer(Size), Size > 0 ->
  ok;
config_check([<<"state_log">>, <<"directory">>] = _Key, _EnvKey, Value)
when is_binary(Value) ->
  ok;
config_check([<<"state_log">>, <<"compaction_size">>] = _Key, _EnvKey, Size)
when is_integer(Size), Size > 0 ->
  ok;
config_check([<<"events">>, <<"default_expiry">>] = _Key, _EnvKey, Value)
when is_integer(Value), Value > 0 ->
  ok;
config_check([<<"logging">>, <<"handlers">>] = _Key, _EnvKey, Handlers)
when is_list(Handlers) ->
  try
    NewHandlers = [
      {binary_to_atom(H, utf8), []} ||
      H <- Handlers
    ],
    {ok, NewHandlers}
  catch
    error:_ ->
      {error, invalid_value}
  end;
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

%% @doc Configure Erlang logging.
%%   This function also starts SASL application if requested.

-spec setup_logging(config(), #opts{}) ->
  ok | {error, term()}.

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
      case indira_disk_h:install(error_logger, File) of
        ok -> ok;
        {error, Reason} -> {error, {log_file, Reason}}
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
  ErlangConfig = proplists:get_value(<<"erlang">>, GlobalConfig, []),
  try
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

cli_opt("--pidfile=" ++ Path = _Arg, Opts) ->
  cli_opt(["--pidfile", Path], Opts);
cli_opt("--pidfile" = _Arg, _Opts) ->
  {need, 1};
cli_opt(["--pidfile", Path] = _Arg, Opts = #opts{options = CLIOpts}) ->
  _NewOpts = Opts#opts{options = [{pidfile, Path} | CLIOpts]};

cli_opt("--config=" ++ Path = _Arg, Opts) ->
  cli_opt(["--config", Path], Opts);
cli_opt("--config" = _Arg, _Opts) ->
  {need, 1};
cli_opt(["--config", Path] = _Arg, Opts = #opts{options = CLIOpts}) ->
  _NewOpts = Opts#opts{options = [{config, Path} | CLIOpts]};

cli_opt("--timeout=" ++ Timeout = _Arg, Opts) ->
  cli_opt(["--timeout", Timeout], Opts);
cli_opt("--timeout" = _Arg, _Opts) ->
  {need, 1};
cli_opt(["--timeout", Timeout] = _Arg, Opts = #opts{options = CLIOpts}) ->
  case make_integer(Timeout) of
    {ok, Seconds} when Seconds > 0 ->
      % NOTE: we need timeout in milliseconds
      _NewOpts = Opts#opts{options = [{timeout, Seconds * 1000} | CLIOpts]};
    _ ->
      {error, bad_timeout}
  end;

cli_opt("--read-block=" ++ ReadBlock = _Arg, Opts) ->
  cli_opt(["--read-block", ReadBlock], Opts);
cli_opt("--read-block" = _Arg, _Opts) ->
  {need, 1};
cli_opt(["--read-block", ReadBlock] = _Arg, Opts = #opts{options = CLIOpts}) ->
  case make_integer(ReadBlock) of
    {ok, Bytes} when Bytes > 0, Bytes rem 8 == 0 ->
      _NewOpts = Opts#opts{options = [{read_block, Bytes} | CLIOpts]};
    _ ->
      {error, bad_read_block}
  end;

cli_opt("--read-tries=" ++ ReadTries = _Arg, Opts) ->
  cli_opt(["--read-tries", ReadTries], Opts);
cli_opt("--read-tries" = _Arg, _Opts) ->
  {need, 1};
cli_opt(["--read-tries", ReadTries] = _Arg, Opts = #opts{options = CLIOpts}) ->
  case make_integer(ReadTries) of
    {ok, Number} when Number > 0 ->
      _NewOpts = Opts#opts{options = [{read_tries, Number} | CLIOpts]};
    _ ->
      {error, bad_read_tries}
  end;

cli_opt("--debug" = _Arg, Opts = #opts{options = CLIOpts}) ->
  _NewOpts = Opts#opts{options = [{debug, true} | CLIOpts]};

cli_opt("--wait" = _Arg, Opts = #opts{options = CLIOpts}) ->
  _NewOpts = Opts#opts{options = [{wait, true} | CLIOpts]};

cli_opt("--print-pid" = _Arg, Opts = #opts{options = CLIOpts}) ->
  _NewOpts = Opts#opts{options = [{print_pid, true} | CLIOpts]};

cli_opt("-" ++ _ = _Arg, _Opts) ->
  {error, bad_option};

cli_opt(Arg, Opts = #opts{op = Op, args = OpArgs}) when Op /= undefined ->
  % `++' operator is a little costly, but considering how many arguments there
  % will be, the time it all takes will drown in Erlang startup
  _NewOpts = Opts#opts{args = OpArgs ++ [Arg]};

cli_opt(Arg, Opts = #opts{op = undefined}) ->
  case Arg of
    "start"  -> Opts#opts{op = start};
    "status" -> Opts#opts{op = status};
    "stop"   -> Opts#opts{op = stop};
    "reload" -> Opts#opts{op = reload_config};
    "compact"     -> Opts#opts{op = compact_statelog};
    "reopen-logs" -> Opts#opts{op = reopen_logs};
    "dist-erl-start" -> Opts#opts{op = dist_start};
    "dist-erl-stop"  -> Opts#opts{op = dist_stop};
    "list"   -> Opts#opts{op = list};
    "delete" -> Opts#opts{op = delete};
    "log-dump"    -> Opts#opts{op = log_dump};
    "log-replay"  -> Opts#opts{op = log_replay};
    "log-restore" -> Opts#opts{op = log_restore};
    "log-compact" -> Opts#opts{op = log_compact};
    _ -> {error, bad_command}
  end.

%% @doc Helper to convert string to integer.
%%
%%   Doesn't die on invalid argument.

-spec make_integer(string()) ->
  {ok, integer()} | {error, badarg}.

make_integer(String) ->
  try list_to_integer(String) of
    Integer -> {ok, Integer}
  catch
    error:badarg -> {error, badarg}
  end.

%% }}}
%%----------------------------------------------------------
%% printing lines to STDOUT and STDERR {{{

%% @doc Print a string to STDOUT, ending it with a new line.

-spec println(iolist() | binary()) ->
  ok.

println(Line) ->
  io:put_chars([Line, $\n]).

%% @doc Print an error to STDERR, ending it with a new line.

-spec printerr(iolist() | binary()) ->
  ok.

printerr(Line) ->
  printerr(Line, []).

%% @doc Print an error (with some context) to STDERR, ending it with a new
%%   line.

-spec printerr(iolist() | binary(), [{Name, Value}]) ->
  ok
  when Name :: atom(),
       Value :: atom() | string() | binary() | integer().

printerr(Line, InfoFields) ->
  Info = [
    [" ", format_info_field(Name, Value)] ||
    {Name, Value} <- InfoFields
  ],
  case Info of
    [] -> io:put_chars(standard_error, [Line, $\n]);
    _  -> io:put_chars(standard_error, [Line, $:, Info, $\n])
  end.

%% @doc Helper for {@link printerr/2}.

-spec format_info_field(atom(), Value) ->
  iolist()
  when Value :: atom() | integer().

% for now there's no use for string values
%format_info_field(Name, Value) when is_list(Value); is_binary(Value) ->
%  case re:run(Value, "^[a-zA-Z0-9~@_+:,./-]*$", [{capture, none}]) of
%    match ->
%      [atom_to_list(Name), $=, Value];
%    nomatch ->
%      PrintValue = re:replace(Value, "[\"\\\\]", "\\\\&", [global]),
%      [atom_to_list(Name), $=, $", PrintValue, $"]
%  end;
format_info_field(Name, Value) when is_integer(Value) ->
  [atom_to_list(Name), $=, integer_to_list(Value)];
format_info_field(Name, Value) when is_atom(Value) ->
  [atom_to_list(Name), $=, atom_to_list(Value)].

%% }}}
%%----------------------------------------------------------
%% log_dump() {{{

%% @doc Read state log file and dump the records to STDOUT.
%%
%%   Workhorse for `statetipd log-dump' command.

-spec log_dump(statip_flog:handle(), pos_integer(), pos_integer()) ->
  ok | {error, ExitCode :: pos_integer()}.

log_dump(Handle, ReadBlock, ReadTries) ->
  case statip_flog:read(Handle, ReadBlock) of
    {ok, Entry} ->
      {ok, JSON} = encode_log_record(Entry),
      println(JSON),
      log_dump(Handle, ReadBlock, ReadTries);
    eof ->
      ok;
    {error, bad_record} ->
      {ok, Pos} = statip_flog:position(Handle),
      printerr("damaged record found", [{position, Pos}]),
      case try_recover(Handle, ReadBlock, ReadTries) of
        {ok, Entry} ->
          printerr("recovered"),
          {ok, JSON} = encode_log_record(Entry),
          println(JSON),
          log_dump(Handle, ReadBlock, ReadTries);
        eof ->
          % the file has some damaged record at EOF, but not long enough for
          % this procedure to give up, so it's a success after all
          printerr("no more records found"),
          ok;
        none ->
          {ok, Pos1} = statip_flog:position(Handle),
          printerr("couldn't recover, giving up", [{end_position, Pos1}]),
          {error, ?EXIT_FORMAT};
        {error, Reason} -> % `Reason' is an atom
          % most probably some I/O error
          printerr("read error", [{reason, Reason}]),
          {error, ?EXIT_READ}
      end;
    {error, Reason} -> % `Reason' is an atom
      % most probably some I/O error
      printerr("read error", [{reason, Reason}]),
      {error, ?EXIT_READ}
  end.

%% @doc Recovery procedure for {@link log_dump/3}.

-spec try_recover(statip_flog:handle(), pos_integer(), pos_integer()) ->
  {ok, statip_flog:entry()} | eof | none | {error, file:posix()}.

try_recover(Handle, ReadBlock, ReadTries) ->
  case statip_flog:recover(Handle, ReadBlock) of
    {ok, Entry} -> {ok, Entry};
    none when ReadTries >= 1 -> try_recover(Handle, ReadBlock, ReadTries - 1);
    none when ReadTries < 1 -> none;
    eof -> eof;
    {error, Reason} -> {error, Reason}
  end.

%% }}}
%%----------------------------------------------------------
%% log_replay() {{{

%% @doc Replay state log file and dump the records to STDOUT.
%%
%%   Body for `statetipd log-replay' command.
%%
%% @see replay/3

-spec log_replay(statip_flog:handle(), pos_integer(), pos_integer()) ->
  ok | {error, ExitCode :: pos_integer()}.

log_replay(Handle, ReadBlock, ReadTries) ->
  case replay(Handle, ReadBlock, ReadTries) of
    {ok, Records} ->
      statip_flog:fold(fun fold_print/4, [], Records),
      ok;
    {error, ExitCode} ->
      {error, ExitCode}
  end.

%% @doc {@link statip_flog:fold/3} callback for {@link log_replay/3}.

fold_print({GroupName, GroupOrigin} = _Key, GroupType, Values, Acc) ->
  Acc1 = {GroupType, GroupName, GroupOrigin},
  lists:foldl(fun fold_print/2, Acc1, Values),
  Acc.

%% @doc {@link lists:foldl/3} callback for {@link fold_print/4}.

fold_print(Value, {Type, Name, Origin} = Acc) ->
  {ok, JSON} = encode_log_record({Type, Name, Origin, Value}),
  println(JSON),
  Acc.

%% }}}
%%----------------------------------------------------------
%% log_restore() {{{

%% @doc Read a log dump and write it to a state log file.
%%
%%   Body for `statetipd log-restore' command.
%%
%% @see log_restore/3

-spec log_restore(file:io_device(), statip_flog:handle()) ->
  ok | {error, ExitCode :: pos_integer()}.

log_restore(ReadHandle, WriteHandle) ->
  log_restore(ReadHandle, WriteHandle, 1).

%% @doc Workhorse for {@link log_restore/2}.

-spec log_restore(file:io_device(), statip_flog:handle(), pos_integer()) ->
  ok | {error, ExitCode :: pos_integer()}.

log_restore(ReadHandle, WriteHandle, LineNo) ->
  case file:read_line(ReadHandle) of
    {ok, Line} ->
      case decode_log_record(Line) of
        {ok, Record} ->
          case statip_flog:append(WriteHandle, Record) of
            ok ->
              log_restore(ReadHandle, WriteHandle, LineNo + 1);
            {error, Reason} ->
              printerr("write error", [{reason, Reason}, {line, LineNo}]),
              {error, ?EXIT_WRITE}
          end;
        {error, badarg} ->
          printerr("invalid record", [{line, LineNo}]),
          {error, ?EXIT_FORMAT}
      end;
    eof ->
      ok;
    {error, Reason} ->
      printerr("read error", [{reason, Reason}, {line, LineNo}]),
      {error, ?EXIT_READ}
  end.

%% }}}
%%----------------------------------------------------------
%% log_write_back() {{{

%% @doc Write values from replayed log file to a log file.
%%
%%   Function truncates the target log file.

-spec log_write_back(file:filename(), statip_flog:records()) ->
  ok | {error, ExitCode :: pos_integer()}.

log_write_back(LogFile, Records) ->
  case statip_flog:open(LogFile, [write, truncate]) of
    {ok, WriteHandle} ->
      try
        statip_flog:fold(fun fold_write/4, WriteHandle, Records),
        ok
      catch
        error:Reason -> % `Reason' is an atom
          printerr("record write error", [{reason, Reason}]),
          {error, ?EXIT_WRITE}
      end;
    {error, Reason} ->
      printerr("can't open log file for writing", [{reason, Reason}]),
      {error, ?EXIT_WRITE}
  end.

%% @doc {@link statip_flog:fold/3} callback for {@link log_write_back/2}.
%%
%%   <i>NOTE</i>: On write errors this function dies with the reason.

fold_write({GroupName, GroupOrigin} = _Key, GroupType, Values, Handle) ->
  Acc = {Handle, GroupType, GroupName, GroupOrigin},
  lists:foldl(fun fold_write/2, Acc, Values),
  Handle.

%% @doc {@link lists:foldl/3} callback for {@link fold_write/4}.
%%
%%   <i>NOTE</i>: On write errors this function dies with the reason.

fold_write(Value, {Handle, Type, Name, Origin} = Acc) ->
  case statip_flog:append(Handle, {Type, Name, Origin, Value}) of
    ok -> Acc;
    {error, Reason} -> erlang:error(Reason)
  end.

%% }}}
%%----------------------------------------------------------
%% replay() {{{

%% @doc Replay state log file.
%%
%%   Function prints error messages to STDERR.

-spec replay(statip_flog:handle(), pos_integer(), pos_integer()) ->
  {ok, statip_flog:records()} | {error, ExitCode :: pos_integer()}.

replay(Handle, ReadBlock, ReadTries) ->
  case statip_flog:replay(Handle, ReadBlock, ReadTries) of
    {ok, Records} ->
      {ok, Records};
    {error, bad_file} ->
      printerr("invalid first record, probably not a state log file"),
      {error, ?EXIT_FORMAT};
    {error, damaged_file} ->
      % XXX: recover() always reads full `ReadBlock' blocks except at EOF, but
      % then it would return `{ok, Records}', so the estimate here is precise
      {ok, EndPos} = statip_flog:position(Handle),
      Pos = EndPos - ReadBlock * ReadTries,
      printerr("file damaged beyond recovery", [{position, Pos}]),
      {error, ?EXIT_FORMAT};
    {error, Reason} ->
      printerr("read error", [{reason, Reason}]),
      {error, ?EXIT_READ}
  end.

%% }}}
%%----------------------------------------------------------
%% encode_log_record() {{{

%% @doc Encode a record from log file as a JSON.

-spec encode_log_record(statip_flog:entry()) ->
  {ok, iolist()} | {error, badarg}.

encode_log_record({GroupType, GroupName, GroupOrigin, Value} = _Entry)
when GroupType == related; GroupType == unrelated ->
  statip_json:encode([
    {type, GroupType} |
    statip_value:to_struct(GroupName, GroupOrigin, Value, [full])
  ]);
encode_log_record({clear, GroupName, GroupOrigin, Key} = _Entry) ->
  statip_json:encode([
    {type, clear},
    {name, GroupName},
    {origin, undef_null(GroupOrigin)},
    {key, Key}
  ]);
encode_log_record({clear, GroupName, GroupOrigin} = _Entry) ->
  statip_json:encode([
    {type, clear},
    {name, GroupName},
    {origin, undef_null(GroupOrigin)}
  ]);
encode_log_record({rotate, GroupName, GroupOrigin} = _Entry) ->
  statip_json:encode([
    {type, rotate},
    {name, GroupName},
    {origin, undef_null(GroupOrigin)}
  ]).

%% @doc Decode a record from JSON string.

-spec decode_log_record(string()) ->
  {ok, statip_flog:entry()} | {error, badarg}.

decode_log_record(JSON) ->
  case statip_json:decode(JSON) of
    {ok, [{<<"key">>, Key}, {<<"name">>, Name}, {<<"origin">>, Origin},
           {<<"type">>, <<"clear">>}]}
    when is_binary(Name), (is_binary(Origin) orelse Origin == null),
         is_binary(Key) ->
      {ok, {clear, Name, null_undef(Origin), Key}};

    {ok, [{<<"name">>, Name}, {<<"origin">>, Origin},
           {<<"type">>, <<"clear">>}]}
    when is_binary(Name), (is_binary(Origin) orelse Origin == null) ->
      {ok, {clear, Name, null_undef(Origin)}};

    {ok, [{<<"name">>, Name}, {<<"origin">>, Origin},
           {<<"type">>, <<"rotate">>}]}
    when is_binary(Name), (is_binary(Origin) orelse Origin == null) ->
      {ok, {rotate, Name, null_undef(Origin)}};

    {ok, Struct} ->
      try {proplists:get_value(<<"type">>, Struct),
           statip_value:from_struct(Struct)} of
        {<<"related">>, {Name, Origin, Value}} ->
          {ok, {related, Name, null_undef(Origin), Value}};
        {<<"unrelated">>, {Name, Origin, Value}} ->
          {ok, {unrelated, Name, null_undef(Origin), Value}};
        _ ->
          {error, badarg}
      catch
        _:_ ->
          {error, badarg}
      end;

    {error, badarg} ->
      {error, badarg}
  end.

undef_null(undefined = _Value) -> null;
undef_null(Value) -> Value.

null_undef(null = _Value) -> undefined;
null_undef(Value) -> Value.

%% }}}
%%----------------------------------------------------------

%%%---------------------------------------------------------------------------

%% @doc Load and set `statip' application config from a config file.
%%
%%   Function intended for use in reloading config in the runtime.
%%
%%   Errors are formatted with {@link format_error/1}.

-spec load_app_config(file:filename(), #opts{}) ->
  ok | {error, Message :: binary()}.

load_app_config(ConfigFile, Options) ->
  case read_config_file(ConfigFile) of
    {ok, Config} ->
      ok = reset_statip_config(),
      case configure_statip(config_defaults(Config), Options) of
        ok ->
          case load_error_logger_config(Config, Options) of
            ok -> load_indira_config(Config, Options);
            {error, Message} -> {error, Message}
          end;
        {error, Reason} ->
          {error, iolist_to_binary(format_error({configure, Reason}))}
      end;
    {error, Reason} ->
      {error, iolist_to_binary(format_error(Reason))}
  end.

%%----------------------------------------------------------
%% load_error_logger_config() {{{

%% @doc Set destination file for {@link error_logger}/{@link
%%   indira_disk_h}.
%%
%% @see load_app_config/2

-spec load_error_logger_config(config(), #opts{}) ->
  ok | {error, Message :: binary()}.

load_error_logger_config(Config, _Options) ->
  ErlangConfig = proplists:get_value(<<"erlang">>, Config, []),
  case proplists:get_value(<<"log_file">>, ErlangConfig) of
    File when is_binary(File) ->
      ok = indira_app:set_option(statip, error_logger_file, File);
    undefined ->
      ok = application:unset_env(statip, error_logger_file);
    _ ->
      {error, iolist_to_binary(format_error({configure, bad_config}))}
  end.

%% }}}
%%----------------------------------------------------------
%% load_indira_config() {{{

%% @doc Reconfigure Indira's network configuration for Erlang.
%%
%% @see load_app_config/2

-spec load_indira_config(config(), #opts{}) ->
  ok | {error, Message :: binary()}.

load_indira_config(Config, Options) ->
  case prepare_indira_options(Config, Options) of
    {ok, IndiraOptions} ->
      case indira_app:distributed_reconfigure(IndiraOptions) of
        ok ->
          ok;
        {error, invalid_net_config = _Reason} ->
          {error, <<"invalid network configuration">>};
        {error, Reason} ->
          Message = io_lib:format("Erlang network reloading error: ~1024p",
                                  [Reason]),
          {error, iolist_to_binary(Message)}
      end;
    {error, bad_config} ->
      % errors in "[erlang]" section
      {error, iolist_to_binary(format_error({configure, bad_config}))}
  end.

%% }}}
%%----------------------------------------------------------
%% reset_statip_config() {{{

%% @doc Reset `statip' application's environment to default values.
%%
%%   Two keys are omitted: `configure', which is not really a configuration
%%   setting (keeps "config reload" function for later use) and
%%   `default_expiry', which cannot be reset freely to an arbitrary temporary
%%   value like the others.
%%
%% @see config_defaults/1

reset_statip_config() ->
  CurrentConfig = [
    Entry ||
    {Key, _} = Entry <- application:get_all_env(statip),
    Key /= configure,     % not really part of the configuration
    Key /= default_expiry % immediately used, so needs special care
  ],
  DefaultConfig = dict:from_list(statip_default_env()),
  lists:foreach(
    fun({Key, _}) ->
      case dict:find(Key, DefaultConfig) of
        {ok, Value} -> application:set_env(statip, Key, Value);
        error -> application:unset_env(statip, Key)
      end
    end,
    CurrentConfig
  ),
  ok.

%% }}}
%%----------------------------------------------------------
%% config_defaults() {{{

%% @doc Populate config read from TOML file with values default for `statip'
%%   application.
%%
%%   This function is used for reloading config and only works for settings
%%   that cannot be freely reset to default (e.g.
%%   <i>senders.default_expiry</i>, which is used immediately).
%%
%% @see reset_statip_config/0

-spec config_defaults(config()) ->
  config().

config_defaults(Config) ->
  SendersSection = proplists:get_value(<<"senders">>, Config, []),
  case proplists:get_value(<<"default_expiry">>, SendersSection) of
    undefined ->
      Expiry = proplists:get_value(default_expiry, statip_default_env()),
      NewSendersSection = [{<<"default_expiry">>, Expiry} | SendersSection],
      _NewConfig = [{<<"senders">>, NewSendersSection} | Config];
    _ ->
      Config
  end.

%% }}}
%%----------------------------------------------------------
%% statip_default_env() {{{

%% @doc Extract application's default environment from `statip.app' file.

statip_default_env() ->
  StatipAppFile = filename:join(code:lib_dir(statip, ebin), "statip.app"),
  {ok, [{application, statip, AppKeys}]} = file:consult(StatipAppFile),
  proplists:get_value(env, AppKeys).

%% }}}
%%----------------------------------------------------------

%%%---------------------------------------------------------------------------
%%% vim:ft=erlang:foldmethod=marker
