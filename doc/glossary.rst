********
Glossary
********

.. describe:: group of values

    A set of *values* that have the same meaning, but which were possibly
    collected at different places (see *group origin*) and concern different
    monitored objects. Identified by *group name*.

    .. describe:: related values

        Group of related values is collected at some *origin* at once, expires
        at once, and changes at once. If a list of *value keys* changes, the
        *keys* that were present but are missing should disappear from
        StateTip as soon as possible.

        List of network interfaces of a server is a good example of a group of
        related values.

    .. describe:: unrelated values

        *Values* from a group of unrelated values don't form a meaningful set,
        apart from telling the same thing about similar objects. Each value
        changes and expires independently of the others.

        An example of such values is expiry time of X.509 certificates
        installed on a server. Unlike with network interfaces, a *value* for
        an old certificate doesn't need to disappear immediately with next
        reading of certs' statuses.

.. describe:: group name

    Name of a *value group*.

.. describe:: group origin (value origin)

    Place (source) where some of the *values* in a *value group* were
    collected from. *Value group* can consist of *values* from many origins.

    Hostname usually makes a good origin. Origin may also be ``null`` if there
    is no meaningful distinction where the *value* was collected from.

.. describe:: (state) log file

    Append-only binary file that records every *value* change or expiration.
    Log file is used to restore *values* after StateTip restart.

    .. describe:: compaction

        Process of reading all *log records*, discarding the ones that were
        replaced by newer ones, and writing a new *log file* with only the
        newest *records*.

        Part of this process is *replaying* the compacted *log file*.

    .. describe:: record

        Block of binary data that describes a new state of *value* (its group
        name, origin, key, state, expiry time, etc.) or marks that the value
        expired or changed in some other way.

    .. describe:: replaying

        Process of reading *records* from a *log file* and applying changes
        they describe to a data structure, so that the result reflects the
        state of all the *values* in StateTip at the time of writing the *log
        file*.

.. describe:: reader (client)

    Program that extracts data out of StateTip through :ref:`StateTip reader
    protocol <reader-protocol>`.

.. describe:: sender (client)

    Program that sends values to StateTip through :ref:`StateTip sender
    protocol <sender-protocol>`.

.. describe:: value

    Last remembered state of some object that is being observed (monitored),
    usually collected for displaying on a dashboard or providing a listing
    what objects are monitored.

    Consists of *group name*, *origin*, *key*, *state*, and some metadata.

    .. describe:: key

        "Name" of a value. Together with *group name* and *origin* identifies
        particular value.

    .. describe:: state

        Textual representation of the actual status of the monitored object,
        e.g. "up"/"down" for server's availability. Can be ``null`` for values
        collected for the sake of keeping an inventory of objects.

    .. describe:: severity

        Conformity of the *state* with expectations. One of the three values:
        "expected", "warning", "error".

These terms are only used in source code:

.. describe:: value group registry

    Process that keeps track of *value group keeper* processes.

.. describe:: value group keeper

    Process that remembers *values* of specific *origin* from a *value group*.
    Registered in *value group registry* process under a name built of
    *group name* and *origin*.

.. describe:: state logger

    Process responsible for writing changes in *values* to a *log file* and
    for periodical *compaction* of the file.
