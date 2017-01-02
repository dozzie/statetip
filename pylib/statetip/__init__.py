#!/usr/bin/python
'''

.. autoclass:: StateTipSender
    :members:

.. autoclass:: StateTipReader
    :members:

.. autoexception:: StateTipException

.. autoexception:: AddressError

.. autoexception:: NetworkError

.. autoexception:: HTTPError

.. autoexception:: Timeout

'''

import socket
import urllib2
import json

#-----------------------------------------------------------------------------

__VERSION__ = "0.1.1"

#-----------------------------------------------------------------------------

class StateTipException(Exception):
    '''
    A base class for exceptions.
    '''
    pass

class AddressError(StateTipException):
    '''
    StateTip address (host or port) invalid exception.
    '''
    pass

class NetworkError(StateTipException):
    '''
    Network error exception.
    '''
    pass

class HTTPError(NetworkError):
    '''
    HTTP error exception, a subclass of :exc:`NetworkError`.
    '''
    def __init__(self, code, reason):
        '''
        :param code: HTTP status code
        :param reason: message returned in status line

        Both parameters are available as exception's fields (``e.code`` and
        ``e.reason``, respectively).
        '''
        super(HTTPError, self).__init__("HTTP error: [%s] %s" % (code, reason))
        self.code = code
        self.reason = reason

class Timeout(StateTipException):
    '''
    Request timeout exception.
    '''
    pass

#-----------------------------------------------------------------------------

class StateTipSender:
    '''
    Sender client class.
    '''
    def __init__(self, host = 'localhost', port = 3012):
        '''
        :param host: address of StateTip instance to send events to
        :param port: sender port of StateTip instance
        :throws: :exc:`NetworkError`
        '''
        self.host = host
        self.port = port
        try:
            self.conn = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            self.conn.connect((self.host, self.port))
        except socket.error, e:
            raise NetworkError("connection error: %s" % (e,))

    def send(self, name, origin, key, related = False,
             state = None, severity = None, info = None, sort_key = None,
             created = None, expiry = None):
        '''
        :param name: value group name
        :type name: string
        :param origin: value group's origin
        :type origin: string or ``None``
        :param key: value's key
        :type key: string
        :param sort_key: key to sort values with when reading
        :type sort_key: string or ``None``
        :param related: value group type, i.e. if it's a group of related or
            unrelated values
        :type related: boolean
        :param state: state to store in this value
        :type state: string or ``None``
        :param severity: severity of the state
        :type severity: ``"expected"``, ``"warning"``, or ``"error"``
        :param info: additional data to store in this value
        :type info: JSON-serializable object
        :param created: timestamp (unix) of collection of this value
        :type created: integer or float
        :param expiry: when this value expires after its collection
        :type expiry: integer (seconds)
        :throws: :exc:`NetworkError`, :exc:`ValueError`

        Send an event to StateTip.

        If any of the fields is not serializable, :exc:`ValueError` exception
        is raised. Network errors are signaled by throwing
        :exc:`NetworkError`.

        See :doc:`glossary` for exact meaning of any of the above terms.
        '''
        event = {
            "name": name,
            "origin": origin,
            "key": key,
            "related": related,
        }
        if state is not None:
            event["state"] = state
        if severity is not None:
            event["severity"] = severity
        if info is not None:
            event["info"] = info
        if created is not None:
            event["created"] = int(created)
        if expiry is not None:
            event["expiry"] = int(expiry)
        try:
            self.conn.send(json.dumps(event))
            self.conn.send("\n")
        except socket.error, e:
            raise NetworkError("connection error: %s" % (e,))
        except TypeError, e:
            raise ValueError(str(e))

#-----------------------------------------------------------------------------

class StateTipReader:
    '''
    Reader client class.
    '''
    def __init__(self, host = 'localhost', port = 3082, timeout = None):
        '''
        :param host: address of StateTip instance to send events to
        :param port: sender port of StateTip instance
        :param timeout: request timeout for reading data
        '''
        self.host = host
        self.port = port
        self.timeout = timeout

    def _json_request(self, path_format, *args):
        '''
        :param path_format: format string for path portion of HTTP URL; should
            start with ``"/"``
        :param *args: arguments for :obj:`path_format`
        :returns: dictionary or list with deserialized reply
        :throws: :exc:`AddressError`, :exc:`NetworkError`, :exc:`Timeout`

        Send a HTTP request to StateTip, receive reply, and deserialize it.

        Throws :exc:`AddressError` when either host or port specified in
        constructor is of invalid format, :exc:`NetworkError` in the case of
        network/protocol errors (e.g. the remote host couldn't be reached, the
        connection was reset, or server's reply was invalid), or
        :exc:`Timeout` when the request timed out.
        '''
        request = urllib2.Request(
            ("http://%s:%s" + path_format) % ((self.host, self.port) + args),
            headers = {
                "User-Agent": "python-statetip/%s" % (__VERSION__,),
            },
        )
        try:
            reply_handle = urllib2.urlopen(request, timeout = self.timeout)
        except urllib2.HTTPError, e:
            raise HTTPError(e.code, e.reason)
        except urllib2.URLError, e:
            raise NetworkError("connection error: %s" % (e.reason))
        except socket.timeout, e:
            raise Timeout("request timed out")
        except ValueError, e:
            raise AddressError("invalid host or port: %s" % (e,))

        try:
            return json.load(reply_handle)
        except ValueError, e:
            # json module's error description is just as undescriptive, but
            # doesn't tell that it's server's fault
            raise NetworkError("invalid server reply")

    @staticmethod
    def _check_name_origin(name, origin = None):
        # incidentally, origin can also be `None'
        if "/" in name or " " in name:
            raise ValueError("invalid value group name")
        if origin is not None and ("/" in origin or " " in origin):
            raise ValueError("invalid value group origin")

    def names(self):
        '''
        :returns: list of names (strings)
        :throws: :exc:`AddressError`, :exc:`NetworkError`, :exc:`Timeout`

        List the names of recorded value groups.
        '''
        return self._json_request("/json")

    def origins(self, name):
        '''
        :param name: value group name
        :type name: string
        :returns: list of origins (strings, with one entry possibly being
            ``None``)
        :throws: :exc:`AddressError`, :exc:`NetworkError`, :exc:`Timeout`,
            :exc:`ValueError`

        List origins for a specific value group.

        Invalid group name results in :exc:`ValueError`.
        '''
        StateTipReader._check_name_origin(name)

        return [
            origin if origin != "~" else None
            for origin in self._json_request("/json/%s", name)
        ]

    def keys(self, name, origin):
        '''
        :param name: value group name
        :type name: string
        :param origin: value group's origin
        :type origin: string or ``None``
        :returns: list of keys (strings)
        :throws: :exc:`AddressError`, :exc:`NetworkError`, :exc:`Timeout`,
            :exc:`ValueError`

        List keys for a specific origin in a value group.

        Invalid group name or origin results in :exc:`ValueError`.
        '''
        StateTipReader._check_name_origin(name)

        if origin is None:
            origin = "~" # this is how null origin is encoded in URL

        return self._json_request("/json/%s/%s", name, origin)

    def values(self, name, origin):
        '''
        :param name: value group name
        :type name: string
        :param origin: value group's origin
        :type origin: string or ``None``
        :returns: list of dictionaries, each of the same format as
            :meth:`get()`
        :throws: :exc:`AddressError`, :exc:`NetworkError`, :exc:`Timeout`,
            :exc:`ValueError`

        List all values (including key, state, severity, and info fields) of
        a specific origin in a value group.

        Invalid group name or origin results in :exc:`ValueError`.
        '''
        StateTipReader._check_name_origin(name)

        if origin is None:
            origin = "~" # this is how null origin is encoded in URL

        return self._json_request("/json-all/%s/%s", name, origin)

    def get(self, name, origin, key):
        '''
        :param name: value group name
        :type name: string
        :param origin: value group's origin
        :type origin: string or ``None``
        :param key: value's key
        :type key: string
        :return: dictionary or ``None``
        :throws: :exc:`AddressError`, :exc:`NetworkError`, :exc:`Timeout`,
            :exc:`ValueError`

        Retrieve a specific value (or ``None`` if value doesn't exist).
        Returned value will similar to the following dictionary:

        .. code-block:: python

            {"name": "cpus", "origin": "web01", "key": "cpu0",
                "state": None, "severity": "expected", "info": None}

        The returned dictionary is guaranteed to have following fields:

        * ``"name"`` -- value group's name (string)
        * ``"origin"`` -- value group's origin (string or ``None``)
        * ``"key"`` -- value's key (string)
        * ``"state"`` -- state recorded in the value (string or ``None``)
        * ``"severity"`` -- state severity (``"expected"``, ``"warning"``, or ``"error"``)
        * ``"info"`` -- additional information recorded in the value

        Invalid group name or origin results in :exc:`ValueError`.
        '''
        StateTipReader._check_name_origin(name)

        if origin is None:
            origin = "~" # this is how null origin is encoded in URL

        return self._json_request("/json/%s/%s/%s", name, origin, key)

#-----------------------------------------------------------------------------
# vim:ft=python:foldmethod=marker
