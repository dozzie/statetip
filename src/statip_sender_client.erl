%%%---------------------------------------------------------------------------
%%% @doc
%%%   Sender client handler.
%%% @end
%%%---------------------------------------------------------------------------

-module(statip_sender_client).

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

-spec take_over(gen_tcp:socket()) ->
  ok.

take_over(Socket) ->
  {ok, Pid} = statip_sender_client_sup:spawn_worker(Socket),
  ok = gen_tcp:controlling_process(Socket, Pid),
  ok = inet:setopts(Socket, [binary, {packet, line}, {active, once}]),
  ok.

%%%---------------------------------------------------------------------------
%%% supervision tree API
%%%---------------------------------------------------------------------------

%% @private
%% @doc Start connection handler process.

start(Socket) ->
  gen_server:start(?MODULE, [Socket], []).

%% @private
%% @doc Start connection handler process.

start_link(Socket) ->
  gen_server:start_link(?MODULE, [Socket], []).

%%%---------------------------------------------------------------------------
%%% gen_server callbacks
%%%---------------------------------------------------------------------------

%%----------------------------------------------------------
%% initialization/termination {{{

%% @private
%% @doc Initialize {@link gen_server} state.

init([Socket] = _Args) ->
  State = #state{socket = Socket},
  {ok, State}.

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
  {reply, {error, unknown_call}, State}.

%% @private
%% @doc Handle {@link gen_server:cast/2}.

%% unknown casts
handle_cast(_Request, State) ->
  {noreply, State}.

%% @private
%% @doc Handle incoming messages.

%% TCP input
handle_info({tcp, Socket, Line} = _Request,
            State = #state{socket = Socket}) ->
  case decode(Line) of
    {ok, {Name, Origin, Value, Type}} ->
      statip_value:add(Name, Origin, Value, Type),
      inet:setopts(Socket, [{active, once}]),
      {noreply, State};
    {error, bad_format} ->
      % ignore content errors
      inet:setopts(Socket, [{active, once}]),
      {noreply, State};
    {error, not_json} ->
      % stop when non-JSON
      % TODO: log this event
      {stop, normal, State}
  end;

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

%% record decoding helper structure
-record(meta, {
  name    :: statip_value:name(),
  origin  :: statip_value:origin(),
  type    :: related | unrelated,
  created :: statip_value:timestamp(),
  expiry  :: statip_value:expiry()
}).

%% @doc Decode a JSON line into value and its metadata.

-spec decode(statip_json:json_string()) ->
    {ok, {statip_value:name(), statip_value:origin(), #value{},
           related | unrelated}}
  | {error, not_json | bad_format}.

decode(Line) ->
  case statip_json:decode(Line) of
    {ok, [{_,_}|_] = Struct} ->
      % TODO: move reading default to the caller
      {ok, DefaultExpiry} = application:get_env(statip, default_expiry),
      extract_value(Struct, DefaultExpiry);
    {ok, _} ->
      {error, bad_format};
    {error, _} ->
      {error, not_json}
  end.

%% @doc Extract value's info and record from JSON hash, filling defaults as
%%   needed.

-spec extract_value(statip_json:struct(), statip_value:expiry()) ->
    {ok, {statip_value:name(), statip_value:origin(), #value{},
           related | unrelated}}
  | {error, bad_format}.

extract_value(Struct, DefaultExpiry) ->
  try extract_value(Struct, #meta{}, #value{}) of
    {Meta = #meta{name = Name, origin = Origin, type = Type}, Value} ->
      NewValue = fill_defaults(Meta, Value, DefaultExpiry),
      {ok, {Name, Origin, NewValue, Type}}
  catch
    error:{badmatch,_} ->
      {error, bad_format}
  end.

%% @doc Fill default values in record.

-spec fill_defaults(#meta{}, #value{}, statip_value:expiry()) ->
  #value{}.

fill_defaults(Meta, Value, DefaultExpiry) ->
  case Meta of
    #meta{created = undefined} -> Created = statip_value:timestamp();
    #meta{created = Created} -> ok
  end,
  case Meta of
    #meta{expiry = undefined} -> Expiry = DefaultExpiry;
    #meta{expiry = Expiry} -> ok
  end,
  case Value of
    #value{sort_key = undefined, key = SortKey} -> ok;
    #value{sort_key = SortKey} -> ok
  end,
  _NewValue = Value#value{
    sort_key = SortKey,
    created = Created,
    expires = Created + Expiry
  }.

%% @doc Extract record's data and metadata from a hash decoded from JSON.
%%
%%   Function throws error `{badmatch,_}' when the hash contains recognized
%%   key with invalid data (unrecognized keys are ignored).

-spec extract_value(statip_json:struct(), #meta{}, #value{}) ->
  {#meta{}, #value{}} | no_return().

extract_value([] = _Struct, Meta, Value) ->
  {Meta, Value};

extract_value([{<<"name">>, Name} | Rest] = _Struct, Meta, Value) ->
  true = is_binary(Name),
  extract_value(Rest, Meta#meta{name = Name}, Value);

extract_value([{<<"origin">>, null} | Rest], Meta, Value) ->
  extract_value(Rest, Meta#meta{origin = undefined}, Value);
extract_value([{<<"origin">>, Origin} | Rest], Meta, Value) ->
  true = is_binary(Origin),
  extract_value(Rest, Meta#meta{origin = Origin}, Value);

extract_value([{<<"related">>, true} | Rest], Meta, Value) ->
  extract_value(Rest, Meta#meta{type = related}, Value);
extract_value([{<<"related">>, false} | Rest], Meta, Value) ->
  extract_value(Rest, Meta#meta{type = unrelated}, Value);
extract_value([{<<"related">>, IsRelated} | _Rest], _Meta, _Value) ->
  erlang:error({badmatch, IsRelated}); % any other "related" value is invalid

extract_value([{<<"created">>, Created} | Rest], Meta, Value) ->
  true = is_integer(Created),
  extract_value(Rest, Meta#meta{created = Created}, Value);

extract_value([{<<"expiry">>, Expiry} | Rest], Meta, Value) ->
  true = is_integer(Expiry),
  true = Expiry > 0,
  extract_value(Rest, Meta#meta{expiry = Expiry}, Value);

extract_value([{<<"key">>, Key} | Rest], Meta, Value) ->
  true = is_binary(Key),
  extract_value(Rest, Meta, Value#value{key = Key});

extract_value([{<<"sort_key">>, null} | Rest], Meta, Value) ->
  extract_value(Rest, Meta, Value#value{sort_key = undefined});
extract_value([{<<"sort_key">>, SortKey} | Rest], Meta, Value) ->
  true = is_binary(SortKey),
  extract_value(Rest, Meta, Value#value{sort_key = SortKey});

extract_value([{<<"state">>, null} | Rest], Meta, Value) ->
  extract_value(Rest, Meta, Value#value{state = undefined});
extract_value([{<<"state">>, State} | Rest], Meta, Value) ->
  true = is_binary(State),
  extract_value(Rest, Meta, Value#value{state = State});

extract_value([{<<"severity">>, <<"expected">>} | Rest], Meta, Value) ->
  extract_value(Rest, Meta, Value#value{severity = expected});
extract_value([{<<"severity">>, <<"warning">>} | Rest], Meta, Value) ->
  extract_value(Rest, Meta, Value#value{severity = warning});
extract_value([{<<"severity">>, <<"error">>} | Rest], Meta, Value) ->
  extract_value(Rest, Meta, Value#value{severity = error});
extract_value([{<<"severity">>, Severity} | _Rest], _Meta, _Value) ->
  erlang:error({badmatch, Severity}); % any other severity is invalid

extract_value([{<<"info">>, Info} | Rest], Meta, Value) ->
  extract_value(Rest, Meta, Value#value{info = Info});

extract_value([{_Key, _Value} | Rest], Meta, Value) ->
  % skip unknown keys
  extract_value(Rest, Meta, Value).

%%%---------------------------------------------------------------------------
%%% vim:ft=erlang:foldmethod=marker
