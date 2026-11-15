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
# MCP server which runs a Python code, submitted by an MCP client - the
# launcher. The tools are in 'mcp_tools.py'. The configuration comes from
# the environment - the Systemd unit reads it from
# '/etc/mcp-python/mcp-python.conf'. It is read once, at start, into the
# settings objects ('ServeSettings', 'ToolSettings', 'AuthSettings').
#
# Authentication - bearer tokens, all of it is in 'mcp_auth.py'. Here are
# the two lines with 'auth' only.
#
# Listeners - HTTP, HTTPS or both ('MCP_HTTP_VARIANT'). Started as root,
# the server reads the TLS certificate and key into memory, then drops the
# privileges to 'MCP_USER' and only then serves - a submitted code runs as
# 'MCP_USER' and can not read the key file.
#
##

import asyncio
import errno
import os
import pwd
import signal
import sys
from dataclasses import dataclass
from os import environ

import uvicorn

from mcp_auth import AuthSettings
from mcp_tools import ToolSettings, build_server, env_int


@dataclass(frozen=True)
class ServeSettings:
    host: str
    port: int
    port_https: int
    http_variant: str
    tls_cert: str | None
    tls_key: str | None
    user: str | None

    @classmethod
    def from_env(cls, env=environ):
        http_variant = env.get("MCP_HTTP_VARIANT", "HTTP")
        if http_variant not in ("HTTP", "HTTPS", "both"):
            sys.exit(f"Unknown MCP_HTTP_VARIANT '{http_variant}', expected HTTP, HTTPS or both.")
        s = cls(
                host=env.get("MCP_HOST", "127.0.0.1"),
                port=env_int(env, "MCP_PORT", "8765"),
                port_https=env_int(env, "MCP_PORT_HTTPS", "8766"),
                http_variant=http_variant,
                tls_cert=env.get("MCP_TLS_CERT"),
                tls_key=env.get("MCP_TLS_KEY"),
                user=env.get("MCP_USER"),
            )
        s.validate()
        return s

    def validate(self):
        # TLS files - checked for reading only, not read: 'uvicorn.Config.load'
        # reads them later. Checked with the real UID - call before the
        # privileges drop, as the reader of the files.
        if self.http_variant in ("HTTPS", "both"):
            for name, path in (("MCP_TLS_CERT", self.tls_cert), ("MCP_TLS_KEY", self.tls_key)):
                if not path:
                    # Unset - uvicorn would serve plain HTTP at the HTTPS port.
                    raise ValueError(f"{name} is not set, but MCP_HTTP_VARIANT '{self.http_variant}' needs it.")
                if not os.path.exists(path):
                    raise FileNotFoundError(errno.ENOENT, f"{name} file does not exist", path)
                if not os.path.isfile(path) or not os.access(path, os.R_OK):
                    raise PermissionError(errno.EACCES, f"{name} file is not readable", path)

###
##
#

def _configs(mcp, serve):
    app = mcp.streamable_http_app(host=serve.host)
    log_level = mcp.settings.log_level.lower()
    configs = []
    if serve.http_variant in ("HTTP", "both"):
        configs.append(dict(port=serve.port))
    if serve.http_variant in ("HTTPS", "both"):
        configs.append(dict(port=serve.port_https, ssl_certfile=serve.tls_cert, ssl_keyfile=serve.tls_key))
    # The app lifespan (session manager) can run once only - at the first listener.
    return [
        uvicorn.Config(app,
                        host=serve.host,
                        log_level=log_level,
                        lifespan="on" if i == 0 else "off", 
                        **c)
        for i, c in enumerate(configs)
    ]


def _drop_privileges(user):
    if os.getuid() != 0:
        return
    if not user:
        sys.exit("Started as root, but MCP_USER is not set - refuse to serve as root.")
    pw = pwd.getpwnam(user)
    os.setgroups([])
    os.setgid(pw.pw_gid)
    os.setuid(pw.pw_uid)
    if os.getuid() == 0 or os.geteuid() == 0:
        sys.exit("Privileges drop failed.")
    environ.update(HOME=pw.pw_dir, USER=pw.pw_name, LOGNAME=pw.pw_name)


async def _serve(configs):
    servers = [uvicorn.Server(c) for c in configs]
    tasks = [asyncio.create_task(s.serve()) for s in servers]
    # One listener stops (signal, failure) - stop all.
    await asyncio.wait(tasks, return_when=asyncio.FIRST_COMPLETED)
    for s in servers:
        s.should_exit = True
    await asyncio.gather(*tasks)

###
##
#

if __name__ == "__main__":
    try:
        serve = ServeSettings.from_env()
        serve.validate()
        auth = AuthSettings.from_env()
        auth.validate(plain_http_host=serve.host if serve.http_variant != "HTTPS" else None)
        tools = ToolSettings.from_env()
        configs = _configs(build_server(tools, **auth.server_kwargs()), serve)
        for c in configs:
            c.load()  # Reads the certificate and key into an 'SSLContext' and needs corresponding priviledges. The privilidge drop is done later.
        _drop_privileges(serve.user)
        os.chdir(tools.scratch)
        asyncio.run(_serve(configs))
    except KeyboardInterrupt:
        # Stop signals - SIGINT (Ctrl C) and SIGTERM ('kill', 'systemctl stop').
        #
        # While serving, uvicorn handles both itself: on either signal it stops
        # accepting connections, finishes the requests in progress and runs the
        # application shutdown. Then it raises the same signal again, now with
        # the Python default handler in place, so the process ends "by the
        # signal":
        #
        # - SIGTERM - the default action ends the process at once. Systemd
        #   counts a death by SIGTERM as a clean stop. Nothing to do here.
        #
        # - SIGINT - Python turns it into the 'KeyboardInterrupt' exception.
        #   Uncaught, Python prints a traceback, which here means nothing - the
        #   stop was requested and has been done. So it is caught below, and the
        #   process exits with status 130 - the shell convention for "stopped by
        #   SIGINT" (128 + signal number 2).
        #
        # A Ctrl C before serving (configuration, TLS load, privileges drop) is
        # also a 'KeyboardInterrupt' - the same exit, no traceback. Only one in
        # the first fraction of a second, during the module imports above, is
        # outside of this 'try' and still prints a traceback.

        sys.exit(128 + signal.SIGINT)