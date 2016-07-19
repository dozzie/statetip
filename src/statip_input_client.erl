%%%---------------------------------------------------------------------------
%%% @doc
%%%   Client connection handler process.
%%% @end
%%%---------------------------------------------------------------------------

-module(statip_input_client).

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

-record(state, {
  socket :: gen_tcp:socket()
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
  {ok, Pid} = statip_input_client_sup:spawn_worker(Socket),
  ok = gen_tcp:controlling_process(Socket, Pid),
  ok = gen_server:call(Pid, start_handling),
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

handle_call(start_handling = _Request, _From,
            State = #state{socket = Socket}) ->
  inet:setopts(Socket, [{active, once}]),
  {reply, ok, State};

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

%% TCP input
handle_info({tcp, Socket, _Line} = _Request,
            State = #state{socket = Socket}) ->
  gen_tcp:send(Socket, "ACK\n"),
  inet:setopts(Socket, [{active, once}]),
  {noreply, State};

handle_info({tcp_closed, Socket} = _Request,
            State = #state{socket = Socket}) ->
  {stop, normal, State};

handle_info({tcp_error, Socket, _Reason} = _Request,
            State = #state{socket = Socket}) ->
  % TODO: log the error
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
%%% vim:ft=erlang:foldmethod=marker
