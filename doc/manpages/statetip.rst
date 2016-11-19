***************
StateTip client
***************

Synopsis
========

.. code-block:: none

    statetip [--reader] [options] [<name> [<origin> [<key>]]]
    events-stream ... | statetip --sender --name=<name> [options]

Description
===========

:program:`statetip` is a command line client for StateTip. It can be used to
inspect and read data collected by :manpage:`statetipd(8)` (this mode is
called *reader mode*), or to send new data from *STDIN* to
:manpage:`statetipd(8)` (*sender mode*).

:program:`statetip` aims at simplifying some common use cases, like manual
data inspection or writing a small monitoring data pipeline with just shell
tools. If you need more advanced features (e.g. sorting value group's keys in
order different than lexicographical or recording additional data), use
:doc:`Python API <../python-api>` or directly :manpage:`statetip-protocol(7)`.

Usage
=====

There are several "top-level" options, which work regardless of the selected
mode (or that select the client mode):

.. option:: --reader

    Select reader mode. This is the default.

.. option:: --sender

    Select sender mode. This mode requires :option:`--name` to be specified as
    well.

.. option:: --address=<address>

    Select the address that :manpage:`statetipd(8)` listens on. Default is
    *localhost*.

.. option:: --port=<port>

    Select the port that :manpage:`statetipd(8)` listens on. Default is 3082
    for reader mode and 3012 for sender mode.

.. _statetip-reader:

Reader mode
-----------

Reader mode is used to list data already recorded by :manpage:`statetipd(8)`.
Sub-commands typically print a list of elements, each element in its own line.
This can be changed with :option:`--json` option, which causes
:program:`statetip` to print a single line with JSON list.

.. describe:: statetip --reader

    List names of all value groups.

.. describe:: statetip --reader <name>

    List origins of a specific value group.

    Null origin is printed as empty line (in JSON mode it's ``null``, as one
    would expect).

.. describe:: statetip --reader <name> <origin>

    List keys in a specific origin of a value group.

    Null origin is specified as ``"/"``, which otherwise is not a valid
    character in origin.

    Option :option:`--all` changes the mode from listing just keys to listing
    all values. This is similar to listing them one by one with consequent
    calls to :program:`statetip`, except this is a single operation.

    :option:`--all` with :option:`--json` results in printing the values as
    a single JSON list instead of printing them as JSON objects one per line.

.. describe:: statetip --reader <name> <origin> <key>

    List fields (one or several or all) of a specific value.

    By default, only state is printed. This can be changed by specifying
    a combination of :option:`--state`, :option:`--severity`, and
    :option:`--info` options.

    When :option:`--all` is specifed, whole value is printed to *STDOUT* as
    a JSON object.

Following options work in reader mode:

.. option:: --json

    Instead of printing list of elements line by line, print them as a single
    JSON list.

.. option:: --all

    Print whole value (or values) when listing keys of specific origin or when
    reading a specific value.

.. option:: --state

    Print state field of a value.

.. option:: --severity

    Print severity field of a value.

.. option:: --info

    Print info field of a value (always a valid JSON).

.. _statetip-sender:

Sender mode
-----------

Sender mode simplifies writing monitoring data to StateTip. Sender mode reads
a sequence of space-separated records from its *STDIN* and sends them to
:manpage:`statetipd(8)`, which is a shell-friendly behaviour, but the protocol
is simpler than :manpage:`statetip-protocol(7)`, so it doesn't support all the
cases. If you need full control over sent data, see :doc:`Python API
documentation <../python-api>` or :manpage:`statetip-protocol(7)`.

To make :manpage:`statetipd(8)` remember a set of values, you can use
a following command:

.. code-block:: sh

    printf 'key1 value1\nkey2 value2\nkey3 value3\n' | \
      statetip --sender --name=myname --origin=myorigin
    statetip --reader myname myorigin --all
    > {"key":"key1","state":"value1", ...}
    > {"key":"key2","state":"value2", ...}
    > {"key":"key3","state":"value3", ...}

Sender mode only allows sending one value group, which name must be specified
with :option:`--name` option. Origin may either be pre-defined with
:option:`--origin` or :option:`--null-origin` option or be provided along with
value's key.

.. option:: --unrelated

    Value group is a group of unrelated values (i.e. collected independently
    and ageing each on its own). This is the default.

.. option:: --related

    Value group is a group of related values (i.e. collected in a single
    operation, and the new collection replaces the old one immediately).

.. option:: --name=<name>

    Value group name.

.. option:: --origin=<origin>

    Origin of the value group. If not specified in advance, each entry has to
    specify its origin.

.. option:: --null-origin

    Set the origin of the value group to ``null``. Useful for cases when
    there values are collected in a single place, so there's no natural and
    meaningful origin.

.. option:: --expiry=<seconds>

    Expiration age for values. Values older than *<seconds>* are removed from
    listing by :manpage:`statetipd(8)`.

Sender mode input protocol
~~~~~~~~~~~~~~~~~~~~~~~~~~

Input protocol is a sequence of non-empty lines, each having up to four
whitespace-separated fields.

If values' origin was pre-defined with :option:`--origin` or
:option:`--null-origin`, then :program:`statetip` expects one of the following
line formats:

.. code-block:: none

    key
    key value
    key value severity

If neither of the options were specified, :program:`statetip` expects the
origin as an additional first field (this allows to send values of several
origins):

.. code-block:: none

    origin key
    origin key value
    origin key value severity

Name, origin, key, and value are non-empty strings that consist of letters,
digits, ``"."``, ``"_"``, ``"-"``. Key and value can also contain ``"/"``
characters.

If severity is specified, it should be either ``expected``, ``warning``, or
``error``.

See Also
========

* :manpage:`statetipd(8)`
* :manpage:`statetip-protocol(7)`
* Seismometer <http://seismometer.net/>
