%%%---------------------------------------------------------------------------
%%% @doc
%%%   Client connection handler process.
%%% @end
%%%---------------------------------------------------------------------------

-module(statip_input_client).

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
  {ok, Pid} = statip_input_client_sup:spawn_worker(Socket),
  ok = gen_tcp:controlling_process(Socket, Pid),
  ok = inet:setopts(Socket, [binary, {packet, line}, {active, once}]),
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

%% TCP input
handle_info({tcp, Socket, Line} = _Request,
            State = #state{socket = Socket}) ->
  case decode(Line) of
    {ok, {Name, Origin, Record, Type}} ->
      statip_value:add(Name, Origin, Record, Type),
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
  type    :: single | burst,
  created :: statip_value:timestamp(),
  expiry  :: statip_value:expiry()
}).

%% @doc Decode a JSON line into value's info and record.

-spec decode(statip_json:json_string()) ->
    {ok, {statip_value:name(), statip_value:origin(), #value{}, single | burst}}
  | {error, not_json | bad_format}.

decode(Line) ->
  case statip_json:decode(Line) of
    {ok, [{_,_}|_] = Struct} ->
      % TODO: move reading default to the caller
      {ok, DefaultExpiry} = application:get_env(statip, default_expiry),
      extract_record(Struct, DefaultExpiry);
    {ok, _} ->
      {error, bad_format};
    {error, _} ->
      {error, not_json}
  end.

%% @doc Extract value's info and record from JSON hash, filling defaults as
%%   needed.

-spec extract_record(statip_json:struct(), statip_value:expiry()) ->
    {ok, {statip_value:name(), statip_value:origin(), #value{}, single | burst}}
  | {error, bad_format}.

extract_record(Struct, DefaultExpiry) ->
  try extract_record(Struct, #meta{}, #value{}) of
    {Meta = #meta{name = Name, origin = Origin, type = Type}, Record} ->
      NewRecord = fill_defaults(Meta, Record, DefaultExpiry),
      {ok, {Name, Origin, NewRecord, Type}}
  catch
    error:{badmatch,_} ->
      {error, bad_format}
  end.

%% @doc Fill default values in record.

-spec fill_defaults(#meta{}, #value{}, statip_value:expiry()) ->
  #value{}.

fill_defaults(Meta = #meta{created = undefined}, Record, DefaultExpiry) ->
  NewMeta = Meta#meta{created = statip_value:timestamp()},
  fill_defaults(NewMeta, Record, DefaultExpiry);
fill_defaults(Meta = #meta{expiry = undefined}, Record, DefaultExpiry) ->
  NewMeta = Meta#meta{expiry = DefaultExpiry},
  fill_defaults(NewMeta, Record, DefaultExpiry);
fill_defaults(_Meta = #meta{created = Created, expiry = Expiry}, Record,
              _DefaultExpiry) ->
  case Record of
    #value{sort_key = undefined, key = SortKey} -> ok;
    #value{sort_key = SortKey} -> ok
  end,
  _NewRecord = Record#value{
    sort_key = SortKey,
    created = Created,
    expires = Created + Expiry
  }.

%% @doc Extract record's data and metadata from a hash decoded from JSON.
%%
%%   Function throws error `{badmatch,_}' when the hash contains recognized
%%   key with invalid data (unrecognized keys are ignored).

-spec extract_record(statip_json:struct(), #meta{}, #value{}) ->
  {#meta{}, #value{}} | no_return().

extract_record([] = _Struct, Meta, Record) ->
  {Meta, Record};

extract_record([{<<"name">>, Name} | Rest] = _Struct, Meta, Record) ->
  true = is_binary(Name),
  extract_record(Rest, Meta#meta{name = Name}, Record);

extract_record([{<<"origin">>, null} | Rest], Meta, Record) ->
  extract_record(Rest, Meta#meta{origin = undefined}, Record);
extract_record([{<<"origin">>, Origin} | Rest], Meta, Record) ->
  true = is_binary(Origin),
  extract_record(Rest, Meta#meta{origin = Origin}, Record);

extract_record([{<<"burst">>, true} | Rest], Meta, Record) ->
  extract_record(Rest, Meta#meta{type = burst}, Record);
extract_record([{<<"burst">>, false} | Rest], Meta, Record) ->
  extract_record(Rest, Meta#meta{type = single}, Record);
extract_record([{<<"burst">>, IsBurst} | _Rest], _Meta, _Record) ->
  erlang:error({badmatch, IsBurst}); % any other burst value is invalid

extract_record([{<<"created">>, Created} | Rest], Meta, Record) ->
  true = is_integer(Created),
  extract_record(Rest, Meta#meta{created = Created}, Record);

extract_record([{<<"expiry">>, Expiry} | Rest], Meta, Record) ->
  true = is_integer(Expiry),
  true = Expiry > 0,
  extract_record(Rest, Meta#meta{expiry = Expiry}, Record);

extract_record([{<<"key">>, Key} | Rest], Meta, Record) ->
  true = is_binary(Key),
  extract_record(Rest, Meta, Record#value{key = Key});

extract_record([{<<"sort_key">>, null} | Rest], Meta, Record) ->
  extract_record(Rest, Meta, Record#value{sort_key = undefined});
extract_record([{<<"sort_key">>, SortKey} | Rest], Meta, Record) ->
  true = is_binary(SortKey),
  extract_record(Rest, Meta, Record#value{sort_key = SortKey});

extract_record([{<<"value">>, null} | Rest], Meta, Record) ->
  extract_record(Rest, Meta, Record#value{value = undefined});
extract_record([{<<"value">>, Value} | Rest], Meta, Record) ->
  true = is_binary(Value),
  extract_record(Rest, Meta, Record#value{value = Value});

extract_record([{<<"severity">>, <<"expected">>} | Rest], Meta, Record) ->
  extract_record(Rest, Meta, Record#value{severity = expected});
extract_record([{<<"severity">>, <<"warning">>} | Rest], Meta, Record) ->
  extract_record(Rest, Meta, Record#value{severity = warning});
extract_record([{<<"severity">>, <<"error">>} | Rest], Meta, Record) ->
  extract_record(Rest, Meta, Record#value{severity = error});
extract_record([{<<"severity">>, Severity} | _Rest], _Meta, _Record) ->
  erlang:error({badmatch, Severity}); % any other severity is invalid

extract_record([{<<"info">>, Info} | Rest], Meta, Record) ->
  extract_record(Rest, Meta, Record#value{info = Info});

extract_record([{_Key, _Value} | Rest], Meta, Record) ->
  % skip unknown keys
  extract_record(Rest, Meta, Record).

%%%---------------------------------------------------------------------------
%%% vim:ft=erlang:foldmethod=marker
