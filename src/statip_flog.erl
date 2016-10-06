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
-export([append/5, read/2]).
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
-define(RECORD_HEADER_SIZE, (?RECORD_HEADER_MAGIC_SIZE + 4 + 4)). % +2x 32 bits

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
  {ok, Position} = file:position(FH, cur),
  PrePadding = padding(Position), % in case the previous call was incomplete
  case build_record(Name, Origin, Entry, ValueType) of
    {ok, Data} -> file:write(FH, [PrePadding, Data]);
    {error, Reason} -> {error, Reason}
  end.

%% @doc Read an entry from a log file.

-spec read(handle(), pos_integer()) ->
  {ok, entry()} | eof | {error, Reason}
  when Reason :: write_only | bad_record | file:posix() | badarg.

read({flog_write, _} = _Handle, _ReadBlock) ->
  {error, write_only};
read({flog_read, FH} = _Handle, ReadBlock) ->
  case try_read_record(FH, ReadBlock) of
    {ok, Entry} ->
      {ok, Entry};
    eof ->
      eof;
    {error, bad_record} ->
      % TODO: try to recover
      'TODO';
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

%%%---------------------------------------------------------------------------
%%% reading from file handle

%%----------------------------------------------------------
%% try_read_record() {{{

%% @doc Try reading a log entry from opened file.
%%
%%   Incomplete record at end of the file is reported simply as `eof', with
%%   file position being set at the beginning of the record.
%%
%%   Damaged record is reported as `{error, bad_record}', with file position
%%   being set at the beginning of the record.

-spec try_read_record(file:io_device(), pos_integer()) ->
  {ok, entry()} | eof | {error, Reason}
  when Reason :: bad_record | file:posix() | badarg.

try_read_record(FH, ReadBlock) ->
  case read_record_header(FH, ReadBlock) of
    {ok, DataLength, Checksum} ->
      case read_record_body(FH, DataLength, Checksum) of
        {ok, Entry} ->
          {ok, Entry};
        eof ->
          {ok, _} = file:position(FH, {cur, -?RECORD_HEADER_SIZE}),
          eof;
        {error, bad_checksum} ->
          {ok, _} = file:position(FH, {cur, -?RECORD_HEADER_SIZE}),
          {error, bad_record};
        {error, bad_record} -> % record doesn't deserialize
          {ok, _} = file:position(FH, {cur, -?RECORD_HEADER_SIZE}),
          {error, bad_record};
        {error, Reason} ->
          % random read error may also cause seek errors; we don't want to die
          % on those
          _ = file:position(FH, {cur, -?RECORD_HEADER_SIZE}),
          {error, Reason}
      end;
    eof ->
      eof;
    {error, bad_size} -> % `RecordSize > ReadBlock' or `RecordSize rem 8 /= 0'
      {error, bad_record};
    {error, bad_header} -> % invalid magic
      {error, bad_record};
    {error, Reason} ->
      {error, Reason}
  end.

%% }}}
%%----------------------------------------------------------
%% try_read_recover() {{{

%% }}}
%%----------------------------------------------------------
%% read_record_header(), read_record_body() {{{

%% @doc Read record header from file handle.
%%
%%   Incomplete read is returned as EOF, with file position being reset to
%%   just before read try.
%%
%%   Non-read errors (format/size verification) reset file position to just
%%   before read try.

-spec read_record_header(file:io_device(), pos_integer()) ->
  {ok, pos_integer(), integer()} | eof | {error, Reason}
  when Reason :: bad_size | bad_header | file:posix() | badarg.

read_record_header(FH, ReadBlock) ->
  case file_read_exact(FH, ?RECORD_HEADER_SIZE) of
    {ok, Header} ->
      case parse_record_header(Header, ReadBlock) of
        {ok, Length, Checksum} ->
          {ok, Length, Checksum};
        {error, Reason} ->
          {ok, _} = file:position(FH, {cur, -?RECORD_HEADER_SIZE}),
          {error, Reason}
      end;
    eof ->
      eof;
    {error, Reason} ->
      {error, Reason}
  end.

%% @doc Read record body from file handle.
%%
%%   Incomplete read is returned as EOF, with file position being reset to
%%   just before read try (which doesn't cover record's header).
%%
%%   Non-read errors (checksum verification and data deserialization) reset
%%   file position to just before read try (which doesn't cover record's
%%   header).

-spec read_record_body(file:io_device(), pos_integer(), integer()) ->
  {ok, entry()} | eof | {error, Reason}
  when Reason :: bad_checksum | bad_record | file:posix() | badarg.

read_record_body(FH, Length, Checksum) ->
  case file_read_exact(FH, Length) of
    {ok, Data} ->
      case parse_record_body(Data, Checksum) of
        {ok, Entry} ->
          {ok, Entry};
        {error, Reason} ->
          {ok, _} = file:position(FH, {cur, -Length}),
          {error, Reason}
      end;
    eof ->
      eof;
    {error, Reason} ->
      {error, Reason}
  end.

%% }}}
%%----------------------------------------------------------
%% file_read_exact() {{{

%% @doc Read exactly `Size' bytes from a file handle.
%%
%%   If less than `Size' bytes is available, file position is reset to what it
%%   was just before read and `eof' is returned.

-spec file_read_exact(file:io_device(), pos_integer()) ->
  {ok, binary()} | eof | {error, file:posix() | badarg}.

file_read_exact(FH, Size) ->
  case file:read(FH, Size) of
    {ok, Data} when size(Data) == Size ->
      {ok, Data};
    {ok, Data} when size(Data) < Size ->
      {ok, _} = file:position(FH, {cur, -size(Data)}),
      eof;
    eof ->
      eof;
    {error, Reason} ->
      {error, Reason}
  end.

%% }}}
%%----------------------------------------------------------

%%%---------------------------------------------------------------------------
%%% encoding/decoding data

%%----------------------------------------------------------
%% build_record(), padding() {{{

%% @doc Encode log entry for writing to a file.

-spec build_record(statip_value:name(), statip_value:origin(),
                   Entry, single | burst) ->
  {ok, iolist()} | {error, badarg}
  when Entry :: #value{} | clear | {clear, statip_value:key()}.

build_record(Name, Origin, Entry, ValueType) ->
  case encode_log_entry(Name, Origin, Entry, ValueType) of
    {ok, Record} ->
      RecordLength = iolist_size(Record),
      Padding = padding(RecordLength),
      PaddedRecord = [Record, Padding],
      Checksum = erlang:crc32(PaddedRecord),
      Result = [
        ?RECORD_HEADER_MAGIC,
        <<(RecordLength + size(Padding)):32/integer, Checksum:32/integer>> |
        PaddedRecord
      ],
      {ok, Result};
    {error, badarg} ->
      {error, badarg}
  end.

%% @doc Build a binary that pads the specified position to 8.

-spec padding(non_neg_integer()) ->
  binary().

padding(CurrentSize) ->
  PaddingSize = (8 - (CurrentSize rem 8)) rem 8,
  _Padding = binary:part(<<0,0,0,0,0,0,0,0>>, 0, PaddingSize).

%% }}}
%%----------------------------------------------------------
%% parse_record_header(), parse_record_body() {{{

%% @doc Parse header of record out of a binary.
%%
%%   Record length must be less than `ReadBlock', otherwise it's reported as
%%   `{error, bad_size}'.

-spec parse_record_header(binary(), pos_integer()) ->
    {ok, DataSize :: pos_integer(), Checksum :: pos_integer()}
  | {error, bad_size | bad_header}.

parse_record_header(<<Magic:?RECORD_HEADER_MAGIC_SIZE/binary,
                      Length:32/integer, Checksum:32/integer>> = _Header,
                    ReadBlock) ->
  case Magic of
    ?RECORD_HEADER_MAGIC when Length rem 8 == 0, Length =< ReadBlock ->
      {ok, Length, Checksum};
    _ when Length rem 8 /= 0; Length > ReadBlock ->
      {error, bad_size};
    _ ->
      {error, bad_header}
  end.

%% @doc Parse log entry out of a binary.

-spec parse_record_body(binary(), integer()) ->
  {ok, entry()} | {error, bad_checksum | bad_record}.

parse_record_body(Data, Checksum) ->
  case erlang:crc32(Data) of
    Checksum ->
      try decode_log_entry(Data) of
        Entry -> {ok, Entry}
      catch
        _:_ -> {error, bad_record}
      end;
    _ ->
      {error, bad_checksum}
  end.

%% }}}
%%----------------------------------------------------------
%% encode_log_entry() {{{

%% @doc Encode log entry as a binary zero-padded to 8.

-spec encode_log_entry(statip_value:name(), statip_value:origin(),
                       Entry, single | burst) ->
  {ok, iolist()} | {error, badarg}
  when Entry :: #value{} | clear | {clear, statip_value:key()}.

encode_log_entry(Name, Origin, _Entry, ValueType)
when not is_binary(Name);
     Origin /= undefined, not is_binary(Origin);
     ValueType /= single, ValueType /= burst ->
  {error, badarg};
encode_log_entry(Name, Origin, clear = _Entry, _ValueType) ->
  Payload = [?TYPE_CLEAR, store(Name), store(Origin)],
  {ok, Payload};
encode_log_entry(Name, Origin, {clear, Key} = _Entry, _ValueType)
when is_binary(Key) ->
  Payload = [?TYPE_CLEAR_KEY, store(Name), store(Origin), store(Key)],
  {ok, Payload};
encode_log_entry(Name, Origin, Entry = #value{key = Key}, ValueType) ->
  PayloadBody = [
    store(Name), store(Origin), store(Key),
    % TODO: less redundant encoding for `Entry'
    store(term_to_binary(Entry, [{minor_version, 1}, compressed]))
  ],
  case ValueType of
    single -> {ok, [?TYPE_SINGLE | PayloadBody]};
    burst  -> {ok, [?TYPE_BURST  | PayloadBody]}
  end;
encode_log_entry(_Name, _Origin, _Entry, _ValueType) ->
  {error, badarg}.

%% @doc Encode either a binary or atom `undefined' as an iolist.

-spec store(binary() | undefined) ->
  iolist().

store(Data) when is_binary(Data) -> [<<(size(Data)):32>>, Data];
store(undefined = _Data) -> <<0:32>>.

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

%%%---------------------------------------------------------------------------
%%% vim:ft=erlang:foldmethod=marker
