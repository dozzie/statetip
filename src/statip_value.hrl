%%%---------------------------------------------------------------------------
%%%
%%% Common record for `statip_value_*' modules.
%%%
%%%---------------------------------------------------------------------------

-record(value, {
  key :: statip_value:key(),
  sort_key = undefined :: statip_value:key() | undefined,
  value    = undefined :: statip_value:value(),
  severity = expected  :: statip_value:severity(),
  info     = null      :: statip_value:info(),
  created :: statip_value:timestamp(),
  expires :: statip_value:timestamp() % `Created + ExpiryTime'
}).

%%%---------------------------------------------------------------------------
%%% vim:ft=erlang:foldmethod=marker
