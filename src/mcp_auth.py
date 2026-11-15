#!/usr/bin/env python3
#
#  Copyright 2026 Alex Vesev
#
#  This file is part of MCP Python - Model Context Protocol server to
#  provide Python.
#
#  MCP Python is free software: you can redistribute it and/or modify
#  it under the terms of the GNU General Public License as published by
#  the Free Software Foundation, either version 3 of the License, or
#  (at your option) any later version.
#
#  MCP Python is distributed in the hope that it will be useful,
#  but WITHOUT ANY WARRANTY; without even the implied warranty of
#  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#  GNU General Public License for more details.
#
#  You should have received a copy of the GNU General Public License
#  along with MCP Python. If not, see <https://www.gnu.org/licenses/>.
#
##
#
# The authentication part - bearer tokens, one per client. All of it is
# here; the server takes it by 'AuthSettings.server_kwargs' only.
#
# The tokens are kept in a directory ('MCP_AUTH_TOKENS'), a file per
# client: the name of the file is the name of the client, the content is
# the SHA-256 of the token - not the token. A submitted code runs with the
# account of the server and can read what the server reads; a hash gives it
# nothing. A token is random (256 bits) and only generated here, never
# chosen - so a plain hash is enough.
#
# A client added - a file added, revoked - the file deleted. The server
# reads the directory again by itself, no restart ('MCP_AUTH_RELOAD_PERIOD').
# Or reads it once, at start, before the privileges drop - then the
# directory may be readable by root only, and a submitted code can not read
# even the hashes; a change of the clients needs a restart.
#
# Run as a program - the tool for the files ('mcp-python-token'):
#
#   mcp_auth.py [--dir DIR] add NAME | list | remove NAME
#
# Standard library only - the MCP SDK is imported where the server needs
# it, so the tool runs with any 'python3'.
#
##

import argparse
import errno
import hashlib
import ipaddress
import logging
import math
import os
import re
import secrets
import sys
import time
from dataclasses import dataclass
from datetime import date
from os import environ

log = logging.getLogger(__name__)

DEFAULT_TOKENS_DIR = "/etc/mcp-python/tokens"

# Marks a token for a human and for secret scanners.
TOKEN_PREFIX = "mcpp_"

# A valid key of a Kubernetes Secret, no leading dot (hidden - skipped),
# no path separators.
_NAME = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]*")
_HASH_LINE = re.compile(r"sha256:([0-9a-f]{64})")


def _digest(token):
    return hashlib.sha256(token.encode("utf-8")).hexdigest()


def _is_loopback(host):
    if host == "localhost":
        return True
    try:
        return ipaddress.ip_address(host).is_loopback
    except ValueError:
        return False


# Seconds between the reads of the token files, by default.
DEFAULT_RELOAD_PERIOD = "5"


def _reload_period(value):
    # Seconds, or 'once' - 'math.inf': read at start, never again.
    if value == "once":
        return math.inf
    try:
        period = float(value)
    except ValueError:
        period = math.nan
    if not (0 < period < math.inf):
        sys.exit(f"Wrong MCP_AUTH_RELOAD_PERIOD '{value}', expected seconds (more than 0) or once.")
    return period


@dataclass(frozen=True)
class AuthSettings:
    mode: str
    tokens_dir: str
    reload_period: float

    @classmethod
    def from_env(cls, env=environ):
        mode = env.get("MCP_AUTH", "token")
        if mode not in ("token", "none"):
            sys.exit(f"Unknown MCP_AUTH '{mode}', expected token or none.")
        return cls(
            mode=mode,
            tokens_dir=env.get("MCP_AUTH_TOKENS", DEFAULT_TOKENS_DIR),
            reload_period=_reload_period(env.get("MCP_AUTH_RELOAD_PERIOD", DEFAULT_RELOAD_PERIOD)),
        )

    def validate(self, plain_http_host=None):
        # 'plain_http_host' - the listen address of the HTTP listener, if there
        # is one. Warnings only, besides the missing directory - with no tokens
        # the server starts and refuses, a token may come later.
        if self.mode == "none":
            log.warning("MCP_AUTH is 'none' - no authentication, whoever reaches a listener executes a code.")
            return
        if not os.path.isdir(self.tokens_dir):
            raise FileNotFoundError(errno.ENOENT, "MCP_AUTH_TOKENS directory does not exist", self.tokens_dir)
        # Read with the rights of the start - the server reads it again as
        # 'MCP_USER' and reports there, if that account can not (unless the
        # reload period is 'once').
        if not TokenStore(self.tokens_dir).names():
            log.warning(
                "No tokens in '%s' - every request is refused. Add a client: mcp-python-token add NAME",
                self.tokens_dir,
            )
        if plain_http_host is not None and not _is_loopback(plain_http_host):
            log.warning(
                "Bearer tokens over plain HTTP at '%s' - readable on the wire, unless TLS ends in front of the listener.",
                plain_http_host,
            )

    def server_kwargs(self):
        # Arguments of 'MCPServer' - none, when there is no authentication.
        # Called before the privileges drop: with 'once' the files are read
        # here, with the rights of the start, and never again.
        if self.mode == "none":
            return {}
        from mcp.server.auth.settings import AuthSettings as ServerAuthSettings

        store = TokenStore(self.tokens_dir, reload_interval=self.reload_period)
        if self.reload_period == math.inf:
            store.load()
        return dict(
            # The issuer is a must of the model, but there is no OAuth server
            # here - not used. No resource URL - no OAuth metadata routes.
            auth=ServerAuthSettings(issuer_url="http://localhost", resource_server_url=None),
            token_verifier=TokenVerifier(store),
        )


class TokenStore:
    """Directory of token files - a file per client, with the SHA-256 of its token."""

    def __init__(self, directory, reload_interval=5.0):
        self.directory = directory
        # Seconds a read of the directory is good for - a new or revoked
        # client is noticed in this time.
        self.reload_interval = reload_interval
        self._names = {}  # SHA-256 -> client name.
        self._loaded_at = None
        self._state = None

    @staticmethod
    def _check_name(name):
        if not _NAME.fullmatch(name):
            raise ValueError(f"Client name '{name}' - letters, digits, '.', '_' and '-' only, not starting with '.'.")

    def _path(self, name):
        self._check_name(name)
        return os.path.join(self.directory, name)

    @staticmethod
    def _read_hash(path):
        # The first line, which is not empty and not a comment.
        try:
            with open(path, encoding="ascii", errors="replace") as f:
                lines = f.read(4096).splitlines()
        except OSError:
            return None
        for line in lines:
            line = line.strip()
            if line and not line.startswith("#"):
                m = _HASH_LINE.fullmatch(line.lower())
                return m.group(1) if m else None
        return None

    def _read(self):
        # The clients (SHA-256 -> name) and the names of the files skipped.
        names, skipped = {}, []
        with os.scandir(self.directory) as entries:
            # Dot entries - not clients: '..data' of a Kubernetes Secret volume,
            # a file being written by 'add'. A file of such a volume is a link.
            for entry in sorted(entries, key=lambda e: e.name):
                if entry.name.startswith(".") or not entry.is_file():
                    continue
                digest = self._read_hash(entry.path) if _NAME.fullmatch(entry.name) else None
                if digest is None:
                    skipped.append(entry.name)
                else:
                    names[digest] = entry.name
        return names, skipped

    def _refresh(self):
        now = time.monotonic()
        if self._loaded_at is not None and now - self._loaded_at < self.reload_interval:
            return
        self._loaded_at = now
        try:
            names, skipped = self._read()
            state = (sorted(names.values()), skipped)
        except OSError as e:
            # Not readable - no clients: refuse, not serve the old ones.
            names, state = {}, str(e)
        self._names = names
        # The log - at a change only, not at every read.
        if state != self._state:
            self._state = state
            if isinstance(state, str):
                log.error("Tokens are not read, every request is refused - %s", state)
            else:
                for name in skipped:
                    log.warning("Token file '%s' is skipped - a wrong name, not readable or no 'sha256:<hex>' line.",
                                os.path.join(self.directory, name))
                log.info("Tokens of %d client(s) in '%s': %s", len(names), self.directory,
                         ", ".join(state[0]) or "none")

    def load(self):
        """Read the directory now. An unreadable one - 'OSError', not a store with no clients."""
        self._read()
        self._loaded_at = None
        self._refresh()

    def lookup(self, token):
        """The name of the client of the token, or None."""
        # A few small files, once per 'reload_interval' - read in place, also
        # under an event loop. The key is the hash of what the client sent -
        # nothing of a stored token is compared byte by byte.
        self._refresh()
        return self._names.get(_digest(token))

    def names(self):
        """The names of the clients, read now. An unreadable directory - 'OSError'."""
        names, _ = self._read()
        return sorted(names.values())

    def add(self, name):
        """Create the client and return its token - the only time it is known."""
        path = self._path(name)
        if os.path.lexists(path):
            raise FileExistsError(errno.EEXIST, "The client exists - remove it first", path)
        token = TOKEN_PREFIX + secrets.token_urlsafe(32)
        # Written aside (a dot file - skipped by a reading server), then
        # renamed - never seen half written. Readable by the account of the
        # server, whatever the umask is.
        aside = os.path.join(self.directory, f".{name}.new")
        fd = os.open(aside, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o644)
        try:
            with os.fdopen(fd, "w", encoding="ascii") as f:
                os.fchmod(f.fileno(), 0o644)
                f.write(f"# mcp-python - client '{name}', {date.today().isoformat()}. The SHA-256 of the token.\n")
                f.write(f"sha256:{_digest(token)}\n")
            os.rename(aside, path)
        except BaseException:
            os.unlink(aside)
            raise
        self._loaded_at = None
        return token

    def remove(self, name):
        """Revoke the client - its file is overwritten, then deleted."""
        path = self._path(name)
        # Overwritten in place, as 'shred' - what a file system and a disk do
        # with it is up to them. A hash only, so a second line of defence.
        with open(path, "r+b") as f:
            size = os.fstat(f.fileno()).st_size
            f.write(b"\0" * size)
            f.flush()
            os.fsync(f.fileno())
        os.unlink(path)
        self._loaded_at = None


class TokenVerifier:
    """The token verifier of the MCP SDK ('mcp.server.auth.provider.TokenVerifier') over a 'TokenStore'."""

    def __init__(self, store):
        self.store = store

    async def verify_token(self, token):
        from mcp.server.auth.provider import AccessToken

        name = self.store.lookup(token)
        if name is None:
            return None
        # The client name - the identity a session is bound to. No scopes, no
        # expiry - a token is good until its file is deleted.
        return AccessToken(token=token, client_id=name, scopes=[])

###
##
#

def main(argv=None):
    parser = argparse.ArgumentParser(
        prog="mcp-python-token",
        description="Clients of the MCP server 'mcp-python' - their bearer tokens. A running server notices"
                    " a change by itself, in a few seconds.",
    )
    parser.add_argument(
        "--dir",
        default=environ.get("MCP_AUTH_TOKENS", DEFAULT_TOKENS_DIR),
        help="directory of the token files - MCP_AUTH_TOKENS of the server (default: %(default)s)",
    )
    commands = parser.add_subparsers(dest="command", required=True, metavar="{add,list,remove}")
    commands.add_parser("add", help="create a client, print its token - once, it is not kept") \
        .add_argument("name")
    commands.add_parser("list", help="names of the clients")
    commands.add_parser("remove", help="revoke a client") \
        .add_argument("name")
    args = parser.parse_args(argv)

    store = TokenStore(args.dir)
    try:
        if args.command == "add":
            token = store.add(args.name)
            # The token alone at 'stdout' - for a redirect; the rest - 'stderr'.
            print(f"Client '{args.name}' - its token, shown this once (kept is the SHA-256 only):", file=sys.stderr)
            print(token)
        elif args.command == "list":
            for name in store.names():
                print(name)
        elif args.command == "remove":
            store.remove(args.name)
            print(f"Client '{args.name}' is removed.", file=sys.stderr)
    except (OSError, ValueError) as e:
        sys.exit(f"{parser.prog}: {e}")


if __name__ == "__main__":
    main()
