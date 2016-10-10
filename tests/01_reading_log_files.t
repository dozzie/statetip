#!/usr/bin/estap
%%
%% Tests for reading and recovering log files.
%% Main focus: `statip_flog:read()' and `statip_flog:recover()' with various
%% data.
%%
%%----------------------------------------------------------------------------

-define(READ_BLOCK, 4096).

%%----------------------------------------------------------------------------

-test("damaged record (invalid checksum) at EOF").
test1() ->
  {ok, H} = open_data("data/record/damaged.eof.flog"),
  estap:error(read_data(H), "first read()"),
  estap:is(recover_data(H), none, "recover()"),
  estap:is(recover_data(H), eof, "recover()"),
  close_data(H),
  estap:all_ok().

-test("damaged record (invalid checksum) in the middle of log file").
test2() ->
  {ok, H} = open_data("data/record/damaged.middle.flog"),
  estap:error(read_data(H), "first read()"),
  estap:ok(recover_data(H), "recover()"),
  estap:is(read_data(H), eof, "last read()"),
  close_data(H),
  estap:all_ok().

-test("incomplete record at EOF").
test3() ->
  {ok, H} = open_data("data/record/incomplete.eof.flog"),
  estap:is(read_data(H), eof, "first read()"),
  estap:is(read_data(H), eof, "second read()"),
  estap:is(recover_data(H), none, "recover()"),
  estap:is(recover_data(H), eof, "recover()"),
  close_data(H),
  estap:all_ok().

-test("incomplete record in the middle of log file").
test4() ->
  {ok, H} = open_data("data/record/incomplete.middle.flog"),
  estap:error(read_data(H), "first read()"),
  estap:ok(recover_data(H), "recover()"),
  estap:is(read_data(H), eof, "last read()"),
  close_data(H),
  estap:all_ok().

-test("too long record at EOF").
test5() ->
  {ok, H} = open_data("data/record/too_long.eof.flog"),
  estap:error(read_data(H), "first read()"),
  % record spans into two read blocks, so two recover() calls move past it and
  % the second one hits EOF
  estap:is(recover_data(H), none, "first recover()"),
  estap:is(recover_data(H), none, "second recover()"),
  estap:is(recover_data(H), eof, "last recover()"),
  estap:is(read_data(H), eof, "last read()"),
  close_data(H),
  estap:all_ok().

-test("too long record in the middle of log file").
test6() ->
  {ok, H} = open_data("data/record/too_long.middle.flog"),
  estap:error(read_data(H), "first read()"),
  % too long record spans into two read blocks, but doesn't exhaust the second
  % block; first recover() doesn't catch the next record, but the second one
  % does
  estap:is(recover_data(H), none, "first recover()"),
  estap:ok(recover_data(H), "second recover()"),
  estap:is(read_data(H), eof, "last read()"),
  close_data(H),
  estap:all_ok().

-test("bogus record (good checksum) at EOF").
test7() ->
  {ok, H} = open_data("data/record/bogus_good.eof.flog"),
  estap:error(read_data(H), "first read()"),
  estap:is(recover_data(H), none, "recover()"),
  estap:is(recover_data(H), eof, "recover()"),
  close_data(H),
  estap:all_ok().

-test("bogus record (good checksum) in the middle of log file").
test8() ->
  {ok, H} = open_data("data/record/bogus_good.middle.flog"),
  estap:error(read_data(H), "first read()"),
  estap:ok(recover_data(H), "recover()"),
  estap:is(read_data(H), eof, "last read()"),
  close_data(H),
  estap:all_ok().

%{ok, H} = open_data("data/record/garbage.large.eof.flog")
%{ok, H} = open_data("data/record/garbage.large.middle.flog")

-test("small (less than read block) garbage at EOF").
test11() ->
  {ok, H} = open_data("data/record/garbage.small.eof.flog"),
  estap:error(read_data(H), "first read()"),
  estap:is(recover_data(H), none, "recover()"),
  estap:is(recover_data(H), eof, "recover()"),
  close_data(H),
  estap:all_ok().

-test("small (less than read block) garbage in the middle of log file").
test12() ->
  {ok, H} = open_data("data/record/garbage.small.middle.flog"),
  estap:error(read_data(H), "first read()"),
  estap:ok(recover_data(H), "recover()"),
  estap:is(read_data(H), eof, "last read()"),
  close_data(H),
  estap:all_ok().

%%----------------------------------------------------------------------------

open_data(File) ->
  {ok, Handle} = statip_flog:open(estap:test_dir(File), [read]),
  {ok, _} = statip_flog:read(Handle, ?READ_BLOCK), % first record is always OK
  {ok, Handle}.

read_data(Handle) ->
  statip_flog:read(Handle, ?READ_BLOCK).

recover_data(Handle) ->
  statip_flog:recover(Handle, ?READ_BLOCK).

close_data(Handle) ->
  statip_flog:close(Handle).

%%----------------------------------------------------------------------------
%% vim:ft=erlang
