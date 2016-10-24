%%%---------------------------------------------------------------------------

%% ETS table to keep "booted" flag, so `statip_state_log' can tell between
%% regular startup and crash recovery.
-define(ETS_BOOT_TABLE, statip_boot).

%%%---------------------------------------------------------------------------
