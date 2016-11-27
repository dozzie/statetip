%%%---------------------------------------------------------------------------
%%% @doc
%%%   Event log collector process and logging functions.
%%%
%%%   Process conforms to {@link gen_event} interface and loads all the event
%%%   handlers defined in `statip' application's environment `log_handlers'
%%%   (a list of tuples {@type @{atom(), term()@}}).
%%%
%%%   The events send with these functions have following structure:
%%%   {@type @{log, pid(), info | warning | error, event_type(),
%%%     event_info()@}}.
%%%
%%% @see statip_syslog_h
%%% @see statip_stdout_h
%%% @end
%%%---------------------------------------------------------------------------

-module(statip_log).

%% logging interface
-export([set_context/2, append_context/1, get_context/0]).
-export([info/1, warn/1, err/1]).
-export([info/2, warn/2, err/2]).
-export([info/3, warn/3, err/3]).
-export([unexpected_call/3, unexpected_call/2]).
-export([unexpected_cast/2, unexpected_info/2]).
%% event serialization
-export([to_string/1]).

%% supervision tree API
-export([start/0, start_link/0]).

%% config reloading
-export([reload/0]).

-export_type([event_type/0, event_info/0, event_message/0]).

%%%---------------------------------------------------------------------------

-type event_info() ::
  [{atom(), statip_json:struct() | {term, term()} | {str, string()}}].

-type event_type() :: atom().

-type event_message() :: string() | binary().

%%%---------------------------------------------------------------------------
%%% logging interface
%%%---------------------------------------------------------------------------

%% @doc Set logging context.

-spec set_context(event_type(), event_info()) ->
  ok.

set_context(EventType, EventInfo) ->
  put('$statip_log', {EventType, EventInfo}),
  ok.

%% @doc Append information to logging context.

-spec append_context(event_info()) ->
  ok.

append_context(EventInfo) ->
  {EventType, EventContext} = get('$statip_log'),
  put('$statip_log', {EventType, EventContext ++ EventInfo}),
  ok.

%% @doc Get logging context.

-spec get_context() ->
  {event_type(), event_info()} | undefined.

get_context() ->
  get('$statip_log').

%% @doc Event of informative significance.
%%   New client connected, issued a cancel order, submitted new job, etc.
%%
%%   Function expects {@link set_context/2} to be called first.

-spec info(event_message()) ->
  ok.

info(Message) ->
  {EventType, EventContext} = get_context(),
  event(info, EventType, [{message, message(Message)} | EventContext]).

%% @doc Event of informative significance.
%%   New client connected, issued a cancel order, submitted new job, etc.
%%
%%   Function expects {@link set_context/2} to be called first.

-spec info(event_message(), event_info()) ->
  ok.

info(Message, EventInfo) ->
  {EventType, EventContext} = get_context(),
  event(info, EventType,
        [{message, message(Message)} | EventInfo] ++ EventContext).

%% @doc Event of informative significance.
%%   New client connected, issued a cancel order, submitted new job, etc.

-spec info(event_type(), event_message(), event_info()) ->
  ok.

info(EventType, Message, EventInfo) ->
  event(info, EventType, [{message, message(Message)} | EventInfo]).

%% @doc Minor error event.
%%   Typically the error has its cause in some remote entity (e.g. protocol
%%   error), but it's harmless for the operation of HarpCaller.
%%
%%   Function expects {@link set_context/2} to be called first.

-spec warn(event_message()) ->
  ok.

warn(Message) ->
  {EventType, EventContext} = get_context(),
  event(warning, EventType, [{message, message(Message)} | EventContext]).

%% @doc Minor error event.
%%   Typically the error has its cause in some remote entity (e.g. protocol
%%   error), but it's harmless for the operation of HarpCaller.
%%
%%   Function expects {@link set_context/2} to be called first.

-spec warn(event_message(), event_info()) ->
  ok.

warn(Message, EventInfo) ->
  {EventType, EventContext} = get_context(),
  event(warning, EventType,
        [{message, message(Message)} | EventInfo] ++ EventContext).

%% @doc Minor error event.
%%   Typically the error has its cause in some remote entity (e.g. protocol
%%   error), but it's harmless for the operation of HarpCaller.

-spec warn(event_type(), event_message(), event_info()) ->
  ok.

warn(EventType, Message, EventInfo) ->
  event(warning, EventType, [{message, message(Message)} | EventInfo]).

%% @doc Major error event.
%%   An unexpected event that should never occur, possibly threatening service
%%   operation (or part of it).
%%
%%   Function expects {@link set_context/2} to be called first.

-spec err(event_message()) ->
  ok.

err(Message) ->
  {EventType, EventContext} = get_context(),
  event(error, EventType, [{message, message(Message)} | EventContext]).

%% @doc Major error event.
%%   An unexpected event that should never occur, possibly threatening service
%%   operation (or part of it).
%%
%%   Function expects {@link set_context/2} to be called first.

-spec err(event_message(), event_info()) ->
  ok.

err(Message, EventInfo) ->
  {EventType, EventContext} = get_context(),
  event(error, EventType,
        [{message, message(Message)} | EventInfo] ++ EventContext).

%% @doc Major error event.
%%   An unexpected event that should never occur, possibly threatening service
%%   operation (or part of it).

-spec err(event_type(), event_message(), event_info()) ->
  ok.

err(EventType, Message, EventInfo) ->
  event(error, EventType, [{message, message(Message)} | EventInfo]).

%% @doc Report an unexpected call request to {@link gen_server} process.
%%
%%   Report is sent to {@link error_logger} as an error report of type
%%   `statip'.

-spec unexpected_call(term(), term(), module()) ->
  ok.

unexpected_call(Request, From, Module) ->
  error_logger:error_report(statip, [
    {unexpected, call},
    {request, Request},
    {from, From},
    {module, Module}
  ]).

%% @doc Report an unexpected call request to {@link gen_event} process.
%%
%%   Report is sent to {@link error_logger} as an error report of type
%%   `statip'.

-spec unexpected_call(term(), module()) ->
  ok.

unexpected_call(Request, Module) ->
  error_logger:error_report(statip, [
    {unexpected, call},
    {request, Request},
    {module, Module}
  ]).

%% @doc Report an unexpected cast request to {@link gen_server} process.
%%
%%   Report is sent to {@link error_logger} as an error report of type
%%   `statip'.

-spec unexpected_cast(term(), module()) ->
  ok.

unexpected_cast(Request, Module) ->
  error_logger:error_report(statip, [
    {unexpected, cast},
    {request, Request},
    {module, Module}
  ]).

%% @doc Report an unexpected message sent to a process.
%%
%%   Report is sent to {@link error_logger} as an error report of type
%%   `statip'.

-spec unexpected_info(term(), module()) ->
  ok.

unexpected_info(Message, Module) ->
  error_logger:error_report(statip, [
    {unexpected, message},
    {message, Message},
    {module, Module}
  ]).

%%----------------------------------------------------------
%% logging interface helpers
%%----------------------------------------------------------

%% @doc Send an event to the logger.

-spec event(info | warning | error, event_type(), event_info()) ->
  ok.

event(Level, Type, Info) ->
  gen_event:notify(?MODULE, {log, self(), Level, Type, Info}).

%% @doc Ensure that event message is a binary.

-spec message(event_message()) ->
  binary().

message(Message) when is_list(Message) ->
  list_to_binary(Message);
message(Message) when is_binary(Message) ->
  Message.

%%%---------------------------------------------------------------------------
%%% event serialization
%%%---------------------------------------------------------------------------

%% @doc Convert {@type event_info()} to JSON string.
%%
%% @see statip_json:encode/1

-spec to_string(event_info()) ->
  iolist().

to_string(Data) ->
  {ok, JSON} = statip_json:encode([{K, struct_or_string(V)} || {K,V} <- Data]),
  JSON.

%% @doc Convert single value from {@type event_info()} to something
%%   JSON-serializable.

-spec struct_or_string(Entry) ->
  statip_json:struct()
  when Entry :: statip_json:struct() | {term, term()} | {str, string()}.

struct_or_string({term, Term} = _Entry) ->
  % 4GB line limit should be more than enough to have it in a single line
  iolist_to_binary(io_lib:print(Term, 1, 16#FFFFFFFF, -1));
struct_or_string({str, String} = _Entry) ->
  % even if the string is a binary, this will convert it all to a binary
  iolist_to_binary(String);
struct_or_string(Entry) ->
  Entry.

%%%---------------------------------------------------------------------------
%%% supervision tree API
%%%---------------------------------------------------------------------------

%% @private
%% @doc Start log collector process.

start() ->
  case gen_event:start({local, ?MODULE}) of
    {ok, Pid} ->
      case add_handlers(Pid, get_handlers()) of
        ok ->
          {ok, Pid};
        {error, Reason} ->
          gen_event:stop(Pid),
          {error, Reason}
      end;
    {error, Reason} ->
      {error, Reason}
  end.

%% @private
%% @doc Start log collector process.

start_link() ->
  case gen_event:start_link({local, ?MODULE}) of
    {ok, Pid} ->
      case add_handlers(Pid, get_handlers()) of
        ok ->
          {ok, Pid};
        {error, Reason} ->
          gen_event:stop(Pid),
          {error, Reason}
      end;
    {error, Reason} ->
      {error, Reason}
  end.

%% @doc Reload log handlers.

-spec reload() ->
  ok | {error, term()}.

reload() ->
  % TODO: make this a little smarter than remove-all-add-all
  lists:foreach(
    fun(H) -> gen_event:delete_handler(?MODULE, H, []) end,
    gen_event:which_handlers(?MODULE)
  ),
  add_handlers(whereis(?MODULE), get_handlers()).

%% @doc Get handlers defined in application environment.

-spec get_handlers() ->
  [{atom(), term()}].

get_handlers() ->
  case application:get_env(statip, log_handlers) of
    {ok, LogHandlers} -> LogHandlers;
    undefined -> []
  end.

%% @doc Add event handlers to gen_event.

-spec add_handlers(pid(), [{atom(), term()}]) ->
  ok | {error, term()}.

add_handlers(_Pid, [] = _Handlers) ->
  ok;
add_handlers(Pid, [{Mod, Args} | Rest] = _Handlers) ->
  case gen_event:add_handler(Pid, Mod, Args) of
    ok -> add_handlers(Pid, Rest);
    {error, Reason} -> {error, {Mod, Reason}};
    {'EXIT', Reason} -> {error, {exit, Mod, Reason}}
  end.

%%%---------------------------------------------------------------------------
%%% vim:ft=erlang:foldmethod=marker
