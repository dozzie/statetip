********
Glossary
********

.. glossary::

    group of values
    value group
        A set of :term:`values <value>` that have the same meaning, but which
        were possibly collected at different places (see :term:`group origin`)
        and concern different monitored objects. Identified by :term:`group
        name`.

        .. glossary::

            related values
                Group of related values is collected at some :term:`origin
                <group origin>` at once, expires at once, and changes at once.
                If a list of *value keys* changes, the *keys* that were
                present but are missing should disappear from StateTip as soon
                as possible.

                List of network interfaces of a server is a good example of
                a group of related values.

            unrelated values
                :term:`Values <value>` from a group of unrelated values don't
                form a meaningful set, apart from telling the same thing about
                similar objects. Each value changes and expires independently
                of the others.

                An example of such values is expiry time of X.509 certificates
                installed on a server. Unlike with network interfaces,
                a :term:`value` for an old certificate doesn't need to
                disappear immediately with next reading of certs' statuses.

    group name
        Name of a :term:`value group`.

    group origin
    value origin
        Place (source) where some of the :term:`values <value>` in
        a :term:`value group` were collected from. :term:`Value group` can
        consist of :term:`values <value>` from many origins.

        Hostname usually makes a good origin. Origin may also be ``null`` if
        there is no meaningful distinction where the :term:`value` was
        collected from.

    log file
    state log file
        Append-only binary file that records every :term:`value` change or
        expiration. Log file is used to restore :term:`values <value>` after
        StateTip restart.

        .. glossary::

            log compaction
                Process of reading all :term:`log records <log record>`,
                discarding the ones that were replaced by newer ones, and
                writing a new :term:`log file` with only the newest
                :term:`records <log record>`.

                Part of this process is :term:`replaying <log replaying>` the
                compacted :term:`log file`.

            log record
                Block of binary data that describes a new state of
                :term:`value` (its group name, origin, key, state, expiry
                time, etc.) or marks that the value expired or changed in some
                other way.

            log replaying
                Process of reading :term:`records <log record>` from
                a :term:`log file` and applying changes they describe to
                a data structure, so that the result reflects the state of all
                the :term:`values <value>` in StateTip at the time of writing
                the :term:`log file`.

    reader client
        Program that extracts data out of StateTip through :ref:`StateTip
        reader protocol <reader-protocol>`.

    sender client
        Program that sends values to StateTip through :ref:`StateTip sender
        protocol <sender-protocol>`.

    value
        Last remembered state of some object that is being observed
        (monitored), usually collected for displaying on a dashboard or
        providing a listing what objects are monitored.

        Consists of :term:`group name`, :term:`origin <group origin>`,
        :term:`key`, :term:`state`, and some metadata.

        .. glossary::

            key
                "Name" of a value. Together with :term:`group name` and
                :term:`origin <group origin>` identifies particular
                :term:`value`.

            state
                Textual representation of the actual status of the monitored
                object, e.g. "up"/"down" for server's availability. Can be
                ``null`` for values collected for the sake of keeping an
                inventory of objects.

            severity
                Conformity of the :term:`state` with expectations. One of the
                three values: "expected", "warning", "error".

These terms are only used in source code:

.. glossary::

    value group registry
        Process that keeps track of :term:`value group keeper` processes.

    value group keeper
        Process that remembers :term:`values <value>` of specific
        :term:`origin <value origin>` from a :term:`value group`. Registered
        in :term:`value group registry` process under a name built of
        :term:`group name` and :term:`origin <value origin>`.

    state logger
        Process responsible for writing changes in :term:`values <value>` to
        a :term:`log file` and for periodical :term:`compaction <log
        compaction>` of the file.
