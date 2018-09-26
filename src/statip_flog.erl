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
-export([append/2, read/2, recover/2, file_size/1, position/1]).
-export([replay/3, replay/4, fold/3]).
-export([format_error/1]).

-export_type([handle/0, entry/0]).
-export_type([records/0, mapping/2, related_values/0, unrelated_values/0]).

-on_load(load_required_atoms/0).
-export([load_required_atoms/0]).

%%%---------------------------------------------------------------------------
%%% types {{{

-include("statip_value.hrl").

-type handle() :: {flog_write, file:io_device()}
                | {flog_read, file:io_device()}.
%% Log file handle.

-type entry() ::
    entry_clear_value_group()
  | entry_clear_value()
  | entry_rotate_related_values()
  | entry_value().
%% Record read from log file.

-type entry_clear_value_group() ::
 {clear, statip_value:name(), statip_value:origin()}.

-type entry_clear_value() ::
 {clear, statip_value:name(), statip_value:origin(), statip_value:key()}.

-type entry_rotate_related_values() ::
 {rotate, statip_value:name(), statip_value:origin()}.

-type entry_value() ::
 {related | unrelated, statip_value:name(), statip_value:origin(), #value{}}.

%%----------------------------------------------------------
%% record header on-disk data {{{

%% XXX: magic should be a sequence of unique bytes
-define(RECORD_HEADER_MAGIC, <<166,154,184,182,146,161,251,150>>).
-define(RECORD_HEADER_MAGIC_SIZE, 8). % size(?RECORD_HEADER_MAGIC)
-define(RECORD_HEADER_SIZE, (?RECORD_HEADER_MAGIC_SIZE + 4 + 4)). % +2x 32 bits

%% XXX: each type needs to be a single character (see `decode_log_record()')
-define(TYPE_CLEAR,     <<"c">>).
-define(TYPE_CLEAR_KEY, <<"k">>).
-define(TYPE_UNRELATED, <<"u">>).
-define(TYPE_RELATED,   <<"r">>).
-define(TYPE_RELATED_ROTATE, <<"o">>).

%% }}}
%%----------------------------------------------------------
%% replay()/fold() types {{{

-type records() ::
  mapping({statip_value:name(), statip_value:origin()},
          related_values() | unrelated_values()).
%% A container with records replayed from disk. See {@link replay/3} and
%% {@link fold/3}.

%% @type mapping(Key, Value) = gb_tree().
%%   Generic mapping with keys being of `Key' type and values being of `Value'
%%   type.

-type mapping(_Key, _Value) :: gb_trees:tree().

-type unrelated_values() :: {unrelated, mapping(statip_value:key(), #value{})}.
%% Sub-container for {@type records()}, used for storing group of values of
%% "unrelated" type.

-type related_values() ::
  {related, Current :: mapping(statip_value:key(), #value{}) | none,
            Old     :: mapping(statip_value:key(), #value{}) | none}.
%% Sub-container for {@type records()}, used for storing group of values of
%% "related" type.

%% }}}
%%----------------------------------------------------------

%%% }}}
%%%---------------------------------------------------------------------------

%%%---------------------------------------------------------------------------
%%% public interface
%%%---------------------------------------------------------------------------

%% @doc Open a log file for reading or writing.

-spec open(file:filename(), Options :: [Option]) ->
  {ok, handle()} | {error, file:posix() | badarg | system_limit}
  when Option :: read | write | truncate.

open(Filename, Options) ->
  case open_options(Options, {undefined, false}) of
    {ok, {Mode, Truncate}} ->
      OpenOptions = case Mode of
        read -> [read, raw, binary];
        write -> [append, raw]
      end,
      case file:open(Filename, OpenOptions) of
        {ok, Handle} when Mode == read ->
          {ok, {flog_read, Handle}};
        {ok, Handle} when Mode == write, not Truncate ->
          % initially position is 0, which makes the `file_size()' return
          % wrong size
          file:position(Handle, eof),
          {ok, {flog_write, Handle}};
        {ok, Handle} when Mode == write, Truncate ->
          file:position(Handle, bof),
          ok = file:truncate(Handle),
          {ok, {flog_write, Handle}};
        {error, Reason} ->
          {error, Reason}
      end;
    {error, badarg} ->
      {error, badarg}
  end.

%%----------------------------------------------------------
%% open_options() {{{

%% @doc Extract known options from a proplist.

-spec open_options([term()], {undefined | read | write, boolean()}) ->
    {ok, {Mode :: read | write, Truncate :: boolean()}}
  | {error, badarg}.

open_options([], {undefined = _Mode, _Truncate}) ->
  {error, badarg};
open_options([], {Mode, Truncate}) ->
  {ok, {Mode, Truncate}};
open_options([write | Rest], {_Mode, Truncate}) ->
  open_options(Rest, {write, Truncate});
open_options([read | Rest], {_Mode, Truncate}) ->
  open_options(Rest, {read, Truncate});
open_options([truncate | Rest], {Mode, _Truncate}) ->
  open_options(Rest, {Mode, true});
open_options([_Any | _], {_Mode, _Truncate}) ->
  {error, badarg}.

%% }}}
%%----------------------------------------------------------

%% @doc Close a log file handle.

-spec close(handle()) ->
  ok.

close({flog_read, FH} = _Handle) ->
  file:close(FH),
  ok;
close({flog_write, FH} = _Handle) ->
  file:close(FH),
  ok.

%% @doc Read size of an opened log file.

-spec file_size(handle()) ->
  {ok, non_neg_integer()} | {error, file:posix() | badarg}.

file_size({flog_read, FH} = _Handle) ->
  case file:position(FH, cur) of
    {ok, OldPosition} ->
      {ok, EOFPos} = file:position(FH, eof),
      {ok, _} = file:position(FH, OldPosition),
      {ok, EOFPos};
    {error, Reason} ->
      {error, Reason}
  end;
file_size({flog_write, FH} = _Handle) ->
  case file:position(FH, cur) of
    {ok, Position} -> {ok, Position};
    {error, Reason} -> {error, Reason}
  end.

%% @doc Read current read/write position of an opened log file.

-spec position(handle()) ->
  {ok, non_neg_integer()} | {error, file:posix() | badarg}.

position({flog_read, FH} = _Handle) ->
  file:position(FH, cur);
position({flog_write, FH} = _Handle) ->
  file:position(FH, cur).

%% @doc Append an entry to a log file opened for writing.

-spec append(handle(), entry()) ->
  ok | {error, read_only | file:posix() | badarg}.

append(Handle, {rotate, GroupName, GroupOrigin}) ->
  append(Handle, GroupName, GroupOrigin, rotate, related);
append(Handle, {clear, GroupName, GroupOrigin}) ->
  % NOTE: group type doesn't matter for this record, may be unrelated as well
  append(Handle, GroupName, GroupOrigin, clear, unrelated);
append(Handle, {clear, GroupName, GroupOrigin, Key}) ->
  % NOTE: group type doesn't matter for this record, may be unrelated as well
  append(Handle, GroupName, GroupOrigin, {clear, Key}, unrelated);
append(Handle, {GroupType, GroupName, GroupOrigin, Value})
when GroupType == related; GroupType == unrelated ->
  append(Handle, GroupName, GroupOrigin, Value, GroupType).

%% @doc Workhorse for {@link append/2}.

-spec append(handle(), statip_value:name(), statip_value:origin(), Entry,
             related | unrelated) ->
  ok | {error, read_only | file:posix() | badarg}
  when Entry :: #value{} | rotate | clear | {clear, statip_value:key()}.

append({flog_read, _} = _Handle, _Name, _Origin, _Entry, _GroupType) ->
  {error, read_only};
append({flog_write, FH} = _Handle, Name, Origin, Entry, GroupType) ->
  {ok, Position} = file:position(FH, cur),
  PrePadding = padding(Position), % in case the previous call was incomplete
  case build_record(Name, Origin, Entry, GroupType) of
    {ok, Data} -> file:write(FH, [PrePadding, Data]);
    {error, Reason} -> {error, Reason}
  end.

%% @doc Read a record from a log file.
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

%% @doc Replay records from a log file.
%%
%%   Function returns a sequence of records that represent what should be
%%   present state of remembered values, according to the log.
%%
%%   The log file should start with a valid record, otherwise
%%   `{error,bad_file}' is returned.
%%
%%   Some of the records in the log file can be damaged, in which case
%%   automatic recovery is performed. If no valid record could be found for
%%   `RecoverTries' blocks of `ReadBlock' bytes each, the file is deemed
%%   to be damaged and `{error,damaged_file}' is returned.
%%
%% @see replay/4
%% @see fold/3

-spec replay(handle(), pos_integer(), pos_integer()) ->
  {ok, records()} | {error, Reason}
  when Reason :: write_only | bad_file | damaged_file | file:posix() | badarg.

replay(Handle, ReadBlock, RecoverTries) ->
  State = gb_trees:empty(),
  case read(Handle, ReadBlock) of
    {ok, Entry} ->
      NewState = replay_add_entry(Entry, State),
      replay(Handle, ReadBlock, RecoverTries, NewState);
    eof ->
      {ok, State};
    {error, bad_record} ->
      {error, bad_file};
    {error, Reason} ->
      {error, Reason}
  end.

%% @doc Continue replaying records from a log file.
%%
%% @see replay/3
%% @see fold/3

-spec replay(handle(), pos_integer(), pos_integer(), records()) ->
  {ok, records()} | {error, Reason}
  when Reason :: damaged_file | file:posix() | badarg.

replay(Handle, ReadBlock, RecoverTries, State) ->
  case read(Handle, ReadBlock) of
    {ok, Entry} ->
      NewState = replay_add_entry(Entry, State),
      replay(Handle, ReadBlock, RecoverTries, NewState);
    eof ->
      {ok, State};
    {error, bad_record} ->
      case try_recover(Handle, ReadBlock, RecoverTries) of
        {ok, Entry} ->
          NewState = replay_add_entry(Entry, State),
          replay(Handle, ReadBlock, RecoverTries, NewState);
        eof ->
          {ok, State};
        none ->
          {error, damaged_file};
        {error, Reason} ->
          {error, Reason}
      end;
    {error, Reason} ->
      {error, Reason}
  end.

%% @doc Fold over records replayed from a log file.
%%
%%   Note that unlike {@link lists:foldl/3}, `Fun' is called with a <em>list
%%   of values</em> from the value group (the same name and origin).
%%
%% @see replay/3
%% @see replay/4

-spec fold(Fun, AccIn :: term(), records()) ->
  AccOut :: term()
  when Fun :: fun((Key, Type, Records, Acc :: term()) -> NewAcc :: term()),
       Key :: {statip_value:name(), statip_value:origin()},
       Type :: related | unrelated,
       Records :: [#value{}, ...].

fold(Fun, AccIn, Records) ->
  foreach(Fun, AccIn, gb_trees:iterator(Records)).

%% @doc Describe an error returned by any function from this module.

-spec format_error(term()) ->
  string().

format_error(read_only = _Reason) ->
  "file opened for reading only";
format_error(write_only = _Reason) ->
  "file opened for writing only";
format_error(bad_record = _Reason) ->
  "invalid record in log file";
format_error(bad_file = _Reason) ->
  "log file has invalid format";
format_error(damaged_file = _Reason) ->
  "log file is damaged";
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
                   Entry, related | unrelated) ->
  {ok, iolist()} | {error, badarg}
  when Entry :: #value{} | rotate | clear | {clear, statip_value:key()}.

build_record(Name, Origin, Entry, GroupType) ->
  case encode_log_record(Name, Origin, Entry, GroupType) of
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

%% @doc Parse log record out of a binary.

-spec parse_record_body(binary(), integer()) ->
  {ok, entry()} | {error, bad_checksum | bad_record}.

parse_record_body(Data, Checksum) ->
  case erlang:crc32(Data) of
    Checksum ->
      try decode_log_record(Data) of
        Entry -> {ok, Entry}
      catch
        _:_ -> {error, bad_record}
      end;
    _ ->
      {error, bad_checksum}
  end.

%% }}}
%%----------------------------------------------------------
%% encode_log_record() {{{

%% @doc Encode log entry as a binary.

-spec encode_log_record(statip_value:name(), statip_value:origin(),
                        Entry, related | unrelated) ->
  {ok, iolist()} | {error, badarg}
  when Entry :: #value{} | rotate | clear | {clear, statip_value:key()}.

encode_log_record(Name, Origin, _Entry, GroupType)
when not is_binary(Name);
     Origin /= undefined, not is_binary(Origin);
     GroupType /= related, GroupType /= unrelated ->
  {error, badarg};
encode_log_record(Name, Origin, clear = _Entry, _GroupType) ->
  Payload = [?TYPE_CLEAR, store(Name), store(Origin)],
  {ok, Payload};
encode_log_record(Name, Origin, {clear, Key} = _Entry, _GroupType)
when is_binary(Key) ->
  Payload = [?TYPE_CLEAR_KEY, store(Name), store(Origin), store(Key)],
  {ok, Payload};
encode_log_record(Name, Origin, rotate = _Entry, related = _GroupType) ->
  Payload = [?TYPE_RELATED_ROTATE, store(Name), store(Origin)],
  {ok, Payload};
encode_log_record(Name, Origin, Entry = #value{key = Key}, GroupType) ->
  PayloadBody = [
    store(Name), store(Origin), store(Key),
    % TODO: less redundant encoding for `Entry'
    store(term_to_binary(Entry, [{minor_version, 1}, compressed]))
  ],
  case GroupType of
    unrelated -> {ok, [?TYPE_UNRELATED | PayloadBody]};
    related   -> {ok, [?TYPE_RELATED   | PayloadBody]}
  end;
encode_log_record(_Name, _Origin, _Entry, _GroupType) ->
  {error, badarg}.

%% @doc Encode either a binary or atom `undefined' as an iolist.

-spec store(binary() | undefined) ->
  iolist().

store(Data) when is_binary(Data) -> [<<(size(Data)):32>>, Data];
store(undefined = _Data) -> <<0:32>>.

%% }}}
%%----------------------------------------------------------
%% decode_log_record() {{{

%% @doc Decode a log record from a binary payload.
%%
%%   If anything with decoding goes wrong, the function raises an error.

-spec decode_log_record(binary()) ->
  entry() | no_return().

decode_log_record(<<Type:1/binary, Data/binary>> = _Payload) ->
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
    ?TYPE_RELATED_ROTATE ->
      <<NameLen:32/integer, Name:NameLen/binary,
        OriginLen:32/integer, Origin:OriginLen/binary,
        _Padding/binary>> = Data,
      {rotate, Name, null_undefined(Origin)};
    ?TYPE_UNRELATED ->
      <<NameLen:32/integer, Name:NameLen/binary,
        OriginLen:32/integer, Origin:OriginLen/binary,
        KeyLen:32/integer, _Key:KeyLen/binary,
        TermLen:32/integer, TermBin:TermLen/binary,
        _Padding/binary>> = Data,
      Record = binary_to_term(TermBin, [safe]), % TODO: change the encoding
      {unrelated, Name, null_undefined(Origin), Record};
    ?TYPE_RELATED ->
      <<NameLen:32/integer, Name:NameLen/binary,
        OriginLen:32/integer, Origin:OriginLen/binary,
        KeyLen:32/integer, _Key:KeyLen/binary,
        TermLen:32/integer, TermBin:TermLen/binary,
        _Padding/binary>> = Data,
      Record = binary_to_term(TermBin, [safe]), % TODO: change the encoding
      {related, Name, null_undefined(Origin), Record}
  end.

%% @doc Convert an empty binary to `undefined', leaving non-empty binaries
%%   intact. This decodes "origin" field from log.

null_undefined(<<>>) -> undefined;
null_undefined(Bin) -> Bin.

%% }}}
%%----------------------------------------------------------

%%%---------------------------------------------------------------------------
%%% replay records from file

%%----------------------------------------------------------
%% try_recover() {{{

%% @doc Try recovering a valid record for specified number of blocks.
%%
%% @see recover/2

-spec try_recover(handle(), pos_integer(), pos_integer()) ->
  {ok, entry()} | none | eof | {error, file:posix() | badarg}.

try_recover(_Handle, _ReadBlock, 0 = _RecoverTries) ->
  none;
try_recover(Handle, ReadBlock, RecoverTries) when RecoverTries > 0 ->
  case recover(Handle, ReadBlock) of
    {ok, Entry} -> {ok, Entry};
    eof -> eof;
    none -> try_recover(Handle, ReadBlock, RecoverTries - 1);
    {error, Reason} -> {error, Reason}
  end.

%% }}}
%%----------------------------------------------------------
%% replay_add_entry() {{{

%% @doc Update a sequence of values with a new log entry.

-spec replay_add_entry(entry(), records()) ->
  records().

replay_add_entry({clear, Name, Origin} = _Entry, State) ->
  _NewState = gb_trees:delete_any({Name, Origin}, State);

replay_add_entry({clear, Name, Origin, Key} = _Entry, State) ->
  case gb_trees:lookup({Name, Origin}, State) of
    {value, {unrelated, KeyMap}} ->
      NewKeyMap = gb_trees:delete_any(Key, KeyMap),
      case gb_trees:is_empty(NewKeyMap) of
        true ->
          _NewState = gb_trees:delete({Name, Origin}, State);
        false ->
          NewValue = {unrelated, NewKeyMap},
          _NewState = gb_trees:enter({Name, Origin}, NewValue, State)
      end;
    {value, {related, KeyMap, OldKeyMap}} ->
      % this is not an occurrence that happens naturally, but operator could
      % have requested a specific value be removed
      NewKeyMap = gb_trees:delete_any(Key, KeyMap),
      NewOldKeyMap = gb_trees:delete_any(Key, OldKeyMap),
      case {gb_trees:is_empty(NewKeyMap), gb_trees:is_empty(NewOldKeyMap)} of
        {true, true} ->
          _NewState = gb_trees:delete({Name, Origin}, State);
        {true, false} ->
          NewValue = {related, none, NewOldKeyMap},
          _NewState = gb_trees:enter({Name, Origin}, NewValue, State);
        {false, true} ->
          NewValue = {related, NewKeyMap, none},
          _NewState = gb_trees:enter({Name, Origin}, NewValue, State);
        {false, false} ->
          NewValue = {related, NewKeyMap, NewOldKeyMap},
          _NewState = gb_trees:enter({Name, Origin}, NewValue, State)
      end;
    none ->
      State
  end;

replay_add_entry({rotate, Name, Origin} = _Entry, State) ->
  case gb_trees:lookup({Name, Origin}, State) of
    {value, {unrelated, _KeyMap}} ->
      State; % operation not expected for group of unrelated values
    {value, {related, none = _KeyMap, _OldKeyMap}} ->
      _NewState = gb_trees:delete({Name, Origin}, State);
    {value, {related, KeyMap, _OldKeyMap}} ->
      _NewState = gb_trees:enter({Name, Origin}, {related,none,KeyMap}, State);
    none ->
      State
  end;

replay_add_entry({unrelated, Name, Origin, Value = #value{key = Key}} = _Entry,
                 State) ->
  case gb_trees:lookup({Name, Origin}, State) of
    {value, {unrelated, KeyMap}} ->
      NewKeyMap = gb_trees:enter(Key, Value, KeyMap),
      _NewState = gb_trees:enter({Name, Origin}, {unrelated,NewKeyMap}, State);
    {value, {related, _KeyMap, _OldKeyMap}} ->
      State; % record incompatible with remembered type of value group
    none ->
      NewKeyMap = gb_trees:insert(Key, Value, gb_trees:empty()),
      _NewState = gb_trees:enter({Name, Origin}, {unrelated, NewKeyMap}, State)
  end;

replay_add_entry({related, Name, Origin, Value = #value{key = Key}} = _Entry,
                 State) ->
  case gb_trees:lookup({Name, Origin}, State) of
    {value, {unrelated, _KeyMap}} ->
      State; % record incompatible with remembered type of value group
    {value, {related, KeyMap, OldKeyMap}} ->
      NewKeyMap = case KeyMap of
        none -> gb_trees:insert(Key, Value, gb_trees:empty());
        _    -> gb_trees:enter(Key, Value, KeyMap)
      end,
      NewValue = {related, NewKeyMap, OldKeyMap},
      _NewState = gb_trees:enter({Name, Origin}, NewValue, State);
    none ->
      NewKeyMap = gb_trees:insert(Key, Value, gb_trees:empty()),
      NewValue = {related, NewKeyMap, none},
      _NewState = gb_trees:enter({Name, Origin}, NewValue, State)
  end.

%% }}}
%%----------------------------------------------------------

%%%---------------------------------------------------------------------------
%%% fold() helpers

%%----------------------------------------------------------
%% foreach() {{{

%% @doc Iterate through {@type gb_tree} for {@link fold/3}.

-spec foreach(fun(), term(), gb_trees:iter()) ->
  term().

foreach(Fun, Acc, Iterator) ->
  case gb_trees:next(Iterator) of
    {Key, {unrelated, RecTree}, NewIterator} ->
      Records = gb_trees:values(RecTree),
      NewAcc = Fun(Key, unrelated, Records, Acc),
      foreach(Fun, NewAcc, NewIterator);
    {Key, {related, RecTree, OldRecTree}, NewIterator} ->
      Records = burst_records(RecTree, OldRecTree),
      NewAcc = Fun(Key, related, Records, Acc),
      foreach(Fun, NewAcc, NewIterator);
    none ->
      Acc
  end.

%burst_records(none = _RecTree, none = _OldRecTree) ->
%  []; % should never happen; `replay_add_entry()' guarantees that
burst_records(none = _RecTree, OldRecTree) ->
  gb_trees:values(OldRecTree);
burst_records(RecTree, none = _OldRecTree) ->
  gb_trees:values(RecTree);
burst_records(RecTree, OldRecTree) ->
  _Records = gb_trees:values(RecTree) ++ [
    V ||
    V = #value{key = Key} <- gb_trees:values(OldRecTree),
    not gb_trees:is_defined(Key, RecTree)
  ].

%% }}}
%%----------------------------------------------------------

%%%---------------------------------------------------------------------------

%% @private
%% @doc Load all atoms that can be stored in records in log file.
%%
%%   This prevents {@link read/2} from failing mysteriously on an otherwise
%%   completely good record when Erlang is started in interactive mode.

load_required_atoms() ->
  required_atoms(),
  ok.

required_atoms() ->
  _Required = [
    {severity, [expected, warning, error]},
    {info, [null]}
  ].

%%%---------------------------------------------------------------------------
%%% vim:ft=erlang:foldmethod=marker
