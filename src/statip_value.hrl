%%%---------------------------------------------------------------------------
%%%
%%% Common record for `statip_value_*' modules.
%%%
%%%---------------------------------------------------------------------------

-record(value, {
  key      :: statip_value:key(),
  sort_key :: statip_value:key(),
  value    :: statip_value:value(),
  severity :: statip_value:severity(),
  info     :: statip_value:info(),
  created  :: statip_value:timestamp(),
  expires  :: statip_value:timestamp() % `Created + ExpiryTime'
}).

%%%---------------------------------------------------------------------------
%%% vim:ft=erlang:foldmethod=marker
