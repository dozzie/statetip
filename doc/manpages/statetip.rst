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

:program:`statetip` is a client for StateTip. It can be used to inspect and
read data collected by :manpage:`statetipd(8)`, which is called the *reader
mode*, or to send new data from *STDIN* to :manpage:`statetipd(8)`, which is
called the *sender mode*.

*NOTE*: To read null origin, specify ``"/"``, which otherwise is not a valid
character in origin.

Options
=======

.. option:: --reader
.. option:: --sender
.. option:: --address=<address>
.. option:: --port=<port>

Reader mode options
-------------------

.. option:: --json
.. option:: --all
.. option:: --state
.. option:: --severity
.. option:: --info

Sender mode options
-------------------

.. option:: --unrelated
.. option:: --related
.. option:: --name=<name>
.. option:: --origin=<origin>
.. option:: --null-origin
.. option:: --expiry=<seconds>

Input protocol
==============

Input with :option:`--origin` or :option:`--null-origin`:

.. code-block:: none

    key
    key value
    key value severity

Input without :option:`--origin` and :option:`--null-origin`:

.. code-block:: none

    origin key
    origin key value
    origin key value severity

Severities: ``expected``, ``warning``, ``error``.

Neither group name nor group origin should contain slash. Key can contain
slashes.

Sender client protocol
----------------------

.. include:: protocol_sender.rst.common

See Also
========

* :manpage:`statetipd(8)`
* Seismometer <http://seismometer.net/>
