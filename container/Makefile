#!/usr/bin/env -S "make" "--debug=vm" "--makefile"
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
# Container image of "mcp-python" - the build, a launch by 'docker run' or
# by Docker Compose, and the image as a self-extracting archive. Run here
# ('make -C container ...') or from the project root - the targets have the
# same names there ('make container', 'make container-...', 'make
# compose-...').
#
##
#
# Typical usage, at the project root:
#
#     make container                  # The image, '<name>:<version>' and '<name>:latest'.
#     make container-launch           # HTTP and HTTPS at 127.0.0.1:8765, 8766, until Ctrl C.
#     make compose-launch             # HTTPS at 127.0.0.1:8766, in background.
#     make compose-log                # Its log, until Ctrl C.
#     make compose-stop               # Stopped and removed.
#
# The launches - by the launchers of this directory, 'mcp-python-container'
# and 'mcp-python-compose' (see mcp-python-container(1),
# mcp-python-compose(1)), with the secrets of the development tree - see
# 'DIR_BUILD_DATA' in 'variables.mk'. The check of a listener - printed at
# the start.
#
# The image as one file - no registry needed, see 'container-package' below:
#
#     make container-package          # 'artifacts/<name>_<version>_container.run'
#     sh mcp-python_<version>_container.run   # At the target host - 'docker load'.
#
# The same, as the Deb package '$(PACKAGE_NAME_CONTAINER)' ('debian-container'),
# the '.run' file in '/usr/lib/<package>'. Parent 'Makefile' may call a targets
# from this 'Makefile' for a packaging.
#
# Podman instead of Docker:
#
#     make container CONTAINER_TOOL=podman
#
# Without the rules at the root - 'make -C container container-launch' and
# so on.
#
##

SHELL := /usr/bin/bash
.ONESHELL:

# The variables of the project - the same as at the root, with the paths
# relative to the root: here they are used as '$(DIR_ROOT)/...'.
include ../variables.mk

DIR_BUILD_CONTAINER := $(DIR_ROOT)/$(DIR_BUILD)/container
DIR_BUILD_PACKAGE := $(DIR_ROOT)/$(DIR_BUILD)/container-package

# 'docker' or 'podman' - for the launchers too.
export CONTAINER_TOOL ?= docker

# The self-extracting archive - the header (a shell script) and the image
# after it ('container-package').
SFX_HEADER := sfx-header.sh
SFX_NAME := $(PACKAGE_NAME)_$(PACKAGE_VERSION)_container.run

# The Deb package of the image - its 'debian' directory and the stage it is
# built in ('container-package-deb').
DIR_DEBIAN := $(DIR_ROOT)/debian-container
DIR_BUILD_DEB := $(DIR_ROOT)/$(DIR_BUILD)/deb-container

.PHONY: build rootfs rootfs-clean container container-launch container-package deb-version-check container-package-deb compose-launch compose-log compose-stop

##
# The targets of the root 'Makefile'. A target of its own each: with
# '.ONESHELL' a recipe with '$$(MAKE)' is one line, and 'make -n' runs such a
# line - the whole recipe - instead of printing it.
#
build:
	$(MAKE) --directory=.. build

##
# Container image - the file tree of 'make install' at the root, staged into
# the image build context ('rootfs'), is copied into the image as is. The
# server virtual environment is created at the image build ('Dockerfile').
#
container: rootfs
	@PS4="●:make:$(@): "
	set -xeu
	$(CONTAINER_TOOL) build \
	    --file Dockerfile \
	    --tag "$(PACKAGE_NAME):$(PACKAGE_VERSION)" \
	    --tag "$(PACKAGE_NAME):latest" \
	    "$(DIR_BUILD_CONTAINER)"

	true : Job done.

# The build context - anew each time. The '$$(MAKE)' line alone in its
# recipe, as 'build' above.
rootfs: build rootfs-clean
	$(MAKE) --directory=.. install DESTDIR="$(abspath $(DIR_BUILD_CONTAINER))/rootfs" INSTALL_OWNER=

rootfs-clean:
	@PS4="●:make:$(@): "
	set -xeu
	test "$(DIR_BUILD_CONTAINER)" != '/' || exit 1
	rm -rf "$(DIR_BUILD_CONTAINER)"

	true : Job done.

##
# Container launch - 'mcp-python-container', in the foreground.
#
container-launch: container
	@PS4="●:make:$(@): "
	set -xeu
	exec ./mcp-python-container

	true : Job done.

##
# The image as a self-extracting archive - '<name>_<version>_container.run'
# in 'artifacts' of the root, with the hash file. A shell script
# ('sfx-header.sh'), then, after its line '__PAYLOAD_BELOW__', the image -
# 'docker save' of both tags, '<version>' and 'latest', compressed by gzip.
# At the target host - no registry, no source tree:
#
#     sh mcp-python_<version>_container.run              # 'docker load' of the image.
#     sh mcp-python_<version>_container.run --extract .  # The '.tar.gz' only, no load.
#     sh mcp-python_<version>_container.run --help
#
# The image is built anew first - the archive has the image of this source
# tree, not an older one with the same tag.
#
container-package: container
	@PS4="●:make:$(@): "
	set -xeu -o pipefail
	test "$(DIR_BUILD_PACKAGE)" != '/' || exit 1
	rm -rf "$(DIR_BUILD_PACKAGE)"
	mkdir -p "$(DIR_BUILD_PACKAGE)"
	if [ ! -d "$(DIR_ROOT)/$(DIR_ARTIFACTS)" ] ; then mkdir "$(DIR_ROOT)/$(DIR_ARTIFACTS)" ; fi

	payload="$(PACKAGE_NAME)_$(PACKAGE_VERSION)_image.tar.gz"
	# Into a file, not to the standard output - 'podman save' wants it so.
	$(CONTAINER_TOOL) save \
	    --output "$(DIR_BUILD_PACKAGE)/image.tar" \
	    "$(PACKAGE_NAME):$(PACKAGE_VERSION)" \
	    "$(PACKAGE_NAME):latest"
	gzip -9 --no-name --stdout "$(DIR_BUILD_PACKAGE)/image.tar" > "$(DIR_BUILD_PACKAGE)/$${payload}"
	payload_sha256="$$( sha256sum -b "$(DIR_BUILD_PACKAGE)/$${payload}" | cut -d ' ' -f 1 )"

	# The values of the header - none of them has '#' or '&' of 'sed'.
	sed \
	    -e "s#@PACKAGE_NAME@#$(PACKAGE_NAME)#g" \
	    -e "s#@PACKAGE_VERSION@#$(PACKAGE_VERSION)#g" \
	    -e "s#@PAYLOAD_NAME@#$${payload}#g" \
	    -e "s#@PAYLOAD_SHA256@#$${payload_sha256}#g" \
	    "$(SFX_HEADER)" > "$(DIR_BUILD_PACKAGE)/header.sh"
	# The header is a script on its own too - a syntax error is found here,
	# not at the target host.
	sh -n "$(DIR_BUILD_PACKAGE)/header.sh"
	test "$$( tail -n 1 "$(DIR_BUILD_PACKAGE)/header.sh" )" = "__PAYLOAD_BELOW__"

	cat "$(DIR_BUILD_PACKAGE)/header.sh" "$(DIR_BUILD_PACKAGE)/$${payload}" > "$(DIR_BUILD_PACKAGE)/$(SFX_NAME)"
	chmod 755 "$(DIR_BUILD_PACKAGE)/$(SFX_NAME)"
	# The payload, as the header cuts it out, is the one packed.
	sh "$(DIR_BUILD_PACKAGE)/$(SFX_NAME)" --check

	mv --force "$(DIR_BUILD_PACKAGE)/$(SFX_NAME)" "$(DIR_ROOT)/$(DIR_ARTIFACTS)/"
	rm -rf "$(DIR_BUILD_PACKAGE)"
	cd "$(DIR_ROOT)/$(DIR_ARTIFACTS)"
	sha256sum -b "$(SFX_NAME)" > "$(SFX_NAME).sha256"

	true : Job done.

##
# The versions of both changelogs - the one of 'debian-container' is kept by
# hand, the image is of the one of 'debian'. A target of its own - a
# mismatch stops 'container-package-deb' before the long image build.
#
deb-version-check:
	@PS4="●:make:$(@): "
	set -xeu
	version="$$( dpkg-parsechangelog --file "$(DIR_DEBIAN)/changelog" -S Version )"
	if [ "$${version}" != "$(PACKAGE_VERSION)" ] ; then
	    { set +x ; } 2>/dev/null
	    echo "○:make:$(@): The version of 'debian-container/changelog' is '$${version}', of 'debian/changelog' - '$(PACKAGE_VERSION)'. Add an entry:" >&2
	    echo "    dch --changelog debian-container/changelog --newversion '$(PACKAGE_VERSION)'" >&2
	    exit 1
	fi

	true : Job done.

##
# The Deb package '$(PACKAGE_NAME_CONTAINER)' - '<package>_<version>_<arch>.deb'
# in 'artifacts' of the root, with the hash file. Built in a stage of its
# own, where 'debian-container' is 'debian' - see
# 'debian-container/README.source'. The architecture is the one of this
# host, as the one of the image is.
#
container-package-deb: deb-version-check container-package
	@PS4="●:make:$(@): "
	set -xeu
	stage="$(DIR_BUILD_DEB)/$(PACKAGE_NAME_CONTAINER)-$(PACKAGE_VERSION)"
	test "$(DIR_BUILD_DEB)" != '/' || exit 1
	rm -rf "$(DIR_BUILD_DEB)"
	mkdir -p "$${stage}/container"
	# '-L' - the symbolic links to the files of 'debian' become the files.
	cp -rL "$(DIR_DEBIAN)" "$${stage}/debian"
	cp -r . "$${stage}/container/"
	# The version of the image - for the launchers.
	sed -i "s#@PACKAGE_VERSION@#$(PACKAGE_VERSION)#g" "$${stage}/container/mcp-python-container-launcher.bash"
	cp "$(DIR_ROOT)/$(DIR_ARTIFACTS)/$(SFX_NAME)" "$${stage}/"

	( cd "$${stage}" && fakeroot dpkg-buildpackage -b -us -uc )

	mv --force "$(DIR_BUILD_DEB)/$(PACKAGE_NAME_CONTAINER)_$(PACKAGE_VERSION)_"*".deb"       "$(DIR_ROOT)/$(DIR_ARTIFACTS)/"
	mv --force "$(DIR_BUILD_DEB)/$(PACKAGE_NAME_CONTAINER)_$(PACKAGE_VERSION)_"*".changes"   "$(DIR_ROOT)/$(DIR_ARTIFACTS)/"
	mv --force "$(DIR_BUILD_DEB)/$(PACKAGE_NAME_CONTAINER)_$(PACKAGE_VERSION)_"*".buildinfo" "$(DIR_ROOT)/$(DIR_ARTIFACTS)/"
	rm -rf "$(DIR_BUILD_DEB)"
	cd "$(DIR_ROOT)/$(DIR_ARTIFACTS)"
	for f in "$(PACKAGE_NAME_CONTAINER)_$(PACKAGE_VERSION)_"*".deb" ; do
	    sha256sum -b "$${f}" > "$${f}.sha256"
	done

	true : Job done.

##
# Docker Compose launch - 'mcp-python-compose', in the background.
#
compose-launch: container
	@PS4="●:make:$(@): "
	set -xeu
	./mcp-python-compose up

	true : Job done.

compose-log:
	@PS4="●:make:$(@): "
	set -xeu
	exec ./mcp-python-compose logs --follow --timestamps --tail 100

	true : Job done.

compose-stop:
	@PS4="●:make:$(@): "
	set -xeu
	./mcp-python-compose down

	true : Job done.
