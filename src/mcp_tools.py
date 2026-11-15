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
# The MCP part - tools, which run a Python code, submitted by an MCP
# client, with the 'workload' interpreter. Each call is a separate process
# (no state between calls). The settings come from the environment, once,
# at start ('ToolSettings.from_env') and are passed to 'build_server'.
#
##

import asyncio
import sys
from dataclasses import dataclass
from os import environ
from tempfile import TemporaryDirectory

from mcp.server.mcpserver import MCPServer


def env_int(env, name, default):
    value = env.get(name, default)
    try:
        return int(value)
    except ValueError:
        sys.exit(f"{name} '{value}' is not an integer.")


@dataclass(frozen=True)
class ToolSettings:
    work_python: str
    scratch: str
    exec_timeout: int
    output_limit: int

    @classmethod
    def from_env(cls, env=environ):
        return cls(
            work_python=env.get("MCP_WORK_PYTHON", "python3"),
            scratch=env.get("MCP_SCRATCH", "/tmp"),
            exec_timeout=env_int(env, "MCP_EXEC_TIMEOUT", "60"),
            output_limit=env_int(env, "MCP_OUTPUT_LIMIT", "65536"),
        )


def _cut(b, limit):
    s = b.decode("utf-8", errors="replace")
    if len(s) > limit:
        return s[:limit] + f"\n... [truncated, {len(s) - limit} more characters]"
    return s


async def _exec(args, timeout, settings):
    with TemporaryDirectory(dir=settings.scratch) as cwd:
        proc = await asyncio.create_subprocess_exec(
            *args,
            cwd=cwd,
            stdin=asyncio.subprocess.DEVNULL,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
        )
        try:
            out, err = await asyncio.wait_for(proc.communicate(), timeout)
            timed_out = False
        except asyncio.TimeoutError:
            proc.kill()
            out, err = await proc.communicate()
            timed_out = True
    return {
        "returncode": proc.returncode,
        "stdout": _cut(out, settings.output_limit),
        "stderr": _cut(err, settings.output_limit),
        "timed_out": timed_out,
    }


def build_server(settings, **server_kwargs):
    # 'server_kwargs' - more arguments of 'MCPServer', as is: the
    # authentication ('mcp_auth.py'), if any.
    mcp = MCPServer(
        "python3",
        instructions="Runs Python 3 code on the host. Each 'run_python' call is a fresh interpreter process; print results to stdout.",
        **server_kwargs,
    )

    @mcp.tool()
    async def run_python(code: str, timeout_s: int = 30) -> dict:
        """Run Python 3 code in a fresh interpreter process and return its stdout, stderr and exit code.

        The working directory is an empty temporary directory, removed after the call.
        'timeout_s' is capped by the server limit.
        """
        timeout = max(1, min(timeout_s, settings.exec_timeout))
        return await _exec([settings.work_python, "-I", "-c", code], timeout, settings)

    @mcp.tool()
    async def python_info() -> dict:
        """Report the interpreter version and the installed packages available to 'run_python'."""
        py = settings.work_python
        version = await _exec([py, "-I", "-c", "import sys; print(sys.version)"], settings.exec_timeout, settings)
        packages = await _exec([py, "-I", "-m", "pip", "list", "--format=freeze"], settings.exec_timeout, settings)
        return {"version": version["stdout"].strip(), "packages": packages["stdout"].split()}

    return mcp
