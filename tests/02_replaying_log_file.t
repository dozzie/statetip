#!/usr/bin/estap
%%
%% Writing and replaying log files.
%%
%%----------------------------------------------------------------------------

-include("statip_value.hrl").

-define(READ_BLOCK, 4096).
-define(REPLAY_RETRIES, 3).

%%----------------------------------------------------------------------------

-test("unrelated values group").
test_unrelated() ->
  File = "data/replay/unrelated.flog",
  ok = write_file(File, [
    {unrelated, "sequence", undefined, record("1.one")},
    {unrelated, "sequence", undefined, record("2.two")},
    {unrelated, "sequence", undefined, record("3.three")}
  ]),
  Expected = [
    {unrelated, "sequence", undefined, "1.one", undefined},
    {unrelated, "sequence", undefined, "2.two", undefined},
    {unrelated, "sequence", undefined, "3.three", undefined}
  ],
  estap:eq(replay_file(File), Expected, "replay"),
  estap:all_ok().

-test("related values group").
test_related() ->
  File = "data/replay/related.flog",
  ok = write_file(File, [
    {related, "sequence", undefined, record("1.one")},
    {related, "sequence", undefined, record("2.two")},
    {related, "sequence", undefined, record("3.three")}
  ]),
  Expected = [
    {related, "sequence", undefined, "1.one", undefined},
    {related, "sequence", undefined, "2.two", undefined},
    {related, "sequence", undefined, "3.three", undefined}
  ],
  estap:eq(replay_file(File), Expected, "replay"),
  estap:all_ok().

-test("unrelated A, unrelated A.1'").
test_unrelated_replace() ->
  File = "data/replay/unrelated_replace.flog",
  ok = write_file(File, [
    {unrelated, "sequence", undefined, record("1.one", "first")},
    {unrelated, "sequence", undefined, record("2.two", "second")},
    {unrelated, "sequence", undefined, record("3.three", "third")},
    {unrelated, "sequence", undefined, record("2.two", "fourth")}
  ]),
  Expected = [
    {unrelated, "sequence", undefined, "1.one", "first"},
    {unrelated, "sequence", undefined, "2.two", "fourth"},
    {unrelated, "sequence", undefined, "3.three", "third"}
  ],
  estap:eq(replay_file(File), Expected, "replay"),
  estap:all_ok().

-test("related A, related A.1'").
test_related_replace() ->
  File = "data/replay/related_replace.flog",
  ok = write_file(File, [
    {related, "sequence", undefined, record("1.one", "first")},
    {related, "sequence", undefined, record("2.two", "second")},
    {related, "sequence", undefined, record("3.three", "third")},
    {related, "sequence", undefined, record("2.two", "fourth")}
  ]),
  Expected = [
    {related, "sequence", undefined, "1.one", "first"},
    {related, "sequence", undefined, "2.two", "fourth"},
    {related, "sequence", undefined, "3.three", "third"}
  ],
  estap:eq(replay_file(File), Expected, "replay"),
  estap:all_ok().

-test("unrelated, clear, unrelated").
test_unrelated_clear_unrelated() ->
  File = "data/replay/unrelated_clear_unrelated.flog",
  ok = write_file(File, [
    {unrelated, "sequence", undefined, record("u1.one")},
    {unrelated, "sequence", undefined, record("u2.two")},
    {clear, "sequence", undefined},
    {unrelated, "sequence", undefined, record("u3.three")},
    {unrelated, "sequence", undefined, record("u4.four")}
  ]),
  Expected = [
    {unrelated, "sequence", undefined, "u3.three", undefined},
    {unrelated, "sequence", undefined, "u4.four", undefined}
  ],
  estap:eq(replay_file(File), Expected, "replay"),
  estap:all_ok().

-test("related, clear, related").
test_related_clear_related() ->
  File = "data/replay/related_clear_related.flog",
  ok = write_file(File, [
    {related, "sequence", undefined, record("r1.one")},
    {related, "sequence", undefined, record("r2.two")},
    {clear, "sequence", undefined},
    {related, "sequence", undefined, record("r3.three")},
    {related, "sequence", undefined, record("r4.four")}
  ]),
  Expected = [
    {related, "sequence", undefined, "r3.three", undefined},
    {related, "sequence", undefined, "r4.four", undefined}
  ],
  estap:eq(replay_file(File), Expected, "replay"),
  estap:all_ok().

-test("unrelated, clear, related").
test_unrelated_clear_related() ->
  File = "data/replay/unrelated_clear_related.flog",
  ok = write_file(File, [
    {unrelated, "sequence", undefined, record("u1.one")},
    {unrelated, "sequence", undefined, record("u2.two")},
    {clear, "sequence", undefined},
    {related, "sequence", undefined, record("r1.one")},
    {related, "sequence", undefined, record("r2.two")},
    {related, "sequence", undefined, record("r3.three")}
  ]),
  Expected = [
    {related, "sequence", undefined, "r1.one", undefined},
    {related, "sequence", undefined, "r2.two", undefined},
    {related, "sequence", undefined, "r3.three", undefined}
  ],
  estap:eq(replay_file(File), Expected, "replay"),
  estap:all_ok().

-test("related, clear, unrelated").
test_related_clear_unrelated() ->
  File = "data/replay/related_clear_unrelated.flog",
  ok = write_file(File, [
    {related, "sequence", undefined, record("r1.one")},
    {related, "sequence", undefined, record("r2.two")},
    {clear, "sequence", undefined},
    {unrelated, "sequence", undefined, record("u1.one")},
    {unrelated, "sequence", undefined, record("u2.two")}
  ]),
  Expected = [
    {unrelated, "sequence", undefined, "u1.one", undefined},
    {unrelated, "sequence", undefined, "u2.two", undefined}
  ],
  estap:eq(replay_file(File), Expected, "replay"),
  estap:all_ok().

-test("related, rotate, related (replace key)").
test_related_rotate_related_replace() ->
  File = "data/replay/related_rotate_related_replace.flog",
  ok = write_file(File, [
    {related, "sequence", undefined, record("1.one", "value-1")},
    {related, "sequence", undefined, record("2.two", "value-2")},
    {rotate, "sequence", undefined},
    {related, "sequence", undefined, record("1.one", "value-3")}
  ]),
  Expected = [
    {related, "sequence", undefined, "1.one", "value-3"},
    {related, "sequence", undefined, "2.two", "value-2"}
  ],
  estap:eq(replay_file(File), Expected, "replay"),
  estap:all_ok().

-test("related, rotate, related (add key)").
test_related_rotate_related_add() ->
  File = "data/replay/related_rotate_related_add.flog",
  ok = write_file(File, [
    {related, "sequence", undefined, record("1.one", "value-1")},
    {related, "sequence", undefined, record("2.two", "value-2")},
    {rotate, "sequence", undefined},
    {related, "sequence", undefined, record("3.three", "value-3")}
  ]),
  Expected = [
    {related, "sequence", undefined, "1.one", "value-1"},
    {related, "sequence", undefined, "2.two", "value-2"},
    {related, "sequence", undefined, "3.three", "value-3"}
  ],
  estap:eq(replay_file(File), Expected, "replay"),
  estap:all_ok().

-test("related, rotate, rotate").
test_related_rotate_rotate() ->
  File = "data/replay/related_rotate_rotate.flog",
  ok = write_file(File, [
    {related, "sequence", undefined, record("r1.one")},
    {related, "sequence", undefined, record("r2.two")},
    {rotate, "sequence", undefined},
    {rotate, "sequence", undefined}
  ]),
  Expected = [
    % empty
  ],
  estap:eq(replay_file(File), Expected, "replay"),
  estap:all_ok().

-test("unrelated A, related B").
test_unrelated_related() ->
  File = "data/replay/unrelated_related.flog",
  ok = write_file(File, [
    {unrelated, "seqA", undefined, record("u1.one")},
    {unrelated, "seqA", undefined, record("u2.two")},
    {related, "seqB", undefined, record("r1.one")},
    {related, "seqB", undefined, record("r2.two")}
  ]),
  Expected = [
    % NOTE: {related,...} < {unrelated,...}
    {related, "seqB", undefined, "r1.one", undefined},
    {related, "seqB", undefined, "r2.two", undefined},
    {unrelated, "seqA", undefined, "u1.one", undefined},
    {unrelated, "seqA", undefined, "u2.two", undefined}
  ],
  estap:eq(replay_file(File), Expected, "replay"),
  estap:all_ok().

-test("unrelated A, related B, rotate B").
test_unrelated_related_rotate() ->
  File = "data/replay/unrelated_related_rotate.flog",
  ok = write_file(File, [
    {unrelated, "seqA", undefined, record("u1.one")},
    {unrelated, "seqA", undefined, record("u2.two")},
    {related, "seqB", undefined, record("r1.one")},
    {related, "seqB", undefined, record("r2.two")},
    {rotate, "seqB", undefined}
  ]),
  Expected = [
    % NOTE: {related,...} < {unrelated,...}
    {related, "seqB", undefined, "r1.one", undefined},
    {related, "seqB", undefined, "r2.two", undefined},
    {unrelated, "seqA", undefined, "u1.one", undefined},
    {unrelated, "seqA", undefined, "u2.two", undefined}
  ],
  estap:eq(replay_file(File), Expected, "replay"),
  estap:all_ok().

-test("unrelated A, clear A.1").
test_unrelated_clear_part() ->
  File = "data/replay/unrelated_clear_part.flog",
  ok = write_file(File, [
    {unrelated, "sequence", undefined, record("1.one")},
    {unrelated, "sequence", undefined, record("2.two")},
    {unrelated, "sequence", undefined, record("3.three")},
    {clear, "sequence", undefined, "2.two"}
  ]),
  Expected = [
    {unrelated, "sequence", undefined, "1.one", undefined},
    {unrelated, "sequence", undefined, "3.three", undefined}
  ],
  estap:eq(replay_file(File), Expected, "replay"),
  estap:all_ok().

-test("unrelated A, clear A.nx").
test_unrelated_clear_nx_part() ->
  File = "data/replay/unrelated_clear_part.flog",
  ok = write_file(File, [
    {unrelated, "sequence", undefined, record("1.one")},
    {unrelated, "sequence", undefined, record("2.two")},
    {unrelated, "sequence", undefined, record("3.three")},
    {clear, "sequence", undefined, "4.four"}
  ]),
  Expected = [
    {unrelated, "sequence", undefined, "1.one", undefined},
    {unrelated, "sequence", undefined, "2.two", undefined},
    {unrelated, "sequence", undefined, "3.three", undefined}
  ],
  estap:eq(replay_file(File), Expected, "replay"),
  estap:all_ok().

-test("unrelated A, related A").
test_unrelated_related_ignored() ->
  File = "data/replay/unrelated_related_ignored.flog",
  ok = write_file(File, [
    {unrelated, "sequence", undefined, record("1.one")},
    {unrelated, "sequence", undefined, record("2.two")},
    {unrelated, "sequence", undefined, record("3.three")},
    {related, "sequence", undefined, record("4.four")}
  ]),
  Expected = [
    {unrelated, "sequence", undefined, "1.one", undefined},
    {unrelated, "sequence", undefined, "2.two", undefined},
    {unrelated, "sequence", undefined, "3.three", undefined}
  ],
  estap:eq(replay_file(File), Expected, "replay"),
  estap:all_ok().

-test("related A, unrelated A").
test_related_unrelated_ignored() ->
  File = "data/replay/related_unrelated_ignored.flog",
  ok = write_file(File, [
    {related, "sequence", undefined, record("1.one")},
    {related, "sequence", undefined, record("2.two")},
    {related, "sequence", undefined, record("3.three")},
    {unrelated, "sequence", undefined, record("4.four")}
  ]),
  Expected = [
    {related, "sequence", undefined, "1.one", undefined},
    {related, "sequence", undefined, "2.two", undefined},
    {related, "sequence", undefined, "3.three", undefined}
  ],
  estap:eq(replay_file(File), Expected, "replay"),
  estap:all_ok().

-test("unrelated, rotate").
test_unrelated_rotate() ->
  File = "data/replay/unrelated_rotate.flog",
  ok = write_file(File, [
    {unrelated, "sequence", undefined, record("1.one")},
    {unrelated, "sequence", undefined, record("2.two")},
    {unrelated, "sequence", undefined, record("3.three")},
    {rotate, "sequence", undefined}
  ]),
  Expected = [
    {unrelated, "sequence", undefined, "1.one", undefined},
    {unrelated, "sequence", undefined, "2.two", undefined},
    {unrelated, "sequence", undefined, "3.three", undefined}
  ],
  estap:eq(replay_file(File), Expected, "replay"),
  estap:all_ok().

%%----------------------------------------------------------------------------

replay_file(File) ->
  case statip_flog:open(estap:test_dir(File), [read]) of
    {ok, FH} ->
      {ok, Recs} = statip_flog:replay(FH, ?READ_BLOCK, ?REPLAY_RETRIES),
      statip_flog:close(FH),
      Result = statip_flog:fold(fun replay_fold_fun/4, [], Recs),
      lists:sort(lists:flatten(Result));
    {error, Reason} ->
      estap:bail_out([
        "open(", File, ") error: ",
        estap:explain({error, Reason})
      ])
  end.

replay_fold_fun({Name, Origin}, Type, Records, Acc) ->
  Rs = [
    {Type, decode(Name), decode(Origin), decode(Key), decode(State)} ||
    #value{key = Key, state = State} <- Records
  ],
  [Rs | Acc].

write_file(File, Records) ->
  _ = file:delete(estap:test_dir(File)),
  case statip_flog:open(estap:test_dir(File), [write]) of
    {ok, Handle} ->
      lists:foreach(fun(Args) -> ok = append(Handle, Args) end, Records),
      ok = statip_flog:close(Handle),
      ok;
    {error, Reason} ->
      estap:bail_out([
        "open(", File, ") error: ",
        estap:explain({error, Reason})
      ])
  end.

append(Handle, {clear, Name, Origin}) ->
  % type doesn't matter, as long as it makes sense for this record
  statip_flog:append(Handle, encode(Name), encode(Origin), clear, related);
append(Handle, {clear, Name, Origin, Key}) ->
  % type doesn't matter, as long as it makes sense for this record
  statip_flog:append(Handle, encode(Name), encode(Origin),
                     {clear, encode(Key)}, unrelated);
append(Handle, {unrelated, Name, Origin, Entry = #value{}}) ->
  statip_flog:append(Handle, encode(Name), encode(Origin), Entry, unrelated);
append(Handle, {related, Name, Origin, Entry = #value{}}) ->
  statip_flog:append(Handle, encode(Name), encode(Origin), Entry, related);
append(Handle, {rotate, Name, Origin}) ->
  statip_flog:append(Handle, encode(Name), encode(Origin), rotate, related).

%%----------------------------------------------------------------------------

record(Key) ->
  record(Key, undefined).

record(Key, State) ->
  record(Key, State, 0).

record(Key, State, TimeOffset) ->
  #value{
    key = encode(Key),
    state = encode(State),
    created = timestamp(TimeOffset),
    expires = timestamp(TimeOffset) + 90
  }.

timestamp(Offset) ->
  1234567890 + Offset.

encode(undefined = _V) -> undefined;
encode(V) when is_list(V) -> list_to_binary(V);
encode(V) when is_atom(V) -> atom_to_binary(V, utf8);
encode(V) when is_binary(V) -> V.

decode(undefined = _V) -> undefined;
decode(V) when is_binary(V) -> binary_to_list(V).

%%----------------------------------------------------------------------------
%% vim:ft=erlang:foldmethod=marker
