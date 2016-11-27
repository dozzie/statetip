***************
StateTip daemon
***************

Synopsis
========

.. code-block:: none

    statetipd [options] start [--debug] [--config <path>] [--pidfile <path>]
    statetipd [options] status [--wait [--timeout <seconds>]]
    statetipd [options] stop [--timeout <seconds>] [--print-pid]
    statetipd [options] reload
    statetipd [options] compact
    statetipd [options] reopen-logs
    statetipd [options] dist-erl-start
    statetipd [options] dist-erl-stop
    statetipd [options] list [<name> [<origin> [<key>]]]
    statetipd [options] delete <name> [<origin> [<key>]]
    statetipd log-dump <logfile> [--read-block <bytes>] [--read-tries <count>]
    statetipd log-replay <logfile> [--read-block <bytes>] [--read-tries <count>]
    statetipd log-restore <logfile> <dump-file>
    statetipd log-compact <logfile> [--read-block <bytes>] [--read-tries <count>]

Description
===========

:program:`statetipd` is a service to help build monitoring systems, especially
for dashboards. :program:`statetipd` remembers the last values of events sent
to it and can serve as an inventory of sorts. For example, a sysadmin may
collect status of servers (e.g. "up" or "down") in his network.
:program:`statetipd` allows to list all the servers that status was collected
for, and then for each server display its status and/or some graphs.

Usage
=====

To receive values and list them :program:`statetipd` uses a protocol defined
in :manpage:`statetip-protocol(7)`. :doc:`Python module <../python-api>` that
already implements the protocol is provided, as well as a command line tool
:manpage:`statetip(1)`. :manpage:`statetip(1)` is intended mainly for manual
data inspection and for writing small pipelines to feed :program:`statetipd`
with data, so it's not as flexible as Python API, but should be enough for
most use cases.

To run and control the :program:`statetipd` daemon, there are several commands
that are described below.

Commands
--------

Commands that are issued to a daemon instance (all except ``start`` and
``log-*``) use the path to control socket specified with :option:`--socket`
option as the target daemon's address. Similarly, ``start`` uses
:option:`--socket` as the address that these commands can be sent to.

.. describe:: statetipd start [--debug] [--config <path>] [--pidfile <path>]

    Start the :program:`statetipd` daemon. It doesn't detach from the
    terminal, so the caller is responsible for that, e.g. using
    :manpage:`start-stop-daemon(8)`.

.. describe:: statetipd status [--wait [--timeout <seconds>]]

    Check if the daemon is running. Status is both printed to *STDOUT* and
    indicated with exit code (0 means the daemon is running, 1 means it's
    stopped).

    With :option:`--wait` option the command will wait for daemon to start
    listening on the control socket (useful for initscripts), timing out after
    *<seconds>* (default is to wait indefinitely).

.. describe:: statetipd stop [--timeout <seconds>] [--print-pid]

    Shutdown the daemon. With :option:`--print-pid` option, PID of the daemon
    is printed to *STDOUT*, so the caller may wait until the process really
    terminates (it may happen that nothing is printed; in such case, the
    process already terminated).

    Command waits at most *<seconds>* (default is infinity), and then reports
    an error.

.. describe:: statetipd reload

    Reload the daemon's configuration. See also :ref:`statetipd-config`.

.. describe:: statetipd compact

    Start the state log file compaction outside its usual schedule.

    This command is executed in the daemon instance, unlike similar command
    ``statetipd log-compact``.

.. describe:: statetipd reopen-logs

    Reopen log files, both state log and Erlang log.

.. describe:: statetipd dist-erl-start

    Configure Erlang networking as a distributed node. This usually will be
    a debugging channel.

    See :ref:`statetipd-erlang` config file section for configuration details.

.. describe:: statetipd dist-erl-stop

    Deconfigure Erlang networking.

.. describe:: statetipd list [<name> [<origin> [<key>]]]

    List known value group names, origins, keys, or specific value.

    ``null`` origin in arguments is encoded as an empty string, so the command
    is ``statetipd list <name> "" [<key>]``. In ``statetipd list <name>``,
    ``null`` origin is printed as ``"<null>"``.

    The same information can be extracted using :manpage:`statetip(1)` tool.

.. describe:: statetipd delete <name> [<origin> [<key>]]

    Delete value group, origin in a value group, or specific value.

    ``null`` origin is encoded as an empty string, so the command is
    ``statetipd delete <name> "" [<key>]``.

.. describe:: statetipd log-dump <logfile> [--read-block <bytes>] [--read-tries <count>]

    Print the content of a state log file to *STDOUT* as a sequence of JSON
    objects, one per line. A log file can be restored from such a dump with
    ``statetipd log-restore`` command.

    Any problems (e.g. damaged records) encountered during dumping a log file
    are printed to *STDERR*.

.. describe:: statetipd log-replay <logfile> [--read-block <bytes>] [--read-tries <count>]

    Replay a state log file and print the end result to *STDOUT* as a sequence
    of JSON objects, one per line. This command is similar to ``statetipd
    log-dump``, except it only prints the most recent values.

    Problems (e.g. damaged records) encountered during replaying a log
    file that the procedure recovered from are suppressed. To get a detailed
    report, use ``statetipd log-dump`` command.

.. describe:: statetipd log-restore <logfile> <dump-file>

    Create a state log file from a dump that was created with ``statetipd
    log-dump`` or ``statetipd log-replay``.

.. describe:: statetipd log-compact <logfile> [--read-block <bytes>] [--read-tries <count>]

    Compact the specified state log file. Similar in effect to ``statetipd
    log-replay`` followed by ``statetipd log-restore``.

    This command is executed in the calling process, not in the daemon
    instance, unlike similar command ``statetipd compact``.

Options
-------

.. option:: --socket <path>

    Location of an administrative socket, where a command will be sent (or on
    which commands will be received, in case of ``statetipd start``). Defaults
    to :file:`/var/run/statetip/control`.

.. option:: --config <path>

    Path to a configuration file (see :ref:`statetipd-config`). Defaults to
    :file:`/etc/statetip/statetip.toml`.

    Used by ``statetipd start``.

.. option:: --debug

    Verbose start of :program:`statetipd` (starts ``sasl`` Erlang application
    before anything else).

    Used by ``statetipd start``.

.. option:: --pidfile <path>

    Path to a file where daemon's PID will be written to. If not specified, no
    pidfile will be written.

    Used by ``statetipd start``.

.. option:: --print-pid

    Flag to make ``statetipd stop`` command print PID of the daemon, so the
    caller may wait until the process terminates.

    *NOTE*: ``statetipd stop`` may still print nothing if the daemon
    terminates before the command returns.

.. option:: --timeout <seconds>

    Timeout for ``statetipd stop`` and ``statetipd status --wait`` commands.
    Defaults to infinity.

.. option:: --wait

    Flag to make ``statetipd status`` command to wait for control socket to
    appear instead of telling immediately that the daemon is stopped. Option
    intended for use in initscripts.

.. option:: --read-block <bytes>

    Size of a maximum block that is read from a log file. A single record
    needs to fit in this block. It will also be used to search for a valid
    record if a damaged entry is encountered.

    The block size must be a multiple of 8.

    Default is 4096 bytes. For comparison, records with a small *info* field
    take around 150-200 bytes.

.. option:: --read-tries <count>

    Number of consequent read blocks (:option:`--read-block`) that will be
    tried if a damaged entry is encountered.

    Default is 3 blocks.

.. _statetipd-config:

Configuration
=============

Config file for :program:`statetipd` is a TOML file. It specifies where
:program:`statetipd` listens for clients (e.g. :manpage:`statetip(1)`), where
state log is saved, and how to configure Erlang networking for debugging.

Configuration file could look like this:

.. code-block:: ini

    [senders]
    listen = ["localhost:3012"]
    default_expiry = 43200

    [readers]
    listen = ["localhost:3082"]

    [state_log]
    directory = "/var/lib/statetip"
    compaction_size = 10485760

    [logging]
    handlers = ["statip_syslog_h"]

    [erlang]
    node_name = "statetip"
    name_type = "longnames"
    cookie_file = "/etc/statetip/cookie.txt"
    distributed_immediate = false
    log_file = "/var/log/statetip/erlang.log"

``[senders]``
-------------

Section relevant to sender clients, which send values.

.. describe:: listen = ["<address>:<port>", ...]

    List of addresses to listen for sender clients. If *<address>* is
    specified as ``*``, :program:`statetipd` accepts connections on any
    address.

    Default value is ``["localhost:3012"]``.

.. describe:: default_expiry = <seconds>

    Expiry age that will be set for values that didn't provide one.

    Default value is 43200 (12 hours).

``[readers]``
-------------

Section relevant to reader clients.

.. describe:: listen = ["<address>:<port>", ...]

    List of addresses to listen for reader clients. If *<address>* is
    specified as ``*``, :program:`statetipd` accepts connections on any
    address.

    Default value is ``["localhost:3082"]``.

``[state_log]``
---------------

Section for state logging. State log is a file that records all the changes to
the value groups.

If no state logging is configured, :program:`statetipd` looses all the
received values (until they are sent again). Typically this shouldn't be
a problem, as monitoring usually sends updates in intervals counted in
minutes, but for the cases when a value is collected rarely, state log comes
handy.

*NOTE*: It is always safe to delete contents of ``state_log.directory`` when
:program:`statetipd` is shut down.

.. describe:: directory = "<path>"

    Directory to store state log. If set, then changes in all value groups
    will be recorded and restored on daemon start.

    If the option is not set, no state log is written and all values are lost
    on restart.

.. describe:: compaction_size = <bytes>

    A size limit for state log, after which the log is compacted (old entries
    are removed and a new log file that only contains fresh entries is written
    in its place).

    Default value is 10485760 (10 MB).

``[logging]``
-------------

.. describe:: handlers = ["<handler>", ...]

    List of destinations for :program:`statetipd`'s internal logging.
    Currently supported values are ``"statip_syslog_h"`` and
    ``"statip_stdout_h"``.

    Default is ``[]`` (no logging).

.. _statetipd-erlang:

``[erlang]``
------------

Section to configure Erlang VM running :program:`statetipd` as distributed
node. This exposes a channel for debugging StateTip.

.. describe:: node_name = "<node>"

    Node name for Erlang VM running :program:`statetipd`.

.. describe:: name_type = "shortnames" | "longnames"

    Type of names for distributed Erlang. Either ``"shortnames"`` or
    ``"longnames"``.

.. describe:: cookie_file = "<path>"

    Path to a file that contains cookie for distributed Erlang. If not
    specified, Erlang's default procedure for setting cookie takes place.

.. describe:: distributed_immediate = true | false

    Whether to start Erlang networking immediately or wait until an
    appropriate command (``statetipd dist-erl-start``) is issued.

    Default is ``false``.

.. describe:: log_file = "<path>"

    File to write Erlang's internal messages to (:manpage:`error_logger(3)`).
    Default is not set.

See Also
========

* :manpage:`statetip(1)`
* :manpage:`statetip-protocol(7)`
* :manpage:`start-stop-daemon(8)`
* Seismometer <http://seismometer.net/>
