# check=skip=SecretsUsedInArgOrEnv
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

# Container image of "mcp-python" - MCP server, which runs a Python 3 code.
#
# Built by 'make container' - the build context is 'build/container', with
# the file tree of 'make install' in 'rootfs'. The layout of the image is
# the one of the installed Deb package; what 'debian/postinst' does at a
# host - the account, the scratch, the server virtual environment - is done
# here, at the image build.
#
# The Python minor version - the one of the reference virtual environment
# ('make build'), which 'requirements.lock' comes from.
#
# The first line - a directive of the build checks, it has to stay the
# first one: 'MCP_AUTH' and 'MCP_AUTH_TOKENS' of 'ENV' below are taken for
# secrets by their names. They are a mode and a path.

ARG BASE=python:3.12-slim-bookworm
FROM ${BASE}

# Before the sources - a change of them does not rebuild the environment.
COPY rootfs/usr/share/mcp-python/ /usr/share/mcp-python/

RUN adduser \
        --system \
        --group \
        --home /var/lib/mcp-python \
        --no-create-home \
        --shell /usr/sbin/nologin \
        --gecos "MCP server - Python 3" \
        mcp-python \
    && install --directory --owner=root --group=root --mode=0755 /var/lib/mcp-python \
    && install --directory --owner=mcp-python --group=mcp-python --mode=0700 /var/lib/mcp-python/scratch \
    && python3 -m venv /var/lib/mcp-python/venv \
    && /var/lib/mcp-python/venv/bin/python -m pip install \
        --no-cache-dir \
        --disable-pip-version-check \
        --no-input \
        --progress-bar off \
        --requirement /usr/share/mcp-python/requirements.txt \
        --constraint /usr/share/mcp-python/requirements.lock

COPY rootfs/ /

# The configuration - environment, see '/etc/mcp-python/mcp-python.conf' (a
# reference here, not read) for all the settings. Listens at all addresses
# of the container - which of the host, is up to '--publish'.
#
# Authentication - bearer tokens. The image has no clients, every request
# is refused - mount a directory of token files (see 'mcp_auth.py') at
# '/etc/mcp-python/tokens', read only.
ENV MCP_HOST=0.0.0.0 \
    MCP_HTTP_VARIANT=HTTP \
    MCP_USER=mcp-python \
    MCP_WORK_PYTHON=/usr/local/bin/python3 \
    MCP_SCRATCH=/var/lib/mcp-python/scratch \
    MCP_AUTH=token \
    MCP_AUTH_TOKENS=/etc/mcp-python/tokens

EXPOSE 8765 8766

# Not root - nothing to drop. For HTTPS, with a key the submitted code can
# not read: '--user root --cap-add SETUID --cap-add SETGID' - the server
# reads the key, then drops to MCP_USER itself.
USER mcp-python
WORKDIR /var/lib/mcp-python
ENTRYPOINT ["/var/lib/mcp-python/venv/bin/python", "/usr/lib/mcp-python/mcp-python.py"]
