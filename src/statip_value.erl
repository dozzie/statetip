%%%---------------------------------------------------------------------------
%%% @doc
%%%   Value records access functions.
%%%
%%%   <b>TODO</b>: What do I call "value"? What do I call "record"? What is
%%%   "name", "origin", and "key"?
%%% @end
%%%---------------------------------------------------------------------------

-module(statip_value).

%% public interface
-export([timestamp/0]).

-export_type([name/0, origin/0, key/0]).
-export_type([value/0, severity/0, info/0]).
-export_type([timestamp/0, expiry/0]).

%%%---------------------------------------------------------------------------
%%% type specification/documentation {{{

-type name() :: binary().
%% Value name.

-type origin() :: binary() | undefined.
%% Record's origin.

-type key() :: binary().
%% Record's key, which identifies particular record. @{type @{name(),
%% origin(), key@}} is an address for {@type value()}, {@type severity()}, and
%% {@type info()}.

-type value() :: binary() | undefined.
%% Value to be remembered.in the record.

-type severity() :: ok | warning | critical.
%% Value's severity.

-type info() :: statip_json:struct().
%% Additional data associated with the record.

-type timestamp() :: integer().
%% Time (unix timestamp) when the record was collected.

-type expiry() :: pos_integer().
%% Number of seconds after {@type timestamp()} when the record is valid. After
%% this time, the record is deleted.

%%% }}}
%%%---------------------------------------------------------------------------

%%%---------------------------------------------------------------------------
%%% public interface
%%%---------------------------------------------------------------------------

timestamp() ->
  {MS,S,_US} = os:timestamp(),
  MS * 1000 * 1000 + S.

%%%---------------------------------------------------------------------------
%%% vim:ft=erlang:foldmethod=marker
