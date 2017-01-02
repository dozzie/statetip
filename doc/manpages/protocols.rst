****************
Client protocols
****************

Description
===========

Supplying and using data from monitoring are two quite different tasks and
it's rarely useful for a single client to do both. Because of this, StateTip
uses two separate protocols on two different ports. This way one may expose
StateTip for reading while keeping data submission limited.

.. _sender-protocol:

Sender protocol
===============

Default TCP port for sender connections is 3012.

Sender protocol is an unidirectional sequence of values, each of which is
encoded as JSON hash in a single line. Each line has to contain a valid JSON
object.

A JSON hash is expected to contain following keys:

* ``"name"`` (string) -- value group name
* ``"origin"`` (string or ``null``) -- origin of the value
* ``"key"`` (string) -- key of the value
* ``"related"`` (boolean) -- type of the value group: related values or
  unrelated values

JSON hash can also have following keys:

* ``"sort_key"`` (string or ``null``) -- key used to sort entries when lists
  keys or whole values from an origin; if ``null`` or omitted, ``"key"`` is
  used for sorting
* ``"state"`` (string or ``null``) -- state carried by the value; if omitted,
  ``null`` is assumed
* ``"severity"`` (``"expected"``, ``"warning"``, or ``"error"``) -- severity
  of the state; if omitted, ``"expected"`` is assumed
* ``"info"`` (any JSON object) -- additional information to be recorded along
  with the value; if omitted, ``null`` is assumed
* ``"created"`` (integer) -- unix timestamp (epoch time) that says when the
  value was collected; if omitted, StateTip sets it to current time
* ``"expiry"`` (integer) -- number of seconds (greater than zero), after which
  the value expires and is removed from StateTip; if omitted, StateTip sets it
  to a configured default

Example minimal valid value:

.. code-block:: json

    {"related": false, "name": "fs", "origin": "web01", "key": "/home"}

Example fully-specified valid value (wrapped for readability):

.. code-block:: json

    {"related": true,
      "name": "interfaces", "origin": "web01", "key": "vlan512",
      "sort_key": "vlan0512",
      "state": "up", "severity": "expected", "info": {"device": "eth0"},
      "created": 1470000000, "expiry": 3600}

.. _reader-protocol:

Reader protocol
===============

Default TCP port for reader connections is 3082.

Reader protocol is a protocol based on HTTP, because many languages already
have a client, and even command line clients (:manpage:`curl(1)` or
:manpage:`wget(1)`) can be used to read data from StateTip. All requests use
GET verb.

URL to read data from StateTip will somewhat like this:
``http://localhost:3082/list/interfaces/web01``. From this URL, only path
portion has any meaning to StateTip (trailing ``"/"`` is ignored). Hostname
and port are not used, apart from telling the HTTP client where to send
request to.

*NOTE*: StateTip doesn't provide any authentication or authorization mechanism
on its own.

*NOTE*: Whenever a JSON object (either a hash or a list) is returned, it's
always encoded in one line. If many JSON objects are returned, each is encoded
in its own line.

There are two basic path prefixes that can be used:

* ``/list/...`` -- List value group names, origins, keys, or specific value,
  one item per line. All lists (names, origins, and keys) are returned as
  plain text values (no specific encoding or quoting), and specific value is
  returned as a JSON hash.

* ``/json/...`` -- Similar to ``/list/...`` prefix, except the data will
  always be a JSON: an array for names, origins, and keys, hash for specific
  value.

For simplicity, the ``/list/...`` prefix was chosen for the paths below, but
``/json/...`` prefix can be used as well.

Following data queries are available:

* ``/list/`` -- list value group names
* ``/list/<name>`` -- list origins of the specified value group; ``null``
  origin makes a ``"~"`` entry, both in ``/list/...`` and in ``/json/...``
* ``/list/<name>/<origin>`` -- list keys in specified value group origin
* ``/list/<name>/~`` -- special case for ``null`` origin
* ``/list/<name>/<origin>/<key>`` -- retrieve specific value (again, ``null``
  origin is encoded in the URL as ``"~"``)

A value (``/list/<name>/<origin>/<key>`` path) is returned as a JSON hash that
resembles a value from :ref:`sender protocol <sender-protocol>`, except it
doesn't contain ``"sort_key"``, ``"created"``, nor ``"expiry"``, and it always
contain all the other keys. Example (wrapped for readability):

.. code-block:: json

    {"name": "interfaces", "origin": "web01", "key": "vlan512",
      "state": "up", "severity": "expected", "info": {"device": "eth0"}}

If requested value doesn't exist, it's either reported as ``null``
(``/json/<name>/<origin>/<key>`` path) or empty string
(``/list/<name>/<origin>/<key>`` path).

Beside ``/list/...`` and ``/json/...`` prefixes, there are two more paths
available:

* ``/all/<name>/<origin>`` -- Instead of listing keys, list whole values, as
  if multiple ``/list/<name>/<origin>/<key>`` calls were made.

* ``/json-all/<name>/<origin>`` -- Similar to ``/all/<name>/<origin>``, but
  all the values are returned as a single JSON list.

These two paths allow to avoid sending multiple HTTP requests. They also
mitigate possible key encoding problems, if some key contains a special
character that would otherwise need to be quoted.

Command line examples
---------------------

This is a hypothetical shell session that uses :manpage:`curl(1)` to read
monitoring data from StateTip:

.. code-block:: none

    $ curl http://localhost:3082/list
    interfaces
    servers
    x509-certs

    $ curl http://localhost:3082/json
    ["interfaces","servers","x509-certs"]

    $ curl http://localhost:3082/list/servers
    ~

    $ curl http://localhost:3082/json/servers
    ["~"]

    $ curl http://localhost:3082/list/servers/~
    web01
    web02
    db01

    $ curl http://localhost:3082/all/servers/~
    {"name":"servers","origin":null,"key":"web01","state":"up","severity":"expected","info":null}
    {"name":"servers","origin":null,"key":"web02","state":"down","severity":"error","info":null}
    {"name":"servers","origin":null,"key":"db01","state":"up","severity":"expected","info":null}

    $ curl http://localhost:3082/list/servers/~/web02
    {"name":"servers","origin":null,"key":"web02","state":"down","severity":"error","info":null}

    $ curl http://localhost:3082/list/interfaces
    web01
    web02
    db01

    $ curl http://localhost:3082/json/interfaces/db01
    ["eth0","eth1","lo"]

    $ curl http://localhost:3082/json/interfaces/db01/eth1
    {"name":"interfaces","origin":"db01","key":"eth1","state":"up","severity":"expected","info":{"address":"10.8.2.14/24"}}

See Also
========

* :manpage:`statetip(1)`
* :manpage:`curl(1)`
* :manpage:`wget(1)`
