#!/usr/bin/env python3
"""
bench/bench_target.py: the one place every bench script decides whether a
caller-supplied connection target is acceptable.

Where a bench script takes a FILE PATH, the containment check pins that
path inside the current working directory: a traversal-style argument can
then neither redirect where the data is read (path traversal) nor what
is connected to (connection-string injection). That check is about a
FILE PATH.

These bench scripts take a NETWORK ENDPOINT instead (--host, --port,
--user, --password, --database), so the equivalent threat is different in
kind but the same in spirit: an unvalidated --host silently redirects the
benchmark at an arbitrary server, and an unvalidated --database can name
any schema on that server. Both reach the engine as ordinary driver
parameters -- no SQL text is built from them -- so the risk here is
"benchmark pointed somewhere the caller did not intend", not injection.

So the check here is:
  * --host must be a plain hostname or IP literal. A value that looks
    like anything else (a URL, a path, a socket spec) is rejected: the
    driver would accept it, but a benchmark silently connecting somewhere
    unexpected is exactly what this guards against.
  * --database must be a plain SQL identifier. It is passed to the
    driver as a parameter, but the scripts also read
    information_schema with DATABASE() as the schema filter, so a
    non-identifier there is a schema-name injection into that filter's
    expectations.
  * --port must be in range.

The password is never validated, never logged, and never placed in a
connection string: it goes straight into the driver's own password= keyword
argument, so it cannot end up in a DSN, an exception message, or a log
line.
"""

from __future__ import annotations

import ipaddress
import re
import sys

# A SQL identifier: starts with a letter or underscore, then letters,
# digits, underscores or $. Deliberately excludes the backtick and the
# quote characters, so a value that would need quoting is rejected rather
# than quoted-and-escaped -- a bench script has no legitimate reason to
# benchmark a schema whose name needs quoting.
_IDENT_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_$]*$")

# A hostname label: letters, digits and hyphens, dot-separated.
_HOSTNAME_RE = re.compile(r"^(?=.{1,253}$)[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?"
                          r"(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)*$")


def _is_ip_literal(host: str) -> bool:
    """True if host is a bare IPv4/IPv6 literal."""
    try:
        ipaddress.ip_address(host)
        return True
    except ValueError:
        return False


def validate_target(script: str, host: str, port: int, database: str) -> str | None:
    """
    Returns an error message if the target is unacceptable, or None if it
    is fine. The caller prints the message and exits 2.
    """
    if not host:
        return f"{script}: --host must not be empty"

    # A bare IP literal is always fine. Otherwise it must be a plain
    # hostname: no scheme, no path, no port suffix, no userinfo. The
    # driver would take any of those, which is precisely the surprise
    # this check exists to prevent.
    if not _is_ip_literal(host) and not _HOSTNAME_RE.match(host):
        return (f"{script}: --host must be a plain hostname or IP address "
                f"(got: {host!r})")

    if not (1 <= port <= 65535):
        return f"{script}: --port must be in 1-65535 (got: {port})"

    if not database:
        return f"{script}: --database must not be empty"

    if not _IDENT_RE.match(database):
        return (f"{script}: --database must be a plain identifier "
                f"(letters, digits, underscore; got: {database!r})")

    return None


def check_target(script: str, host: str, port: int, database: str) -> bool:
    """Prints the error and returns False if the target is unacceptable."""
    err = validate_target(script, host, port, database)
    if err is None:
        return True
    print(err, file=sys.stderr)
    return False
