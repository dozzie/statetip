StateTip recent state registry
==============================

StateTip is an application intended for remembering most recent values for
different variables collected by a monitoring system.

This allow monitoring probe to simply read the current state of the thing
being monitored (e.g. network link status) in regular intervals and send the
result out. StateTip receives such a state, remembers it, and allows some
dashboard to read what was the most recent state.

StateTip can also recombine stream of messages back into a list. For instance,
it makes sense to collect hosts availability as a separate message for each
host, but sometimes it's necessary to get a list of monitored hosts back from
the events stream. StateTip again allows to collect data in simplest form,
rebuilding the list from the stream.

Contact and License
-------------------

StateTip is written by Stanislaw klekot <dozzie at jarowit.net>.
The primary distribution point is
<http://dozzie.jarowit.net/trac/wiki/StateTip>.

StateTip is distributed under GNU GPL v3 license. See LICENSE file for
details.
