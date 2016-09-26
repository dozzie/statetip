%%%---------------------------------------------------------------------------
%%% @doc
%%%   Event log file.
%%%
%%% @todo Read error recovery
%%% @todo Encoding less redundant than `term_to_binary(#value{})'
%%% @end
%%%---------------------------------------------------------------------------

-module(statip_flog).

%% public interface
-export([open/2, close/1]).
-export([append/5, read/1]).
-export([format_error/1]).

-export_type([handle/0, entry/0]).

%%%---------------------------------------------------------------------------
%%% types {{{

-include("statip_value.hrl").

-type handle() :: {flog_write, file:io_device()}
                | {flog_read, file:io_device()}.

-type entry() ::
    {clear,  statip_value:name(), statip_value:origin()}
  | {clear,  statip_value:name(), statip_value:origin(), statip_value:key()}
  | {single, statip_value:name(), statip_value:origin(), #value{}}
  | {burst,  statip_value:name(), statip_value:origin(), #value{}}.

-define(RECORD_HEADER_MAGIC, <<166,154,184,182,146,161,251,150>>).
-define(RECORD_HEADER_MAGIC_SIZE, 8). % size(?RECORD_HEADER_MAGIC)
-define(RECORD_HEADER_SIZE, ?RECORD_HEADER_MAGIC_SIZE + 4 + 4). % +2x 32 bits

%% XXX: each type needs to be a single character (see `decode_log_entry()')
-define(TYPE_CLEAR,     <<"c">>).
-define(TYPE_CLEAR_KEY, <<"k">>).
-define(TYPE_SINGLE,    <<"s">>).
-define(TYPE_BURST,     <<"b">>).

%%% }}}
%%%---------------------------------------------------------------------------

%%%---------------------------------------------------------------------------
%%% public interface
%%%---------------------------------------------------------------------------

%% @doc Open a log file for reading or writing.

-spec open(file:filename(), [Option]) ->
  {ok, handle()} | {error, file:posix() | badarg | system_limit}
  when Option :: read | write.

open(Filename, [read] = _Mode) ->
  case file:open(Filename, [read, raw, binary]) of
    {ok, Handle}    -> {ok, {flog_read, Handle}};
    {error, Reason} -> {error, Reason}
  end;
open(Filename, [write] = _Mode) ->
  case file:open(Filename, [append, raw]) of
    {ok, Handle}    -> {ok, {flog_write, Handle}};
    {error, Reason} -> {error, Reason}
  end.

%% @doc Close a log file handle.

-spec close(handle()) ->
  ok.

close({flog_read, FH} = _Handle) ->
  file:close(FH),
  ok;
close({flog_write, FH} = _Handle) ->
  file:close(FH),
  ok.

%% @doc Append an entry to a log file opened for writing.

-spec append(handle(), statip_value:name(), statip_value:origin(),
             Entry | [Entry], single | burst) ->
  ok | {error, read_only | file:posix() | badarg}
  when Entry :: #value{} | clear | {clear, statip_value:key()}.

append({flog_read, _} = _Handle, _Name, _Origin, _Entry, _ValueType) ->
  {error, read_only};
append({flog_write, FH} = _Handle, Name, Origin, Entry, ValueType) ->
  case encode_log_entry(Name, Origin, Entry, ValueType) of
    {ok, {DataLength, Data}} ->
      {ok, Position} = file:position(FH, cur),
      PadPrefixLen = 8 - Position rem 8,
      % NOTE: prefix should be 0..7 bytes long, but `PadPrefixLen' is 1..8
      PadPrefix = binary:part(<<0,0,0,0,0,0,0,0>>, 0, PadPrefixLen rem 8),
      Checksum = erlang:crc32(Data),
      file:write(FH, [
        PadPrefix,
        ?RECORD_HEADER_MAGIC,
        <<DataLength:32/integer, Checksum:32/integer>>,
        Data
      ]);
    {error, Reason} ->
      {error, Reason}
  end.

%% @doc Read an entry from a log file.

-spec read(handle()) ->
  {ok, entry()} | eof | {error, Reason}
  when Reason :: write_only
               | bad_record
               | file:posix()
               | badarg.

read({flog_write, _} = _Handle) ->
  {error, write_only};
read({flog_read, FH} = _Handle) ->
  % TODO: on `{eof, N}' move back `N' bytes
  case read_header(FH) of
    {ok, {DataLength, Checksum}} ->
      case read_entry(FH, DataLength, Checksum) of
        {ok, Entry} -> {ok, Entry};
        {eof, _} -> eof;
        {error, Reason} -> {error, Reason}
      end;
    {eof, _} ->
      eof;
    {error, Reason} ->
      {error, Reason}
  end.

%% @doc Describe an error returned by any function from this module.

-spec format_error(term()) ->
  string().

format_error(read_only = _Reason) ->
  "file opened for reading only";
format_error(write_only = _Reason) ->
  "file opened for writing only";
format_error(bad_record = _Reason) ->
  "invalid record in log file";
%format_error(badarg = _Reason) ->
%  "bad argument"; % handled by `file:format_error()'
format_error(Reason) ->
  file:format_error(Reason).

%%----------------------------------------------------------
%% encode_log_entry() {{{

%% @doc Encode log entry as a binary zero-padded to 8.

-spec encode_log_entry(statip_value:name(), statip_value:origin(),
                       Entry, single | burst) ->
  {ok, {Length :: pos_integer(), Data :: iolist()}} | {error, badarg}
  when Entry :: #value{} | clear | {clear, statip_value:key()}.

encode_log_entry(Name, Origin, _Entry, ValueType)
when not is_binary(Name);
     Origin /= undefined, not is_binary(Origin);
     ValueType /= single, ValueType /= burst ->
  {error, badarg};
encode_log_entry(Name, Origin, clear = _Entry, _ValueType) ->
  Payload = [?TYPE_CLEAR, store(Name), store(Origin)],
  {ok, add_padding(Payload)};
encode_log_entry(Name, Origin, {clear, Key} = _Entry, _ValueType)
when is_binary(Key) ->
  Payload = [?TYPE_CLEAR_KEY, store(Name), store(Origin), store(Key)],
  {ok, add_padding(Payload)};
encode_log_entry(Name, Origin, Entry = #value{key = Key}, ValueType) ->
  PayloadBody = [
    store(Name), store(Origin), store(Key),
    % TODO: less redundant encoding for `Entry'
    store(term_to_binary(Entry, [{minor_version, 1}, compressed]))
  ],
  case ValueType of
    single -> {ok, add_padding([?TYPE_SINGLE | PayloadBody])};
    burst  -> {ok, add_padding([?TYPE_BURST  | PayloadBody])}
  end;
encode_log_entry(_Name, _Origin, _Entry, _ValueType) ->
  {error, badarg}.

%% @doc Encode either a binary or atom `undefined' as an iolist.

-spec store(binary() | undefined) ->
  iolist().

store(Data) when is_binary(Data) -> [<<(size(Data)):32>>, Data];
store(undefined = _Data) -> <<0:32>>.

%% @doc Add padding to 8 with zeros to an iolist.

-spec add_padding(iolist()) ->
  {Length :: pos_integer(), Data :: iolist()}.

add_padding(Payload) ->
  Size = iolist_size(Payload),
  case Size rem 8 of
    0 -> {Size, Payload};
    N -> {Size + 8 - N, [Payload, binary:part(<<0,0,0,0,0,0,0,0>>, 0, 8 - N)]}
  end.

%% }}}
%%----------------------------------------------------------
%% decode_log_entry() {{{

%% @doc Decode a log entry from a binary payload.
%%
%%   If anything with decoding goes wrong, the function raises an unspecified
%%   error.

-spec decode_log_entry(binary()) ->
  entry() | no_return().

decode_log_entry(<<Type:1/binary, Data/binary>> = _Payload) ->
  % TODO: check if padding is zeros
  case Type of
    ?TYPE_CLEAR ->
      <<NameLen:32/integer, Name:NameLen/binary,
        OriginLen:32/integer, Origin:OriginLen/binary,
        _Padding/binary>> = Data,
      {clear, Name, null_undefined(Origin)};
    ?TYPE_CLEAR_KEY ->
      <<NameLen:32/integer, Name:NameLen/binary,
        OriginLen:32/integer, Origin:OriginLen/binary,
        KeyLen:32/integer, Key:KeyLen/binary,
        _Padding/binary>> = Data,
      {clear, Name, null_undefined(Origin), Key};
    ?TYPE_SINGLE ->
      <<NameLen:32/integer, Name:NameLen/binary,
        OriginLen:32/integer, Origin:OriginLen/binary,
        KeyLen:32/integer, _Key:KeyLen/binary,
        TermLen:32/integer, TermBin:TermLen/binary,
        _Padding/binary>> = Data,
      Record = binary_to_term(TermBin, [safe]), % TODO: change the encoding
      {single, Name, null_undefined(Origin), Record};
    ?TYPE_BURST ->
      <<NameLen:32/integer, Name:NameLen/binary,
        OriginLen:32/integer, Origin:OriginLen/binary,
        KeyLen:32/integer, _Key:KeyLen/binary,
        TermLen:32/integer, TermBin:TermLen/binary,
        _Padding/binary>> = Data,
      Record = binary_to_term(TermBin, [safe]), % TODO: change the encoding
      {burst, Name, null_undefined(Origin), Record}
  end.

%% @doc Convert an empty binary to `undefined', leaving non-empty binaries
%%   intact. This decodes "origin" field from log.

null_undefined(<<>>) -> undefined;
null_undefined(Bin) -> Bin.

%% }}}
%%----------------------------------------------------------
%% read_header(), read_entry() {{{

%% @doc Read an entry header (magic, payload length, checksum) from a file.
%%
%% @see read_entry/3

-spec read_header(file:io_device()) ->
    {ok, {Length :: pos_integer(), Checksum :: integer()}}
  | {eof, ReadSize :: non_neg_integer()}
  | {error, Reason}
  when Reason :: bad_record | file:posix() | badarg.

read_header(FH) ->
  case file:read(FH, ?RECORD_HEADER_SIZE) of
    {ok, <<Header:?RECORD_HEADER_MAGIC_SIZE/binary, Length:32/integer,
           Checksum:32/integer>>} when Header == ?RECORD_HEADER_MAGIC ->
      {ok, {Length, Checksum}};
    {ok, Data} when size(Data) == ?RECORD_HEADER_SIZE ->
      % TODO: find next valid record?
      {error, bad_record};
    {ok, Data} when size(Data) < ?RECORD_HEADER_SIZE ->
      {eof, size(Data)};
    eof ->
      {eof, 0};
    {error, Reason} ->
      {error, Reason}
  end.

%% @doc Read an entry body, checking the checksum read from header.
%%
%% @see read_header/1

-spec read_entry(file:io_device(), pos_integer(), integer()) ->
    {ok, entry()}
  | {eof, ReadSize :: non_neg_integer()}
  | {error, Reason}
  when Reason :: bad_record | file:posix() | badarg.

read_entry(FH, DataLength, Checksum) ->
  case file:read(FH, DataLength) of
    {ok, Data} when size(Data) == DataLength ->
      case erlang:crc32(Data) of
        Checksum ->
          try decode_log_entry(Data) of
            Entry -> {ok, Entry}
          catch
            _:_ -> {error, bad_record}
          end;
        _ ->
          {error, bad_record}
      end;
    {ok, Data} when size(Data) < DataLength ->
      {eof, size(Data)};
    eof ->
      {eof, 0};
    {error, Reason} ->
      {error, Reason}
  end.

%% }}}
%%----------------------------------------------------------

%%%---------------------------------------------------------------------------
%%% vim:ft=erlang:foldmethod=marker
