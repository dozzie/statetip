%%%---------------------------------------------------------------------------
%%% @doc
%%%   HTTP client connection handler process.
%%% @end
%%%---------------------------------------------------------------------------

-module(statip_http_client).

-behaviour(gen_server).

%% public interface
-export([handle_socket/1]).

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

-spec handle_socket(gen_tcp:socket()) ->
  ok.

handle_socket(Socket) ->
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
      process_request(NewState),
      {stop, normal, NewState};
    {error, bad_method = _Reason} ->
      send_error(Socket, 405),
      {stop, normal, State};
    {error, _Reason} ->
      send_error(Socket, 400),
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

send_error(Socket, ErrorCode) ->
  gen_tcp:send(Socket, [
    "HTTP/1.1 ", integer_to_list(ErrorCode),
    " ", error_desc(ErrorCode), "\r\n",
    common_headers(),
    "\r\n"
  ]).

error_desc(400) -> "Bad request";
error_desc(404) -> "Not found";
error_desc(405) -> "Method not allowed";
error_desc(500) -> "Server error".

common_headers() ->
  _Headers = [
    "Server: StateTip/0.0.0\r\n",
    "Connection: close\r\n"
  ].

%%%---------------------------------------------------------------------------

process_request(_State = #state{socket = Socket, path = Path,
                                headers = _Headers}) ->
  {MS, S, US} = os:timestamp(),
  Time = io_lib:format("~B~6..0B.~6..0B", [MS, S, US]),
  gen_tcp:send(Socket, [
    "HTTP/1.1 200 OK\r\n",
    common_headers(),
    "Content-Type: text/plain\r\n",
    "\r\n",
    "requested path: ", Path, "\n",
    "now: ", Time, "\n",
    ""
  ]),
  ok.

%%%---------------------------------------------------------------------------
%%% vim:ft=erlang:foldmethod=marker
