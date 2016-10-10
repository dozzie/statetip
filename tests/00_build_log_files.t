#!/usr/bin/estap
%%
%% Data preparation for log file reading. Additionally some tests for writing
%% log files.
%%
%% TODO: hardcode "small garbage" data
%% TODO: write all the possible record entries
%% TODO: write a longer record sequence that can be replayed
%%
%%----------------------------------------------------------------------------

-define(READ_BLOCK, 4096).

%%----------------------------------------------------------------------------

-test("write several good records").
test_all_good() ->
  write_record("data/record/all_good.flog", [
    fun append_good/1,
    fun append_good/1
  ]).

-test("write a damaged record at EOF").
test_damaged_eof() ->
  write_record("data/record/damaged.eof.flog", [
    fun append_good/1,
    fun append_damaged/1
  ]).

-test("write damaged record in the middle of log file").
test_damaged_middle() ->
  write_record("data/record/damaged.middle.flog", [
    fun append_good/1,
    fun append_damaged/1,
    fun append_good/1
  ]).

-test("write incomplete record at EOF").
test_incomplete_eof() ->
  write_record("data/record/incomplete.eof.flog", [
    fun append_good/1,
    fun append_incomplete/1
  ]).

-test("write incomplete record in the middle of log file").
test_incomplete_middle() ->
  write_record("data/record/incomplete.middle.flog", [
    fun append_good/1,
    fun append_incomplete/1,
    fun append_good/1
  ]).

-test("write too long record at EOF").
test_too_long_eof() ->
  write_record("data/record/too_long.eof.flog", [
    fun append_good/1,
    fun append_too_long/1
  ]).

-test("write too long record in the middle of log file").
test_too_long_middle() ->
  write_record("data/record/too_long.middle.flog", [
    fun append_good/1,
    fun append_too_long/1,
    fun append_good/1
  ]).

-test("write bogus record with good checksum at EOF").
test_bogus_eof() ->
  write_record("data/record/bogus_good.eof.flog", [
    fun append_good/1,
    fun append_bogus_good/1
  ]).

-test("write bogus record with good checksum in the middle of log file").
test_bogus_middle() ->
  write_record("data/record/bogus_good.middle.flog", [
    fun append_good/1,
    fun append_bogus_good/1,
    fun append_good/1
  ]).

-test("write large (> ?READ_BLOCK) garbage at EOF").
test_garbage_large_eof() ->
  write_record("data/record/garbage.large.eof.flog", [
    fun append_good/1,
    fun append_garbage/1,
    fun append_garbage/1,
    fun append_garbage/1
  ]).

-test("write large (> ?READ_BLOCK) garbage in the middle of log file").
test_garbage_large_middle() ->
  write_record("data/record/garbage.large.middle.flog", [
    fun append_good/1,
    fun append_garbage/1,
    fun append_garbage/1,
    fun append_garbage/1,
    fun append_good/1
  ]).

-test("write small (< ?READ_BLOCK) garbage at EOF").
test_garbage_small_eof() ->
  write_record("data/record/garbage.small.eof.flog", [
    fun append_good/1,
    fun append_garbage/1
  ]).

-test("write small (< ?READ_BLOCK) garbage in the middle of log file").
test_garbage_small_middle() ->
  write_record("data/record/garbage.small.middle.flog", [
    fun append_good/1,
    fun append_garbage/1,
    fun append_good/1
  ]).

%%----------------------------------------------------------------------------

write_record(File, Functions) ->
  _ = file:delete(estap:test_dir(File)),
  estap:plan(length(Functions)),
  case statip_flog:open(estap:test_dir(File), [write]) of
    {ok, Handle} ->
      lists:foreach(fun(F) -> estap:ok(F(Handle), "append") end, Functions),
      ok = statip_flog:close(Handle),
      estap:all_ok();
    {error, Reason} ->
      estap:bail_out([
        "open(", File, ") error: ",
        estap:explain({error, Reason})
      ])
  end.

%%----------------------------------------------------------------------------
%% appending records, valid and damaged {{{

append_bogus_good({flog_write, FH} = _Handle) ->
  % XXX: 8-aligned
  BogusPayload = <<
    196, 124, 174, 236, 249, 134, 200,  48,
    210, 214,  57, 104,  21, 193, 110,  70,
    246, 130, 187, 211,  72, 180,  92, 130
  >>,
  BogusPayloadLength = size(BogusPayload),
  Checksum = erlang:crc32(BogusPayload),
  ok = file:write(FH, [
    <<166,154,184,182,146,161,251,150>>, % XXX: record header magic
    <<BogusPayloadLength:32/integer, Checksum:32/integer>>,
    BogusPayload
  ]).

append_garbage({flog_write, FH} = _Handle) ->
  % small garbage, less than ?READ_BLOCK, 8-aligned
  % XXX: assume that it's impossible for this to generate a valid record
  ok = file:write(FH, crypto:rand_bytes(?READ_BLOCK div 2)).

append_damaged({flog_write, FH} = _Handle) ->
  % should be less bytes than an example record has
  DamagePattern = <<37,86,94,72,10,85,1,136,221,175>>,
  Record = valid_record_content(),
  ok = file:write(FH, [
    binary:part(Record, 0, size(Record) - size(DamagePattern)),
    DamagePattern
  ]).

valid_record_content() ->
  % XXX: no public API for raw record data and file opened in append mode,
  % which makes it unseekable for writing purposes, so a temporary file is
  % required
  {ok, Handle} = statip_flog:open("_generate.tmp", [write]),
  ok = append_good(Handle),
  ok = statip_flog:close(Handle),
  {ok, Record} = file:read_file("_generate.tmp"),
  file:delete("_generate.tmp"),
  Record.

append_incomplete({flog_write, FH} = Handle) ->
  ok = append_good(Handle),
  % XXX: should be less than example record
  {ok,_} = file:position(FH, {cur, -10}),
  ok = file:truncate(FH).

append_too_long(Handle) ->
  % each of these has >10 bytes, so (four of them) * (?READ_BLOCK/40)
  % should exceed ?READ_BLOCK
  % NOTE: I probably should put a really big data in `info' field
  Name   = binary:copy(<<"example_name_">>,   ?READ_BLOCK div 40),
  Origin = binary:copy(<<"example_origin_">>, ?READ_BLOCK div 40),
  Key    = binary:copy(<<"example_key_">>,    ?READ_BLOCK div 40),
  Value  = binary:copy(<<"example_value_">>,  ?READ_BLOCK div 40),
  ok = statip_flog:append(Handle, Name, Origin, record(Key, Value), single).

append_good(Handle) ->
  ok = statip_flog:append(Handle, <<"example_name">>, <<"example_origin">>,
                          record("example_key", "example_value"), single).

%% }}}
%%----------------------------------------------------------------------------
%% building records {{{

-include("statip_value.hrl").

timestamp() ->
  1234567890.

record(Key, Value) when is_list(Key) ->
  record(list_to_binary(Key), Value);
record(Key, Value) when is_list(Value) ->
  record(Key, list_to_binary(Value));
record(Key, Value)
when is_binary(Key), is_binary(Value);
     is_binary(Key), Value == undefined ->
  #value{
    key = Key,
    value = Value,
    created = timestamp(),
    expires = timestamp() + 30
  }.

%% }}}
%%----------------------------------------------------------------------------
%% vim:ft=erlang:foldmethod=marker
