#!/bin/sh
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
# Container image of "@PACKAGE_NAME@" @PACKAGE_VERSION@ - a self-extracting
# archive. This script, then, after the line '__PAYLOAD_BELOW__', the image:
# 'docker save' of '@PACKAGE_NAME@:@PACKAGE_VERSION@' and
# '@PACKAGE_NAME@:latest', compressed by gzip. Made by 'make
# container-package' ('container/Makefile', the header is
# 'container/sfx-header.sh' there).
#
# The image is loaded into the local Docker - no registry needed:
#
#     sh THIS-FILE
#
# Podman instead of Docker:
#
#     CONTAINER_TOOL=podman sh THIS-FILE
#
# The image archive only, '@PAYLOAD_NAME@' in DIR, not loaded:
#
#     sh THIS-FILE --extract DIR
#
# By hand, with no this script - the payload starts at the line after the
# marker:
#
#     tail -n "+$(( $( grep --text --line-number --max-count=1 '^__PAYLOAD_BELOW__$' THIS-FILE | cut -d : -f 1 ) + 1 ))" THIS-FILE > image.tar.gz
#     docker load --input image.tar.gz
#
##

set -eu

PACKAGE_NAME='@PACKAGE_NAME@'
PACKAGE_VERSION='@PACKAGE_VERSION@'
PAYLOAD_NAME='@PAYLOAD_NAME@'
PAYLOAD_SHA256='@PAYLOAD_SHA256@'
CONTAINER_TOOL="${CONTAINER_TOOL:-docker}"

self="${0}"
me="$( basename "${self}" )"

usage() {
    cat <<EOF
Usage: sh ${me} [--extract DIR | --check | --help]

Container image '${PACKAGE_NAME}:${PACKAGE_VERSION}' (and '${PACKAGE_NAME}:latest').

  (no option)     Load the image into the local '${CONTAINER_TOOL}' - '${CONTAINER_TOOL} load'.
  --extract DIR   Write the image archive '${PAYLOAD_NAME}' into DIR, no load.
  --check         Check the SHA-256 of the image archive, no load.
  --help          This text.

Environment: CONTAINER_TOOL - 'docker' (default) or 'podman'.
EOF
}

die() {
    echo "${me}: ${*}" >&2
    exit 1
}

# The first line of the payload - the one after the marker. Read as text up
# to the marker only, the binary after it is not parsed.
payload_line() {
    awk '/^__PAYLOAD_BELOW__$/ { print NR + 1 ; found = 1 ; exit } END { if (!found) exit 1 }' "${self}" \
        || die "No payload marker - the file is damaged."
}

# The payload into the file $1, its SHA-256 checked.
payload_extract() {
    line="$( payload_line )"
    tail -n "+${line}" "${self}" > "$1"
    if command -v sha256sum >/dev/null 2>&1 ; then
        actual="$( sha256sum -b "$1" | cut -d ' ' -f 1 )"
    elif command -v shasum >/dev/null 2>&1 ; then
        actual="$( shasum -a 256 -b "$1" | cut -d ' ' -f 1 )"
    else
        echo "${me}: Neither 'sha256sum' nor 'shasum' - the payload is not checked." >&2
        return 0
    fi
    [ "${actual}" = "${PAYLOAD_SHA256}" ] \
        || die "The payload SHA-256 is '${actual}', expected '${PAYLOAD_SHA256}' - the file is damaged."
}

# A directory of temporary files, removed at the exit.
tmp_dir=''
tmp_dir_make() {
    tmp_dir="$( mktemp -d "${TMPDIR:-/tmp}/${PACKAGE_NAME}-image.XXXXXX" )"
    trap 'rm -rf "${tmp_dir}"' EXIT
    trap 'exit 1' HUP INT TERM
}

action='load'
dir_extract=''
while [ "${#}" -gt 0 ] ; do
    case "${1}" in
        --extract)
            [ "${#}" -ge 2 ] || die "No directory after '--extract'."
            action='extract'
            dir_extract="${2}"
            shift 2
            ;;
        --check)
            action='check'
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            usage >&2
            die "Unknown argument '${1}'."
            ;;
    esac
done

case "${action}" in
    extract)
        [ -d "${dir_extract}" ] || die "No directory '${dir_extract}'."
        payload_extract "${dir_extract}/${PAYLOAD_NAME}"
        echo "${me}: Written '${dir_extract}/${PAYLOAD_NAME}'. Load it:"
        echo "    ${CONTAINER_TOOL} load --input '${dir_extract}/${PAYLOAD_NAME}'"
        ;;
    check)
        tmp_dir_make
        payload_extract "${tmp_dir}/${PAYLOAD_NAME}"
        echo "${me}: The payload is intact."
        ;;
    load)
        command -v "${CONTAINER_TOOL}" >/dev/null 2>&1 \
            || die "No '${CONTAINER_TOOL}' - install it, or set CONTAINER_TOOL."
        tmp_dir_make
        payload_extract "${tmp_dir}/${PAYLOAD_NAME}"
        "${CONTAINER_TOOL}" load --input "${tmp_dir}/${PAYLOAD_NAME}"
        echo "${me}: Loaded '${PACKAGE_NAME}:${PACKAGE_VERSION}' and '${PACKAGE_NAME}:latest'."
        ;;
esac

# Not a step further - the payload follows.
exit
__PAYLOAD_BELOW__
