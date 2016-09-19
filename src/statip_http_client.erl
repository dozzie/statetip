%%%---------------------------------------------------------------------------
%%% @doc
%%%   HTTP client connection handler process.
%%% @end
%%%---------------------------------------------------------------------------

-module(statip_http_client).

-behaviour(gen_server).

%% public interface
-export([take_over/1]).

%% supervision tree API
-export([start/1, start_link/1]).

%% gen_server callbacks
-export([init/1, terminate/2]).
-export([handle_call/3, handle_cast/2, handle_info/2]).
-export([code_change/3]).

%%%---------------------------------------------------------------------------
%%% types {{{

-include("statip_value.hrl").

-record(state, {
  socket :: gen_tcp:socket(),
  path :: binary(),
  headers = [] :: [{binary(), binary()}]
}).

%%% }}}
%%%---------------------------------------------------------------------------
%%% public interface
%%%---------------------------------------------------------------------------

%% @doc Spawn a process to handle the transmission from the socket.
%%
%%   Function assumes that it was called from owner of the `Socket' and passes
%%   `Socket''s ownership to the spawned process. Parent should not close
%%   `Socket' after calling this function.

-spec take_over(gen_tcp:socket()) ->
  ok.

take_over(Socket) ->
  {ok, Pid} = statip_http_client_sup:spawn_worker(Socket),
  ok = gen_tcp:controlling_process(Socket, Pid),
  ok = inet:setopts(Socket, [binary, {packet, http_bin}, {active, once}]),
  ok.

%%%---------------------------------------------------------------------------
%%% supervision tree API
%%%---------------------------------------------------------------------------

%% @private
%% @doc Start example process.

start(Socket) ->
  gen_server:start(?MODULE, [Socket], []).

%% @private
%% @doc Start example process.

start_link(Socket) ->
  gen_server:start_link(?MODULE, [Socket], []).

%%%---------------------------------------------------------------------------
%%% gen_server callbacks
%%%---------------------------------------------------------------------------

%%----------------------------------------------------------
%% initialization/termination {{{

%% @private
%% @doc Initialize event handler.

init([Socket] = _Args) ->
  State = #state{socket = Socket},
  {ok, State}.

%% @private
%% @doc Clean up after event handler.

terminate(_Arg, _State = #state{socket = Socket}) ->
  gen_tcp:close(Socket),
  ok.

%% }}}
%%----------------------------------------------------------
%% communication {{{

%% @private
%% @doc Handle {@link gen_server:call/2}.

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

%% parts of HTTP request
handle_info({http, Socket, Packet} = _Request,
            State = #state{socket = Socket}) ->
  case parse_request(Packet, State) of
    {next, NewState} ->
      inet:setopts(Socket, [{active, once}]),
      {noreply, NewState};
    {done, NewState} ->
      try process_request(NewState) of
        {ok, Headers, Body} ->
          gen_tcp:send(Socket, [http_reply(200, Headers), Body]),
          {stop, normal, NewState};
        {error, ErrorCode} when ErrorCode >= 400, ErrorCode =< 599 ->
          gen_tcp:send(Socket, [http_reply(ErrorCode)]),
          {stop, normal, NewState}
      catch
        Error:Reason ->
          % TODO: log this
          gen_tcp:send(Socket, [http_reply(500)]),
          {stop, {Error, Reason}, State}
      end;
    {error, bad_method = _Reason} ->
      gen_tcp:send(Socket, http_reply(405)),
      {stop, normal, State};
    {error, _Reason} ->
      gen_tcp:send(Socket, http_reply(400)),
      {stop, normal, State}
  end;

handle_info({tcp_closed, Socket} = _Request,
            State = #state{socket = Socket}) ->
  {stop, normal, State};

handle_info({tcp_error, Socket, _Reason} = _Request,
            State = #state{socket = Socket}) ->
  {stop, normal, State};

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
%%% parsing HTTP request for gen_server {{{

parse_request({http_request, 'GET', {abs_path, Path}, _Version}, State) ->
  NewState = State#state{path = Path},
  {next, NewState};
parse_request({http_request, _Method, _Path, _Version}, _State) ->
  {error, bad_method};
parse_request({http_header, _WTF, Field, _Reserved, Value},
              State = #state{headers = Headers}) ->
  NewState = State#state{headers = [{ensure_binary(Field), Value} | Headers]},
  {next, NewState};
parse_request(http_eoh, State) ->
  {done, State};
parse_request(_Request, _State) ->
  {error, badarg}.

ensure_binary(Field) when is_atom(Field) -> atom_to_binary(Field, utf8);
ensure_binary(Field) when is_binary(Field) -> Field.

%%% }}}
%%%---------------------------------------------------------------------------
%%% building HTTP reply {{{

http_reply(Code) when is_integer(Code) ->
  http_reply(Code, []).

http_reply(Code, Headers) when is_integer(Code) ->
  _Result = [
    "HTTP/1.1 ", integer_to_list(Code), " ", code_desc(Code), "\r\n",
    "Server: StateTip/0.0.0\r\n",
    "Connection: close\r\n",
    [[H, "\r\n"] || H <- Headers],
    "\r\n"
  ].

code_desc(200) -> "OK";
code_desc(400) -> "Bad request";
code_desc(404) -> "Not found";
code_desc(405) -> "Method not allowed";
code_desc(500) -> "Server error".

%%% }}}
%%%---------------------------------------------------------------------------

-spec process_request(#state{}) ->
  {ok, Headers :: [string()], Body :: iolist() | binary()} | {error, 404}.

process_request(_State = #state{path = Path, headers = _Headers}) ->
  case split_path(Path) of
    {ok, {_Type, Name}} ->
      Reply = [
        "name: ", Name, "\n"
      ],
      {ok, ["Content-Type: text/plain"], Reply};
    {ok, {_Type, Name, Origin}} ->
      % FIXME: or maybe `Name, Key' with empty origin?
      Reply = [
        "name:   ", Name, "\n",
        "origin: ", Origin, "\n"
      ],
      {ok, ["Content-Type: text/plain"], Reply};
    {ok, {_Type, Name, Origin, Key}} ->
      Reply = [
        "name:   ", Name, "\n",
        "origin: ", Origin, "\n",
        "key:    ", Key, "\n"
      ],
      {ok, ["Content-Type: text/plain"], Reply};
    {error, _Reason} ->
      {error, 404}
  end.

%%----------------------------------------------------------
%% extract information on what to return {{{

-spec split_path(binary()) ->
  {ok, Result} | {error, bad_prefix | bad_name | bad_origin}
  when Result :: {Type, Name}
               | {Type, Name, Origin}
               | {Type, Name, Origin, Key},
       Name :: binary(),
       Origin :: binary(),
       Key :: binary(),
       Type :: list | json | all | json_all.

split_path(<<"/list/",     Rest/binary>> = _Path) -> fragments(list, Rest);
split_path(<<"/json/",     Rest/binary>> = _Path) -> fragments(json, Rest);
split_path(<<"/all/",      Rest/binary>> = _Path) -> fragments(all, Rest);
split_path(<<"/json-all/", Rest/binary>> = _Path) -> fragments(json_all, Rest);
split_path(_Path) -> {error, bad_prefix}.

-spec fragments(Type :: atom(), binary()) ->
  {ok, Result} | {error, bad_name | bad_origin}
  when Result :: {Type, Name :: binary()}
               | {Type, Name :: binary(), Origin :: binary()}
               | {Type, Name :: binary(), Origin :: binary(), Key :: binary()}.

fragments(Type, Path) ->
  % TODO: percent-decode
  case binary:split(Path, <<"/">>, [trim]) of
    []         -> {error, bad_name};
    [<<>> | _] -> {error, bad_name};
    [Name]     -> {ok, {Type, Name}};
    [Name, Rest] ->
      case binary:split(Rest, <<"/">>, [trim]) of
        []            -> {error, bad_origin};
        [<<>> | _]    -> {error, bad_origin};
        [Origin]      -> {ok, {Type, Name, Origin}};
        [Origin, Key] -> {ok, {Type, Name, Origin, Key}}
      end
  end.

%% }}}
%%----------------------------------------------------------

%%%---------------------------------------------------------------------------
%%% vim:ft=erlang:foldmethod=marker
