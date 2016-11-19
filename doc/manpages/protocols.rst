Client protocols
================

.. _sender-protocol:

Sender protocol
---------------

Default port 3012

Line-wise JSON.

Mandatory keys:

* ``"name"``    -- string
* ``"origin"``  -- string or ``null``
* ``"key"``     -- string
* ``"related"`` -- ``true`` or ``false``

Optional keys:

* ``"sort_key"`` -- string or ``null`` (if ``null``, ``"key"`` is used for
  sorting)
* ``"state"``    -- string or ``null`` (default: ``null``)
* ``"severity"`` -- ``"expected"``, ``"warning"``, or ``"error"`` (default:
  ``"expected"``)
* ``"info"``     -- any JSON value (default: ``null``)
* ``"created"``  -- integer (unix timestamp; default: current time)
* ``"expiry"``   -- integer (number of seconds greater than zero, default:
  leave to set by server)

Example minimal valid event:

.. code-block:: json

    {"related": false, "name": "fs", "origin": "web01", "key": "/home"}

Example fully-specified 

.. code-block:: json

    {"related": true,
      "name": "interfaces", "origin": "web01", "key": "vlan512",
      "state": "up", "severity": "expected", "info": {"device": "eth0"}}

.. _reader-protocol:

Reader protocol
---------------

Default port 3082

A complete JSON object (either a hash or a list) is always encoded in one
line. If many JSON objects are returned, each is encoded in its own line.

URL prefixes:

* ``/list/...`` -- List value group names, origins, keys, or specific value,
  one item per line. Specific value is returned as a JSON hash, all the others
  are plain text values (no specific encoding).

* ``/json/...`` -- Similar to ``/list/...`` prefix, except the data will
  always be a JSON: an array for names, origins, and keys, hash for specific
  value.

For the URLs below, the ``/list/...`` prefix was chosen. ``/json/...`` and
others have the same format and rules.

* ``/list/`` -- list value group names
* ``/list/<name>`` -- list origins of the specified value group
* ``/list/<name>/<origin>`` -- list keys in specified value group origin
* ``/list/<name>/~`` -- special case when origin was set to ``null``
* ``/list/<name>/<origin>/<key>`` -- specific value as a JSON hash (``null``
  origin encoded as ``"~"``)

.. code-block:: json

    {"name": "interfaces", "origin": "web01", "key": "vlan512",
      "state": "up", "severity": "expected", "info": {"device": "eth0"}}

Beside ``/list/...`` and ``/json/...`` URLs, there are two more URL types:

* ``/all/<name>/<origin>`` -- Instead of listing keys, list whole values, as
  if multiple ``/list/<name>/<origin>/<key>`` calls were made.

* ``/json-all/<name>/<origin>`` -- Similar to ``/all/<name>/<origin>``, but
  all the values are returned as a single JSON list.

This allows to avoid multiple HTTP requests and possible key encoding
problems, if the key contains a special character.
