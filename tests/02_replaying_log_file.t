#!/usr/bin/estap
%%
%% Writing and replaying log files.
%%
%%----------------------------------------------------------------------------

-include("statip_value.hrl").

-define(READ_BLOCK, 4096).
-define(REPLAY_RETRIES, 3).

%%----------------------------------------------------------------------------

-test("sequence of single records").
test_single() ->
  File = "data/replay/single.flog",
  ok = write_file(File, [
    {single, "sequence", undefined, record("1.one")},
    {single, "sequence", undefined, record("2.two")},
    {single, "sequence", undefined, record("3.three")}
  ]),
  Expected = [
    {single, "sequence", undefined, "1.one", undefined},
    {single, "sequence", undefined, "2.two", undefined},
    {single, "sequence", undefined, "3.three", undefined}
  ],
  estap:eq(replay_file(File), Expected, "replay"),
  estap:all_ok().

-test("sequence of burst values").
test_burst() ->
  File = "data/replay/burst.flog",
  ok = write_file(File, [
    {burst, "sequence", undefined, record("1.one")},
    {burst, "sequence", undefined, record("2.two")},
    {burst, "sequence", undefined, record("3.three")}
  ]),
  Expected = [
    {burst, "sequence", undefined, "1.one", undefined},
    {burst, "sequence", undefined, "2.two", undefined},
    {burst, "sequence", undefined, "3.three", undefined}
  ],
  estap:eq(replay_file(File), Expected, "replay"),
  estap:all_ok().

-test("single A, single A.1'").
test_single_replace() ->
  File = "data/replay/single-replace.flog",
  ok = write_file(File, [
    {single, "sequence", undefined, record("1.one", "first")},
    {single, "sequence", undefined, record("2.two", "second")},
    {single, "sequence", undefined, record("3.three", "third")},
    {single, "sequence", undefined, record("2.two", "fourth")}
  ]),
  Expected = [
    {single, "sequence", undefined, "1.one", "first"},
    {single, "sequence", undefined, "2.two", "fourth"},
    {single, "sequence", undefined, "3.three", "third"}
  ],
  estap:eq(replay_file(File), Expected, "replay"),
  estap:all_ok().

-test("burst A, burst A.1'").
test_burst_replace() ->
  File = "data/replay/burst-replace.flog",
  ok = write_file(File, [
    {burst, "sequence", undefined, record("1.one", "first")},
    {burst, "sequence", undefined, record("2.two", "second")},
    {burst, "sequence", undefined, record("3.three", "third")},
    {burst, "sequence", undefined, record("2.two", "fourth")}
  ]),
  Expected = [
    {burst, "sequence", undefined, "1.one", "first"},
    {burst, "sequence", undefined, "2.two", "fourth"},
    {burst, "sequence", undefined, "3.three", "third"}
  ],
  estap:eq(replay_file(File), Expected, "replay"),
  estap:all_ok().

-test("single, clear, single").
test_single_clear_single() ->
  File = "data/replay/single_clear_single.flog",
  ok = write_file(File, [
    {single, "sequence", undefined, record("s1.one")},
    {single, "sequence", undefined, record("s2.two")},
    {clear, "sequence", undefined},
    {single, "sequence", undefined, record("s3.three")},
    {single, "sequence", undefined, record("s4.four")}
  ]),
  Expected = [
    {single, "sequence", undefined, "s3.three", undefined},
    {single, "sequence", undefined, "s4.four", undefined}
  ],
  estap:eq(replay_file(File), Expected, "replay"),
  estap:all_ok().

-test("burst, clear, burst").
test_burst_clear_burst() ->
  File = "data/replay/burst_clear_burst.flog",
  ok = write_file(File, [
    {burst, "sequence", undefined, record("b1.one")},
    {burst, "sequence", undefined, record("b2.two")},
    {clear, "sequence", undefined},
    {burst, "sequence", undefined, record("b3.three")},
    {burst, "sequence", undefined, record("b4.four")}
  ]),
  Expected = [
    {burst, "sequence", undefined, "b3.three", undefined},
    {burst, "sequence", undefined, "b4.four", undefined}
  ],
  estap:eq(replay_file(File), Expected, "replay"),
  estap:all_ok().

-test("single, clear, burst").
test_single_clear_burst() ->
  File = "data/replay/single_clear_burst.flog",
  ok = write_file(File, [
    {single, "sequence", undefined, record("s1.one")},
    {single, "sequence", undefined, record("s2.two")},
    {clear, "sequence", undefined},
    {burst, "sequence", undefined, record("b1.one")},
    {burst, "sequence", undefined, record("b2.two")},
    {burst, "sequence", undefined, record("b3.three")}
  ]),
  Expected = [
    {burst, "sequence", undefined, "b1.one", undefined},
    {burst, "sequence", undefined, "b2.two", undefined},
    {burst, "sequence", undefined, "b3.three", undefined}
  ],
  estap:eq(replay_file(File), Expected, "replay"),
  estap:all_ok().

-test("burst, clear, single").
test_burst_clear_single() ->
  File = "data/replay/burst_clear_single.flog",
  ok = write_file(File, [
    {burst, "sequence", undefined, record("b1.one")},
    {burst, "sequence", undefined, record("b2.two")},
    {clear, "sequence", undefined},
    {single, "sequence", undefined, record("s1.one")},
    {single, "sequence", undefined, record("s2.two")}
  ]),
  Expected = [
    {single, "sequence", undefined, "s1.one", undefined},
    {single, "sequence", undefined, "s2.two", undefined}
  ],
  estap:eq(replay_file(File), Expected, "replay"),
  estap:all_ok().

-test("burst, rotate, burst (replace key)").
test_burst_rotate_burst_replace() ->
  File = "data/replay/burst_rotate_burst_replace.flog",
  ok = write_file(File, [
    {burst, "sequence", undefined, record("1.one", "value-1")},
    {burst, "sequence", undefined, record("2.two", "value-2")},
    {rotate, "sequence", undefined},
    {burst, "sequence", undefined, record("1.one", "value-3")}
  ]),
  Expected = [
    {burst, "sequence", undefined, "1.one", "value-3"},
    {burst, "sequence", undefined, "2.two", "value-2"}
  ],
  estap:eq(replay_file(File), Expected, "replay"),
  estap:all_ok().

-test("burst, rotate, burst (add key)").
test_burst_rotate_burst_add() ->
  File = "data/replay/burst_rotate_burst_add.flog",
  ok = write_file(File, [
    {burst, "sequence", undefined, record("1.one", "value-1")},
    {burst, "sequence", undefined, record("2.two", "value-2")},
    {rotate, "sequence", undefined},
    {burst, "sequence", undefined, record("3.three", "value-3")}
  ]),
  Expected = [
    {burst, "sequence", undefined, "1.one", "value-1"},
    {burst, "sequence", undefined, "2.two", "value-2"},
    {burst, "sequence", undefined, "3.three", "value-3"}
  ],
  estap:eq(replay_file(File), Expected, "replay"),
  estap:all_ok().

-test("burst, rotate, rotate").
test_burst_rotate_rotate() ->
  File = "data/replay/burst_rotate_rotate.flog",
  ok = write_file(File, [
    {burst, "sequence", undefined, record("b1.one")},
    {burst, "sequence", undefined, record("b2.two")},
    {rotate, "sequence", undefined},
    {rotate, "sequence", undefined}
  ]),
  Expected = [
    % empty
  ],
  estap:eq(replay_file(File), Expected, "replay"),
  estap:all_ok().

-test("single A, burst B").
test_single_burst() ->
  File = "data/replay/single_burst.flog",
  ok = write_file(File, [
    {single, "seqA", undefined, record("s1.one")},
    {single, "seqA", undefined, record("s2.two")},
    {burst, "seqB", undefined, record("b1.one")},
    {burst, "seqB", undefined, record("b2.two")}
  ]),
  Expected = [
    % NOTE: {burst,...} < {single,...}
    {burst, "seqB", undefined, "b1.one", undefined},
    {burst, "seqB", undefined, "b2.two", undefined},
    {single, "seqA", undefined, "s1.one", undefined},
    {single, "seqA", undefined, "s2.two", undefined}
  ],
  estap:eq(replay_file(File), Expected, "replay"),
  estap:all_ok().

-test("single A, burst B, rotate B").
test_single_burst_rotate() ->
  File = "data/replay/single_burst_rotate.flog",
  ok = write_file(File, [
    {single, "seqA", undefined, record("s1.one")},
    {single, "seqA", undefined, record("s2.two")},
    {burst, "seqB", undefined, record("b1.one")},
    {burst, "seqB", undefined, record("b2.two")},
    {rotate, "seqB", undefined}
  ]),
  Expected = [
    % NOTE: {burst,...} < {single,...}
    {burst, "seqB", undefined, "b1.one", undefined},
    {burst, "seqB", undefined, "b2.two", undefined},
    {single, "seqA", undefined, "s1.one", undefined},
    {single, "seqA", undefined, "s2.two", undefined}
  ],
  estap:eq(replay_file(File), Expected, "replay"),
  estap:all_ok().

-test("single A, clear A.1").
test_single_clear_part() ->
  File = "data/replay/single_clear_part.flog",
  ok = write_file(File, [
    {single, "sequence", undefined, record("1.one")},
    {single, "sequence", undefined, record("2.two")},
    {single, "sequence", undefined, record("3.three")},
    {clear, "sequence", undefined, "2.two"}
  ]),
  Expected = [
    {single, "sequence", undefined, "1.one", undefined},
    {single, "sequence", undefined, "3.three", undefined}
  ],
  estap:eq(replay_file(File), Expected, "replay"),
  estap:all_ok().

-test("single A, clear A.nx").
test_single_clear_nx_part() ->
  File = "data/replay/single_clear_part.flog",
  ok = write_file(File, [
    {single, "sequence", undefined, record("1.one")},
    {single, "sequence", undefined, record("2.two")},
    {single, "sequence", undefined, record("3.three")},
    {clear, "sequence", undefined, "4.four"}
  ]),
  Expected = [
    {single, "sequence", undefined, "1.one", undefined},
    {single, "sequence", undefined, "2.two", undefined},
    {single, "sequence", undefined, "3.three", undefined}
  ],
  estap:eq(replay_file(File), Expected, "replay"),
  estap:all_ok().

-test("single A, burst A").
test_single_burst_ignored() ->
  File = "data/replay/single_burst_ignored.flog",
  ok = write_file(File, [
    {single, "sequence", undefined, record("1.one")},
    {single, "sequence", undefined, record("2.two")},
    {single, "sequence", undefined, record("3.three")},
    {burst, "sequence", undefined, record("4.four")}
  ]),
  Expected = [
    {single, "sequence", undefined, "1.one", undefined},
    {single, "sequence", undefined, "2.two", undefined},
    {single, "sequence", undefined, "3.three", undefined}
  ],
  estap:eq(replay_file(File), Expected, "replay"),
  estap:all_ok().

-test("burst A, single A").
test_burst_single_ignored() ->
  File = "data/replay/burst_single_ignored.flog",
  ok = write_file(File, [
    {burst, "sequence", undefined, record("1.one")},
    {burst, "sequence", undefined, record("2.two")},
    {burst, "sequence", undefined, record("3.three")},
    {single, "sequence", undefined, record("4.four")}
  ]),
  Expected = [
    {burst, "sequence", undefined, "1.one", undefined},
    {burst, "sequence", undefined, "2.two", undefined},
    {burst, "sequence", undefined, "3.three", undefined}
  ],
  estap:eq(replay_file(File), Expected, "replay"),
  estap:all_ok().

-test("single, rotate").
test_single_rotate() ->
  File = "data/replay/single_rotate.flog",
  ok = write_file(File, [
    {single, "sequence", undefined, record("1.one")},
    {single, "sequence", undefined, record("2.two")},
    {single, "sequence", undefined, record("3.three")},
    {rotate, "sequence", undefined}
  ]),
  Expected = [
    {single, "sequence", undefined, "1.one", undefined},
    {single, "sequence", undefined, "2.two", undefined},
    {single, "sequence", undefined, "3.three", undefined}
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
    {Type, decode(Name), decode(Origin), decode(Key), decode(Value)} ||
    #value{key = Key, value = Value} <- Records
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
  statip_flog:append(Handle, encode(Name), encode(Origin), clear, burst);
append(Handle, {clear, Name, Origin, Key}) ->
  % type doesn't matter, as long as it makes sense for this record
  statip_flog:append(Handle, encode(Name), encode(Origin),
                     {clear, encode(Key)}, single);
append(Handle, {single, Name, Origin, Entry = #value{}}) ->
  statip_flog:append(Handle, encode(Name), encode(Origin), Entry, single);
append(Handle, {burst, Name, Origin, Entry = #value{}}) ->
  statip_flog:append(Handle, encode(Name), encode(Origin), Entry, burst);
append(Handle, {rotate, Name, Origin}) ->
  statip_flog:append(Handle, encode(Name), encode(Origin), rotate, burst).

%%----------------------------------------------------------------------------

record(Key) ->
  record(Key, undefined).

record(Key, Value) ->
  record(Key, Value, 0).

record(Key, Value, TimeOffset) ->
  #value{
    key = encode(Key),
    value = encode(Value),
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
