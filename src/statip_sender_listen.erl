%%%---------------------------------------------------------------------------
%%% @doc
%%%   Sender connection listener process.
%%% @end
%%%---------------------------------------------------------------------------

-module(statip_sender_listen).

-behaviour(gen_server).

%% supervision tree API
-export([start/2, start_link/2]).

%% config reloading
-export([reload/1]).

%% gen_server callbacks
-export([init/1, terminate/2]).
-export([handle_call/3, handle_cast/2, handle_info/2]).
-export([code_change/3]).

%%%---------------------------------------------------------------------------
%%% types {{{

-define(ACCEPT_LOOP_INTERVAL, 100).

-record(state, {
  socket :: gen_tcp:socket()
}).

%%% }}}
%%%---------------------------------------------------------------------------
%%% supervision tree API
%%%---------------------------------------------------------------------------

%% @private
%% @doc Start listener process.

start(BindAddr, Port) ->
  gen_server:start(?MODULE, [BindAddr, Port], []).

%% @private
%% @doc Start listener process.

start_link(BindAddr, Port) ->
  gen_server:start_link(?MODULE, [BindAddr, Port], []).

%%%---------------------------------------------------------------------------
%%% config reloading
%%%---------------------------------------------------------------------------

%% @doc Reload configuration (listen address).

-spec reload(pid()) ->
  ok | {error, term()}.

reload(_Pid) ->
  ok. % TODO: gen_server:call(Pid, reload)

%%%---------------------------------------------------------------------------
%%% gen_server callbacks
%%%---------------------------------------------------------------------------

%%----------------------------------------------------------
%% initialization/termination {{{

%% @private
%% @doc Initialize {@link gen_server} state.

init([Addr, Port] = _Args) ->
  case bind_opts(Addr) of
    {ok, BindOpts} ->
      Options = [
        binary, {packet, line}, {active, false},
        {reuseaddr, true}, {keepalive, true} | BindOpts
      ],
      case gen_tcp:listen(Port, Options) of
        {ok, Socket} ->
          State = #state{socket = Socket},
          {ok, State, 0};
        {error, Reason} ->
          {stop, {listen, Reason}}
      end;
    {error, Reason} ->
      {stop, {resolve, Reason}}
  end.

%% @private
%% @doc Clean up {@link gen_server} state.

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
  {reply, {error, unknown_call}, State, 0}.

%% @private
%% @doc Handle {@link gen_server:cast/2}.

%% unknown casts
handle_cast(_Request, State) ->
  {noreply, State, 0}.

%% @private
%% @doc Handle incoming messages.

handle_info(timeout = _Message, State = #state{socket = Socket}) ->
  case gen_tcp:accept(Socket, ?ACCEPT_LOOP_INTERVAL) of
    {ok, Client} ->
      ok = statip_sender_client:take_over(Client),
      {noreply, State, 0};
    {error, timeout} ->
      % OK, no incoming connection
      {noreply, State, 0};
    {error, Reason} ->
      {stop, {accept, Reason}, State}
  end;

%% unknown messages
handle_info(_Message, State) ->
  {noreply, State, 0}.

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

%% @doc Convert bind hostname to options list suitable for {@link
%%   gen_tcp:listen/2}.
%%
%% @todo IPv6 support

bind_opts(any = _Address) ->
  {ok, []};
bind_opts({_,_,_,_} = Address) ->
  {ok, [{ip, Address}]};
bind_opts(Address) when is_list(Address); is_atom(Address) ->
  case inet:getaddr(Address, inet) of
    {ok, IPAddr} -> {ok, [{ip, IPAddr}]};
    {error, Reason} -> {error, Reason}
  end.

%%%---------------------------------------------------------------------------
%%% vim:ft=erlang:foldmethod=marker
