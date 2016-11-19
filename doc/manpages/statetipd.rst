***************
StateTip daemon
***************

Synopsis
========

.. code-block:: none

    statetipd [options] start [--debug] [--config <path>] [--pidfile <path>]
    statetipd [options] status [--wait [--timeout <seconds>]]
    statetipd [options] stop [--timeout <seconds>] [--print-pid]
    statetipd [options] reload-config
    statetipd [options] compact-statelog
    statetipd [options] reopen-logs
    statetipd [options] dist-erl-start
    statetipd [options] dist-erl-stop
    statetipd [options] list [<name> [<origin> [<key>]]]
    statetipd [options] delete <name> [<origin> [<key>]]
    statetipd [options] log-dump [<logfile>]
    statetipd [options] log-replay [<logfile>]
    statetipd [options] log-recreate [<logfile>] <dump-file>
    statetipd [options] log-compact [<logfile>]

Description
===========

:program:`statetipd` is a helper service for monitoring systems, especially
for building dashboards. :program:`statetipd` remembers the last values of
events sent to it and can serve as an inventory of sorts. For example,
a sysadmin may collect status of servers (e.g. "up" or "down") in his
network. :program:`statetipd` allows to list all the servers that status was
collected for, and then for each server display its status and/or some graphs.

Usage
=====

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

.. describe:: statetipd reload-config

    Reload the daemon's configuration. See also :ref:`statetipd-config`.

.. describe:: statetipd compact-statelog

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

    The same information can be extracted using :manpage:`statetip(1)` tool.

.. describe:: statetipd delete <name> [<origin> [<key>]]

    Delete value group, origin in a value group, or specific value.

.. describe:: statetipd log-dump [<logfile>]

    Print the content of a state log file to *STDOUT* as a sequence of JSON
    objects, one per line. A log file can be recreated with such a dump with
    ``statetipd log-recreate`` command.

    **TODO**: use ``--config``

.. describe:: statetipd log-replay [<logfile>]

    Replay a state log file and print the end result to *STDOUT* as a sequence
    of JSON objects, one per line. This command is similar to ``statetipd
    log-dump``, except it only prints the most recent values.

    **TODO**: use ``--config``

    **TODO**: options for read block size, retries count

.. describe:: statetipd log-recreate [<logfile>] <dump-file>

    Recreate a state log file from a dump that was created with ``statetipd
    log-dump`` or ``statetipd log-replay``.

    **TODO**: use ``--config``

.. describe:: statetipd log-compact [<logfile>]

    Compact the specified state log file. Similar in effect to ``statetipd
    log-replay`` followed by ``statetipd log-recreate``.

    This command is executed in the calling process, not in the daemon
    instance, unlike similar command ``statetipd compact-statelog``.

    **TODO**: use ``--config``

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

.. _statetipd-config:

Configuration
=============

TOML

Example:

.. code-block:: ini

    [events]
    listen = "localhost:3012"
    default_expiry = 43200

    [http]
    listen = "localhost:3082"

    [store]
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

``[events]``
------------

.. describe:: listen

.. describe:: default_expiry

``[http]``
----------

.. describe:: listen

``[store]``
-----------

.. describe:: directory

.. describe:: compaction_size

``[logging]``
-------------

.. describe:: handlers

.. _statetipd-erlang:

``[erlang]``
------------

.. describe:: node_name

.. describe:: name_type

.. describe:: cookie_file

.. describe:: distributed_immediate

.. describe:: log_file

See Also
========

* :manpage:`statetip(1)`
* :manpage:`statetip-protocol(7)`
* :manpage:`start-stop-daemon(8)`
* Seismometer <http://seismometer.net/>
