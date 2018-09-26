%%%---------------------------------------------------------------------------
%%% @doc
%%%   Priority queue that allows to update priority of arbitrary entry.
%%% @end
%%%---------------------------------------------------------------------------

-module(statip_pqueue).

%% public interface
-export([new/0, add/3, delete/3, peek/1, pop/1, update/4]).

-export_type([priority/0, entry/0, pqueue/0]).

%%%---------------------------------------------------------------------------
%%% type specification/documentation {{{

-record(pqueue, {
  lowest = none :: {priority(), entry()} | none,
  mapping = gb_sets:new() :: gb_sets:set()
}).

-type pqueue() :: #pqueue{}.

-type priority() :: term().

-type entry() :: term().

%%% }}}
%%%---------------------------------------------------------------------------

%%%---------------------------------------------------------------------------
%%% public interface
%%%---------------------------------------------------------------------------

%% @doc Create a new, empty priority queue.

-spec new() ->
  pqueue().

new() ->
  #pqueue{}.

%% @doc Add an entry to a priority queue.

-spec add(entry(), priority(), pqueue()) ->
  pqueue().

add(Entry, Priority, _Queue = #pqueue{mapping = Mapping}) ->
  Node = {Priority, Entry},
  NewMapping = gb_sets:add(Node, Mapping),
  NewLowest = gb_sets:smallest(NewMapping),
  _NewQueue = #pqueue{lowest = NewLowest, mapping = NewMapping}.

%% @doc Remove an entry from a priority queue.

-spec delete(entry(), priority(), pqueue()) ->
  pqueue().

delete(Entry, Priority, _Queue = #pqueue{mapping = Mapping}) ->
  Node = {Priority, Entry},
  NewMapping = gb_sets:delete_any(Node, Mapping),
  NewLowest = gb_sets:smallest(NewMapping),
  _NewQueue = #pqueue{lowest = NewLowest, mapping = NewMapping}.

%% @doc Retrieve the first entry from a priority queue.
%%   This doesn't remove the entry from the queue, only checks what's first.

-spec peek(pqueue()) ->
  {entry(), priority()} | none.

peek(_Queue = #pqueue{lowest = none}) -> none;
peek(_Queue = #pqueue{lowest = {Priority, Entry}}) -> {Entry, Priority}.

%% @doc Remove the first entry from a priority queue.

-spec pop(pqueue()) ->
    {entry(), priority(), pqueue()}
  | {none, pqueue()}.

pop(Queue = #pqueue{lowest = none}) ->
  {none, Queue};
pop(_Queue = #pqueue{lowest = {Priority, Entry} = Node, mapping = Mapping}) ->
  NewMapping = gb_sets:delete(Node, Mapping),
  NewLowest = case gb_sets:is_empty(NewMapping) of
    false -> gb_sets:smallest(NewMapping);
    true  -> none
  end,
  NewQueue = #pqueue{lowest = NewLowest, mapping = NewMapping},
  {Entry, Priority, NewQueue}.

%% @doc Update entry's priority in a queue.
%%   The entry has to be present in the queue.

-spec update(entry(), priority(), priority(), pqueue()) ->
  pqueue().

update(Entry, OldPriority, NewPriority, _Queue = #pqueue{mapping = Mapping}) ->
  TempMapping = gb_sets:delete({OldPriority, Entry}, Mapping),
  NewMapping = gb_sets:add({NewPriority, Entry}, TempMapping),
  NewLowest = gb_sets:smallest(NewMapping),
  _NewQueue = #pqueue{lowest = NewLowest, mapping = NewMapping}.

%%%---------------------------------------------------------------------------
%%% vim:ft=erlang:foldmethod=marker
