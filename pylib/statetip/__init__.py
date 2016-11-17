#!/usr/bin/python
'''
'''

import socket
import urllib2
import json

#-----------------------------------------------------------------------------

__VERSION__ = "0.0.0"

#-----------------------------------------------------------------------------

class StateTipException(Exception):
    pass

class URLError(StateTipException):
    pass

class NetworkError(StateTipException):
    pass

class Timeout(StateTipException):
    pass

#-----------------------------------------------------------------------------

class StateTipSender:
    def __init__(self, host = 'localhost', port = 3012):
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
        # XXX: can raise NetworkError or ValueError
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
    def __init__(self, host = 'localhost', port = 3082, timeout = None):
        self.host = host
        self.port = port
        self.timeout = timeout

    def _json_request(self, path_format, *args):
        # XXX: can raise URLError, NetworkError, Timeout, or ValueError
        request = urllib2.Request(
            ("http://%s:%s" + path_format) % ((self.host, self.port) + args),
            headers = {
                "User-Agent": "python-statetip/%s" % (__VERSION__,),
            },
        )
        try:
            reply_handle = urllib2.urlopen(request, timeout = self.timeout)
        except urllib2.HTTPError, e:
            raise NetworkError("HTTP error: [%s] %s" % (e.code, e.reason))
        except urllib2.URLError, e:
            raise NetworkError("connection error: %s" % (e.reason))
        except socket.timeout, e:
            raise Timeout("request timed out")
        except ValueError, e:
            raise URLError("invalid host or port: %s" % (e,))

        try:
            return json.load(reply_handle)
        except ValueError, e:
            # json module's error description is just as undescriptive, but
            # doesn't tell that it's server's fault
            raise ValueError("invalid server reply")

    @staticmethod
    def _check_name_origin(name, origin = None):
        # incidentally, origin can also be `None'
        if "/" in name or " " in name:
            raise Exception() # TODO: be more descriptive
        if origin is not None and ("/" in origin or " " in origin):
            raise Exception() # TODO: be more descriptive

    def names(self):
        return self._json_request("/json")

    def origins(self, name):
        StateTipReader._check_name_origin(name)

        return [
            origin if origin != "~" else None
            for origin in self._json_request("/json/%s", name)
        ]

    def keys(self, name, origin):
        StateTipReader._check_name_origin(name)

        if origin is None:
            origin = "~" # this is how null origin is encoded in URL

        return self._json_request("/json/%s/%s", name, origin)

    def values(self, name, origin):
        StateTipReader._check_name_origin(name)

        if origin is None:
            origin = "~" # this is how null origin is encoded in URL

        return self._json_request("/json-all/%s/%s", name, origin)

    def get(self, name, origin, key):
        StateTipReader._check_name_origin(name)

        if origin is None:
            origin = "~" # this is how null origin is encoded in URL

        return self._json_request("/json/%s/%s/%s", name, origin, key)

#-----------------------------------------------------------------------------
# vim:ft=python:foldmethod=marker
