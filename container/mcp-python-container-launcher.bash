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

##
# The common part of the launchers 'mcp-python-container' and
# 'mcp-python-compose' - sourced by them, not run. The server of the current
# user, in a container, with the secrets of the user:
#
#     ${MCP_DATA_DIR:-${XDG_DATA_HOME:-~/.local/share}/mcp-python}/
#         tls/tls.key, tls/tls.crt  - self-signed, for 'localhost',
#                                     '127.0.0.1' and the names of the host.
#         tokens/<client>           - the SHA-256 of the token, for the server.
#         clients/<client>.token    - the token itself, for a client.
#
# Made at a launch, if absent - only what is absent. The modes are set at
# each launch: the directories 0700, the key and the token files 0600 - the
# user only. The container starts as root, reads them before the privileges
# drop ('DAC_READ_SEARCH', 'MCP_AUTH_RELOAD_PERIOD=once') and serves as its
# account 'mcp-python' - a submitted code can not read them. A client added
# or removed - a restart of the server.
#
# The certificate is not put into the trusted ones here - a matter of its
# own. Neither is it renewed: an expired one is a warning; a new one - delete
# 'tls', launch again.
#
# Environment:
#
#     CONTAINER_TOOL    'docker' (default) or 'podman'.
#     MCP_CLIENT        The client name - default: the user name.
#     MCP_DATA_DIR      The directory of the secrets, see above.
#     MCP_IMAGE_TAG     The image tag - default: the version of the package.
#     MCP_PUBLISH_HOST  The host address of the listeners - default 127.0.0.1.
#     MCP_CPUS          CPUs limit - default 75% of the CPUs of the host.
#
# '@...@' - filled in at the package build ('container/Makefile'). In the
# source tree they stay: the tag is 'latest', the image of 'make container'.
#
##

MCPL_PACKAGE_NAME='mcp-python'
MCPL_PACKAGE_VERSION='@PACKAGE_VERSION@'

# The directory of this file - the compose file is here too. The '.run'
# file of the image - architecture dependent, in '/usr/lib' of the package.
MCPL_DIR_SHARE="$( dirname "$( readlink -f "${BASH_SOURCE[0]}" )" )"
MCPL_DIR_LIB=/usr/lib/mcp-python-container

CONTAINER_TOOL="${CONTAINER_TOOL:-docker}"
MCPL_CLIENT="${MCP_CLIENT:-$( id -un )}"
MCPL_DIR_DATA="${MCP_DATA_DIR:-${XDG_DATA_HOME:-${HOME}/.local/share}/${MCPL_PACKAGE_NAME}}"
MCPL_DIR_TLS="${MCPL_DIR_DATA}/tls"
MCPL_DIR_TOKENS="${MCPL_DIR_DATA}/tokens"
MCPL_DIR_CLIENTS="${MCPL_DIR_DATA}/clients"
MCPL_PUBLISH_HOST="${MCP_PUBLISH_HOST:-127.0.0.1}"
MCPL_CPUS="${MCP_CPUS:-$( nproc | awk '{ printf "%.2f", $1 * 0.75 }' )}"

if [[ "${MCPL_PACKAGE_VERSION}" == @*@ ]] ; then
    MCPL_IMAGE_TAG="${MCP_IMAGE_TAG:-latest}"
else
    MCPL_IMAGE_TAG="${MCP_IMAGE_TAG:-${MCPL_PACKAGE_VERSION}}"
fi
MCPL_IMAGE="${MCPL_PACKAGE_NAME}:${MCPL_IMAGE_TAG}"

# A name of the user for the names of the container and of the Compose
# project - lower case letters, digits, '-' and '_' only.
MCPL_INSTANCE="${MCPL_PACKAGE_NAME}-$( id -un | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9_\n-' '-' )"

mcpl_me="$( basename "$0" )"

mcpl_die() {
    echo "${mcpl_me}: $*" >&2
    exit 1
}

mcpl_note() {
    echo "${mcpl_me}: $*" >&2
}

##
# The names of the certificate - 'localhost', '127.0.0.1', the full and the
# short name of the host (one, if they are the same).
#
mcpl_tls_names() {
    local full short
    full="$( hostname -f 2>/dev/null || true )"
    short="$( hostname -s 2>/dev/null || hostname )"
    local names="DNS:localhost,IP:127.0.0.1"
    local n
    for n in "${full}" "${short}" ; do
        if [[ -n "${n}" && "${n}" != "localhost" && ",${names}," != *",DNS:${n},"* ]] ; then
            names+=",DNS:${n}"
        fi
    done
    echo "${names}"
}

mcpl_tls() {
    local key="${MCPL_DIR_TLS}/tls.key"
    local crt="${MCPL_DIR_TLS}/tls.crt"
    if [[ ! -e "${key}" ]] ; then
        # A new key - the certificate of the old one is of no use.
        rm -f "${crt}"
        openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "${key}.new" 2>/dev/null
        mv "${key}.new" "${key}"
        mcpl_note "Made the TLS key '${key}'."
    fi
    if [[ ! -e "${crt}" ]] ; then
        local names
        names="$( mcpl_tls_names )"
        openssl req -x509 \
            -new \
            -key "${key}" \
            -days 365 \
            -subj "/CN=localhost" \
            -addext "subjectAltName=${names}" \
            -out "${crt}.new"
        mv "${crt}.new" "${crt}"
        mcpl_note "Made the TLS certificate '${crt}' - ${names}. Not trusted by the clients yet."
    fi
    if ! openssl x509 -in "${crt}" -noout -checkend 0 >/dev/null ; then
        mcpl_note "The TLS certificate '${crt}' has expired - delete '${MCPL_DIR_TLS}' and launch again for a new one."
    fi
}

##
# The token of the client and its file for the server. The format - the one
# of 'mcp-python-token' ('mcp_auth.py'): 'mcpp_' and 32 random bytes, Base64
# for URL; the file - a comment and 'sha256:<hex>'.
#
mcpl_tokens() {
    [[ "${MCPL_CLIENT}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] \
        || mcpl_die "Client name '${MCPL_CLIENT}' - letters, digits, '.', '_' and '-' only, not starting with '.'. Set MCP_CLIENT."
    local hash_file="${MCPL_DIR_TOKENS}/${MCPL_CLIENT}"
    local token_file="${MCPL_DIR_CLIENTS}/${MCPL_CLIENT}.token"
    if [[ ! -e "${token_file}" ]] ; then
        if [[ -e "${hash_file}" ]] ; then
            mcpl_note "No '${token_file}' for '${hash_file}' - the token is not known. For a new one delete '${hash_file}' and launch again."
            return 0
        fi
        local token
        token="mcpp_$( head -c 32 /dev/urandom | base64 | tr '+/' '-_' | tr -d '=\n' )"
        printf '%s\n' "${token}" > "${token_file}.new"
        mv "${token_file}.new" "${token_file}"
        mcpl_note "Made the token of the client '${MCPL_CLIENT}' - '${token_file}'."
    fi
    if [[ ! -e "${hash_file}" ]] ; then
        local digest
        digest="$( head -n 1 "${token_file}" | tr -d '\n' | sha256sum | cut -d ' ' -f 1 )"
        {
            echo "# mcp-python - client '${MCPL_CLIENT}', $( date +%F ). The SHA-256 of the token."
            echo "sha256:${digest}"
        } > "${hash_file}.new"
        mv "${hash_file}.new" "${hash_file}"
    fi
}

##
# The secrets - the absent ones made, the modes of all of them set.
#
mcpl_secrets() {
    local old_umask
    old_umask="$( umask )"
    umask 077
    mkdir -p "${MCPL_DIR_TLS}" "${MCPL_DIR_TOKENS}" "${MCPL_DIR_CLIENTS}"
    chmod 700 "${MCPL_DIR_DATA}" "${MCPL_DIR_TLS}" "${MCPL_DIR_TOKENS}" "${MCPL_DIR_CLIENTS}"
    mcpl_tls
    mcpl_tokens
    chmod 600 "${MCPL_DIR_TLS}/tls.key"
    chmod 644 "${MCPL_DIR_TLS}/tls.crt"
    find "${MCPL_DIR_TOKENS}" "${MCPL_DIR_CLIENTS}" -mindepth 1 -maxdepth 1 -type f -exec chmod 600 {} +
    umask "${old_umask}"
}

##
# The image - loaded from the '.run' file of the package, if absent.
#
mcpl_image() {
    command -v "${CONTAINER_TOOL}" >/dev/null 2>&1 \
        || mcpl_die "No '${CONTAINER_TOOL}' - install it, or set CONTAINER_TOOL."
    if "${CONTAINER_TOOL}" image inspect "${MCPL_IMAGE}" >/dev/null 2>&1 ; then
        return 0
    fi
    local run="${MCPL_DIR_LIB}/${MCPL_PACKAGE_NAME}_${MCPL_IMAGE_TAG}_container.run"
    [[ -e "${run}" ]] \
        || mcpl_die "No image '${MCPL_IMAGE}' and no '${run}' to load it from - 'make container' in the source tree, or set MCP_IMAGE_TAG."
    mcpl_note "No image '${MCPL_IMAGE}' - loading it from '${run}'."
    CONTAINER_TOOL="${CONTAINER_TOOL}" sh "${run}"
}

##
# How to check a listener - 401 without the header.
#
mcpl_hints() {
    local scheme_port scheme port
    mcpl_note "The client '${MCPL_CLIENT}'. Check - 401 without the header:"
    for scheme_port in "$@" ; do
        scheme="${scheme_port%:*}"
        port="${scheme_port#*:}"
        if [[ "${scheme}" == "https" ]] ; then
            echo "    curl -I -H \"Authorization: Bearer \$( cat '${MCPL_DIR_CLIENTS}/${MCPL_CLIENT}.token' )\" --cacert '${MCPL_DIR_TLS}/tls.crt' https://localhost:${port}/mcp" >&2
        else
            echo "    curl -I -H \"Authorization: Bearer \$( cat '${MCPL_DIR_CLIENTS}/${MCPL_CLIENT}.token' )\" http://127.0.0.1:${port}/mcp" >&2
        fi
    done
}
