%%%---------------------------------------------------------------------------
%%% @doc
%%%   Event log file.
%%%
%%% @todo Encoding less redundant than `term_to_binary(#value{})'
%%% @todo Document that read block size should be divisible by 8
%%% @end
%%%---------------------------------------------------------------------------

-module(statip_flog).

%% public interface
-export([open/2, close/1]).
-export([append/5, read/2, recover/2]).
-export([format_error/1]).

-export_type([handle/0, entry/0]).

-on_load(load_required_atoms/0).

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

%% XXX: magic should be a sequence of unique bytes
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
%%
%%   Incomplete record at the end of the file is reported simply as `eof',
%%   with file position being set at the beginning of the record.
%%
%%   Damaged record is reported as `{error, bad_record}', with file position
%%   being set at the beginning of the record.
%%
%% @see recover/2

-spec read(handle(), pos_integer()) ->
  {ok, entry()} | eof | {error, Reason}
  when Reason :: write_only | bad_record | file:posix() | badarg.

read({flog_write, _} = _Handle, _ReadBlock) ->
  {error, write_only};
read({flog_read, FH} = _Handle, ReadBlock) ->
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

%% @doc Function that tries to find next valid record after {@link read/2}
%%   error.
%%
%%   On success, file position is set to just after the record. When no valid
%%   record was found, the file position is advanced by `ReadBlock' or to the
%%   end of file.

-spec recover(handle(), pos_integer()) ->
  {ok, entry()} | none | eof | {error, write_only | file:posix() | badarg}.

recover({flog_write, _} = _Handle, _ReadBlock) ->
  {error, write_only};
recover({flog_read, FH} = _Handle, ReadBlock) ->
  % near-EOF reads or `ReadBlock' not divisible by 8 could have caused
  % misalignment; go back a little if necessary
  case file:position(FH, cur) of
    {ok, Position} when Position rem 8 == 0 -> ok;
    {ok, Pos} -> {ok, Position} = file:position(FH, {cur, -(Pos rem 8)})
  end,
  case file:read(FH, ReadBlock) of
    {ok, Data} ->
      RecordCandidates = [
        Offset ||
        {Offset, _Length} <- binary:matches(Data, ?RECORD_HEADER_MAGIC),
        Offset rem 8 == 0
      ],
      case find_record(RecordCandidates, ReadBlock, FH, Position) of
        {ok, Entry} ->
          {ok, Entry};
        none when size(Data) == ReadBlock ->
          % position uncertain, as `find_record()' could have called `read()'
          {ok, _} = file:position(FH, {bof, Position + size(Data)}),
          none;
        none when size(Data) < ReadBlock ->
          % position uncertain, as `find_record()' could have called `read()'
          {ok, _} = file:position(FH, {bof, Position + size(Data)}),
          % `file:read()' hit EOF while reading the block
          eof;
        {error, Reason} ->
          % there could have been reads; read error may mean the seek will
          % also fail, so ignore its status
          _ = file:position(FH, {bof, Position + size(Data)}),
          {error, Reason}
      end;
    eof ->
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

%%%---------------------------------------------------------------------------
%%% reading from file handle

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
%% find_record() {{{

%% @doc Try reading a record from each of the specified offsets, stopping at
%%   the first success.

-spec find_record([non_neg_integer()], pos_integer(), file:io_device(),
                  non_neg_integer()) ->
  {ok, entry()} | none | {error, file:posix() | badarg}.

find_record([] = _Candidates, _ReadBlock, _FH, _ReadStart) ->
  none;
find_record([Offset | Rest] = _Candidates, ReadBlock, FH, ReadStart) ->
  {ok, _} = file:position(FH, {bof, ReadStart + Offset}),
  case read({flog_read, FH}, ReadBlock) of
    {ok, Entry} ->
      {ok, Entry};
    eof ->
      % there could be a shorter valid entry after this place, so don't
      % give up just yet!
      find_record(Rest, ReadBlock, FH, ReadStart);
    {error, bad_record} ->
      find_record(Rest, ReadBlock, FH, ReadStart);
    {error, Reason} ->
      % file read error interrupts the search
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

%% @doc Encode log entry as a binary.

-spec encode_log_entry(statip_value:name(), statip_value:origin(),
                       Entry, single | burst) ->
  {ok, iolist()} | {error, badarg}
  when Entry :: #value{} | clear | {clear, statip_value:key()}.

encode_log_entry(Name, Origin, _Entry, ValueType)
when not is_binary(Name);
     Origin /= undefined, not is_binary(Origin);
     ValueType /= single, ValueType /= burst ->
  {error, badarg};
encode_log_entry(_Name, _Origin, {clear, _Key} = _Entry, burst = _ValueType) ->
  {error, badarg}; % operation not expected for burst values
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

%% @doc Load all atoms that can be stored in records in log file.
%%
%%   This prevents {@link read/2} from failing mysteriously on an otherwise
%%   completely good record when Erlang is started in interactive mode.

load_required_atoms() ->
  required_atoms(),
  ok.

required_atoms() ->
  _Required = [
    {severity, [expected, warning, critical]},
    {info, [null]}
  ].

%%%---------------------------------------------------------------------------
%%% vim:ft=erlang:foldmethod=marker