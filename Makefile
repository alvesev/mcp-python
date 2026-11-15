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

SHELL := /usr/bin/bash

# '.ONESHELL' is preventing 'make -n ...' approach.
.ONESHELL:

# One target at a time, the prerequisites in their order, even with 'make
# -j': the packaging targets share the source tree ('dpkg-buildpackage',
# 'debian/rules clean', '$(DIR_BUILD)'), and 'release' asks first by the order
# of its prerequisites. A 'make' of a sub-directory runs in parallel, if asked.
.NOTPARALLEL:

# The variables shared with the 'Makefile' of the sub-directories.
include variables.mk


export VCS_TAG := $(PACKAGE_NAME)_$(PACKAGE_VERSION)

export FILE_STORE_PATHS_LIST := store-paths
export DIR_ORIGIN := src
export DIR_LIB := /usr/lib/$(PACKAGE_NAME)
export DIR_SHARE := /usr/share/$(PACKAGE_NAME)
export DIR_MAN8 := /usr/share/man/man8
export DIR_BUILD_VENV := $(DIR_BUILD)/venv

# Owner of the installed files. Empty - for a staging as a regular user
# ('make container', 'container/Makefile').
INSTALL_OWNER ?= --owner=root --group=root

#all: clean-all compile package

.PHONY: clean clean-all generate-rel-info install package package-src package-deb package-deb-src package-deb-container package-deb-chart package-helm release release-ask unrelease build dev-launch container secrets tls-cert tls-install tls-uninstall auth-token

clean:
	@PS4="●:make:$(@): "
	set -xeu
	rm -rf "debian/$(PACKAGE_NAME)"
	rm -rf debian/stamp-makefile-*
	rm -rf debian/*.substvars
	rm -rf debian/*.debhelper
	rm -rf debian/.debhelper
	rm -rf debian/files

	true : Job done.

clean-all: clean
	@PS4="●:make:$(@): "
	set -xeu
	test "$(DIR_BUILD)" != '/' || exit 1
	rm -rf $(DIR_BUILD)

	true : Job done.

##
#	TODO - separate release notes generation????
#
generate-rel-info:
	@PS4="●:make:$(@): "
	set -xeu

	if [ -e /etc/lsb-release ] ; then source /etc/lsb-release ; fi
	if [ -e /etc/os-release ] ; then source /etc/os-release ; fi

	export distro_code_name="$${DISTRIB_CODENAME:-undefined-distro-codename}"

	export pack_promote_deadline="low"

	export DEBCHANGE_RELEASE_HEURISTIC="changelog"
	export DEBFULLNAME="No Name"
	export DEBEMAIL="noname@nohost"  # 'EMAIL' variable can be set too.

	dch \
	    --newversion "$${PACKAGE_VERSION}" \
	    --distribution "$${distro_code_name}" \
	    --urgency "$${pack_promote_deadline}" \
	    --force-distribution \
	    "Release notes item."

	# The changelog of the container package - the same version, see
	# 'debian-container/README.source'.
	dch \
	    --changelog debian-container/changelog \
	    --newversion "$${PACKAGE_VERSION}" \
	    --distribution "$${distro_code_name}" \
	    --urgency "$${pack_promote_deadline}" \
	    --force-distribution \
	    "Release notes item."

	# The changelog of the chart package - the same version, see
	# 'debian-chart/README.source'.
	dch \
	    --changelog debian-chart/changelog \
	    --newversion "$${PACKAGE_VERSION}" \
	    --distribution "$${distro_code_name}" \
	    --urgency "$${pack_promote_deadline}" \
	    --force-distribution \
	    "Release notes item."

	git diff   debian/changelog  debian-container/changelog  debian-chart/changelog
	git status debian/changelog  debian-container/changelog  debian-chart/changelog

	true : Job done.


##
# The server virtual environment - built here as a reference only: its
# exact package set ('pip freeze') is packaged as 'requirements.lock'. The
# environment itself is created at the target OS, by 'postinst', with the
# interpreter there.
#
build: $(DIR_BUILD_VENV)
$(DIR_BUILD_VENV):
	@PS4="●:make:$(@): "
	set -xeu
	mkdir -p "$(DIR_BUILD)"
	rm -rf "$(DIR_BUILD_VENV)"
	python3 -m venv "$(DIR_BUILD_VENV)"
	"$(DIR_BUILD_VENV)/bin/pip" install --no-cache-dir --disable-pip-version-check \
	    --requirement "$(DIR_ORIGIN)/requirements.txt"
	{
	    echo "# Package set of the reference virtual environment, built with $$( "$(DIR_BUILD_VENV)/bin/python" --version )."
	    "$(DIR_BUILD_VENV)/bin/pip" freeze --disable-pip-version-check
	} > "$(DIR_BUILD)/requirements.lock"

	true : Job done.

##
# The secrets of the development tree - the TLS certificate (self-signed, for
# 'localhost', '127.0.0.1' and the names of this host), the token files and
# the token of the client 'dev', in '$(DIR_BUILD_DATA)'. Made by the
# launcher ('mcp-python-container secrets') - only the absent ones; kept
# until 'make clean-all'. More clients:
#
#   MCP_CLIENT=NAME container/mcp-python-container secrets
#
# 'tls-cert' and 'auth-token' - the same, the names of before.
#
secrets tls-cert auth-token:
	@PS4="●:make:$(@): "
	set -xeu
	container/mcp-python-container secrets

	true : Job done.

tls-install: secrets
	@PS4="●:make:$(@): "
	set -xeu

	# The name - '.crt' is a must, 'update-ca-certificates' skips the rest.
	sudo install --owner=root --group=root --mode=644 --verbose \
	    "$(DIR_BUILD_DATA)/tls/tls.crt" \
	    "/usr/local/share/ca-certificates/$(PACKAGE_NAME).crt"
	sudo update-ca-certificates

	true : Job done.

tls-uninstall:
	@PS4="●:make:$(@): "
	set -xeu

	sudo rm --force --verbose "/usr/local/share/ca-certificates/$(PACKAGE_NAME).crt"
	sudo update-ca-certificates --fresh  # '--fresh' - the links of the store are built anew, so the one of the removed certificate is gone.

	true : Job done.

##
# Development launch - both HTTP and HTTPS, at the local host only, as the
# current user, with the interpreter of the reference virtual environment
# ('make build'). The secrets - the ones of 'make secrets'; without
# authentication - 'MCP_AUTH=none make dev-launch'.
#
dev-launch: build secrets
	@PS4="●:make:$(@): "
	set -xeu
	test -x "$(DIR_BUILD_VENV)/bin/python" || { echo "No '$(DIR_BUILD_VENV)' - run 'make build' first." >&2 ; exit 1 ; }
	dev="$(DIR_BUILD)/dev"
	mkdir -p "$${dev}/scratch"

	# The paths of the secrets - 'MCP_TLS_CERT', 'MCP_TLS_KEY',
	# 'MCP_AUTH_TOKENS', 'MCP_CLIENT_TOKEN'.
	set -a
	source <( container/mcp-python-container secrets 2>/dev/null )
	set +a
	export MCP_HOST=127.0.0.1
	export MCP_HTTP_VARIANT=both
	export MCP_SCRATCH="$$(realpath "$${dev}/scratch")"
	export MCP_WORK_PYTHON="$${MCP_WORK_PYTHON:-python3}"
	export MCP_AUTH="$${MCP_AUTH:-token}"

	{ set +x ; } 2>/dev/null
	echo "○:make:$(@): Check the listeners - 401 without the header:"
	echo "    curl -I -H \"Authorization: Bearer \$$( cat '$${MCP_CLIENT_TOKEN}' )\" http://$${MCP_HOST}:8765/mcp"
	echo "    curl -I -H \"Authorization: Bearer \$$( cat '$${MCP_CLIENT_TOKEN}' )\" --cacert '$${MCP_TLS_CERT}' https://$${MCP_HOST}:8766/mcp"
	set -x

	exec "$(DIR_BUILD_VENV)/bin/python" "$(DIR_ORIGIN)/mcp-python.py"

	true : Job done.

##
# The file tree of the server - for the Deb package ('debian/rules') and for
# the container image ('make container'). The Systemd unit is not here - it
# belongs to the Deb package only, see 'debian/README.source'.
#
install:
	@PS4="●:make:$(@): "
	set -xeu

	install --directory $(INSTALL_OWNER) --mode=755 --verbose "$(DESTDIR)$(DIR_LIB)"
	install --directory $(INSTALL_OWNER) --mode=755 --verbose "$(DESTDIR)$(DIR_SHARE)"
	install --directory $(INSTALL_OWNER) --mode=755 --verbose "$(DESTDIR)/etc/$(PACKAGE_NAME)"
	# The token files - empty here. At a host 'debian/postinst' gives it to
	# the group of the server account; in a container it is the mount point.
	install --directory $(INSTALL_OWNER) --mode=755 --verbose "$(DESTDIR)/etc/$(PACKAGE_NAME)/tokens"
	install --directory $(INSTALL_OWNER) --mode=755 --verbose "$(DESTDIR)/usr/sbin"
	install --directory $(INSTALL_OWNER) --mode=755 --verbose "$(DESTDIR)$(DIR_MAN8)"

	install $(INSTALL_OWNER) --mode=644 --verbose "$(DIR_ORIGIN)/mcp-python.py"      "$(DESTDIR)$(DIR_LIB)/"
	install $(INSTALL_OWNER) --mode=644 --verbose "$(DIR_ORIGIN)/mcp_tools.py"       "$(DESTDIR)$(DIR_LIB)/"
	install $(INSTALL_OWNER) --mode=644 --verbose "$(DIR_ORIGIN)/mcp_auth.py"        "$(DESTDIR)$(DIR_LIB)/"
	install $(INSTALL_OWNER) --mode=755 --verbose "$(DIR_ORIGIN)/mcp-python-token"   "$(DESTDIR)/usr/sbin/"
	install $(INSTALL_OWNER) --mode=644 --verbose "$(DIR_ORIGIN)/requirements.txt"   "$(DESTDIR)$(DIR_SHARE)/"
	install $(INSTALL_OWNER) --mode=644 --verbose "$(DIR_BUILD)/requirements.lock"   "$(DESTDIR)$(DIR_SHARE)/"
	install $(INSTALL_OWNER) --mode=644 --verbose "$(DIR_ORIGIN)/mcp-python.conf"    "$(DESTDIR)/etc/$(PACKAGE_NAME)/"
	install $(INSTALL_OWNER) --mode=644 --verbose "$(DIR_ORIGIN)/mcp-python.8"       "$(DESTDIR)$(DIR_MAN8)/"
	install $(INSTALL_OWNER) --mode=644 --verbose "$(DIR_ORIGIN)/mcp-python-token.8" "$(DESTDIR)$(DIR_MAN8)/"

	true : Job done.

##
# Targets of the thematic directories - 'make chart-k3s-up' runs 'k3s-up'
# of 'chart/Makefile'. See its header for the targets and the usage.
#
chart-%:
	$(MAKE) --directory=chart $*

##
# The container image, its launches and its package - 'make container',
# 'make container-launch', 'make compose-launch' and so on run the targets of
# the same names of 'container/Makefile'. See its header for the targets and
# the usage. 'container' is phony - a directory of the same name is there.
#
container:
	$(MAKE) --directory=container $@

container-% compose-%:
	$(MAKE) --directory=container $@

#uninstall:
#	@PS4="●:make:$(@): "
#	set -xeu
#	test "..." != '/'
#	rm -rf "debian/$(PACKAGE_NAME)"
#	rm -rf "..."
#	true : Job done.

package-deb:
	@PS4="●:make:$(@): "
	set -xeu
	fakeroot dpkg-buildpackage -b -us -uc
	if [ ! -d "$(DIR_ARTIFACTS)" ] ; then mkdir "$(DIR_ARTIFACTS)" ; fi
	mv --force "../$(PACKAGE_NAME)_"*"_"*".changes" 	"$(DIR_ARTIFACTS)"
	mv --force "../$(PACKAGE_NAME)_"*"_"*".deb" 		"$(DIR_ARTIFACTS)"
	mv --force "../$(PACKAGE_NAME)_"*"_"*".buildinfo" 	"$(DIR_ARTIFACTS)"
	cd $(DIR_ARTIFACTS)
	# The packages of this build only - the ones of other versions and of
	# other packages ('package-deb-container') keep their hash files.
	for f in "$(PACKAGE_NAME)_$(PACKAGE_VERSION)_"*".deb" ; do
	    sha256sum -b "$${f}" > "$${f}.sha256"
	done

	true : Job done.

##
# The container image as the Deb package '$(PACKAGE_NAME_CONTAINER)', with
# the hash file - see 'container/Makefile' and 'debian-container'.
#
# No recipe of its own - the '$$(MAKE)' of the 'container-%' rule. A
# '$$(MAKE)' in a recipe with more lines - 'make -n' runs all of them
# ('.ONESHELL').
package-deb-container: container-package-deb

##
# The Helm chart as the Deb package '$(PACKAGE_NAME_CHART)', with the hash
# file - see 'chart/Makefile' and 'debian-chart'. As 'package-deb-container'.
#
package-deb-chart: chart-package-deb

##
# The Helm chart, with the hash file - see 'chart/Makefile'.
#
package-helm: chart-package
	@PS4="●:make:$(@): "
	set -xeu -o pipefail

	cd $(DIR_ARTIFACTS)
	sha256sum -b "$(CHART_NAME)-$(PACKAGE_VERSION).tgz" > "$(CHART_NAME)-$(PACKAGE_VERSION).tgz.sha256"

	true : Job done.

##
# The sources as an archive - 'artifacts/<name>_<version>_sources.tar.gz', all in the
# directory '<name>-<version>'. The files are the ones Git tracks, with the
# content of the working tree - as the Deb package is built from; a change,
# which is not committed, is in, a file unknown to Git is not.
#
package-src:
	@PS4="●:make:$(@): "
	set -xeu -o pipefail
	if [ ! -d $(DIR_ARTIFACTS) ] ; then mkdir $(DIR_ARTIFACTS) ; fi
	archive="$(PACKAGE_NAME)_$(PACKAGE_VERSION)_sources.tar.gz"
	git ls-files -z \
	    | tar --create --gzip \
	        --null --files-from=- \
	        --owner=root --group=root \
	        --transform='s#^#$(PACKAGE_NAME)-$(PACKAGE_VERSION)/#' \
	        --file="$(DIR_ARTIFACTS)/$${archive}"
	cd $(DIR_ARTIFACTS)
	sha256sum -b "$${archive}" > "$${archive}.sha256"

	true : Job done.

##
# The source Deb package - 'artifacts/<name>_<version>.dsc' and the archive
# it names, '<name>_<version>.tar.gz' (a native package - no upstream
# archive). The whole directory is packed, besides what is named here: Git
# is not asked, so a new directory, which is not a source, is to be added.
# 'debian/rules clean' runs first. Unpack: 'dpkg-source -x <name>_<version>.dsc'.
#
package-deb-src:
	@PS4="●:make:$(@): "
	set -xeu
	# '-I' alone - the default list ('.git' and the like).
	dpkg-buildpackage -S -us -uc \
	    -I \
	    -I"$(DIR_ARTIFACTS)" \
	    -I"$(DIR_BUILD)" \
	    -Imisc \
	    -Itrash \
	    -I.vscode \
	    -I"*.code-workspace" \
	    -I"$(FILE_STORE_PATHS_LIST)"
	if [ ! -d $(DIR_ARTIFACTS) ] ; then mkdir $(DIR_ARTIFACTS) ; fi
	mv --force "../$(PACKAGE_NAME)_$(PACKAGE_VERSION).dsc"                 $(DIR_ARTIFACTS)
	mv --force "../$(PACKAGE_NAME)_$(PACKAGE_VERSION).tar.gz"              $(DIR_ARTIFACTS)
	mv --force "../$(PACKAGE_NAME)_$(PACKAGE_VERSION)_source.changes"      $(DIR_ARTIFACTS)
	mv --force "../$(PACKAGE_NAME)_$(PACKAGE_VERSION)_source.buildinfo"    $(DIR_ARTIFACTS)
	cd $(DIR_ARTIFACTS)
	# The archive - its hash is in the '.dsc'.
	sha256sum -b "$(PACKAGE_NAME)_$(PACKAGE_VERSION).dsc" > "$(PACKAGE_NAME)_$(PACKAGE_VERSION).dsc.sha256"

	true : Job done.

##
# The question first - 'release-ask', the first prerequisite ('.NOTPARALLEL'),
# then the builds, then the tag and the copies to the directories of
# '$(FILE_STORE_PATHS_LIST)'.
#
release: release-ask package-src package-deb-src package-deb package-deb-container package-helm package-deb-chart
	@PS4="●:make:$(@): "
	set -xeu
	if [ ! -e "$(FILE_STORE_PATHS_LIST)" ] ; then
	    touch "$(FILE_STORE_PATHS_LIST)"
	fi

	git \
	    tag \
	    --annotate \
	    --message="Release '$(PACKAGE_NAME)' of version '$(PACKAGE_VERSION)'." \
	    "$(VCS_TAG)"

	while IFS= read -r dir_storage || [[ -n "$${dir_storage}" ]] ; do
	    if [[ -z "$${dir_storage}" || "$${dir_storage}" == \#* ]] ; then
	        continue
	    fi
	    mkdir -pv "$${dir_storage}"
	    dir_storage="$$( cd "$${dir_storage}" && pwd )"
	    cp --verbose \
	        "$(DIR_ARTIFACTS)/$(PACKAGE_NAME)_$(PACKAGE_VERSION)_"*".deb" \
	        "$(DIR_ARTIFACTS)/$(PACKAGE_NAME)_$(PACKAGE_VERSION)_"*".deb.sha256" \
	        "$(DIR_ARTIFACTS)/$(PACKAGE_NAME_CONTAINER)_$(PACKAGE_VERSION)_"*".deb" \
	        "$(DIR_ARTIFACTS)/$(PACKAGE_NAME_CONTAINER)_$(PACKAGE_VERSION)_"*".deb.sha256" \
	        "$(DIR_ARTIFACTS)/$(PACKAGE_NAME_CHART)_$(PACKAGE_VERSION)_"*".deb" \
	        "$(DIR_ARTIFACTS)/$(PACKAGE_NAME_CHART)_$(PACKAGE_VERSION)_"*".deb.sha256" \
	        "$(DIR_ARTIFACTS)/$(CHART_NAME)-$(PACKAGE_VERSION).tgz" \
	        "$(DIR_ARTIFACTS)/$(CHART_NAME)-$(PACKAGE_VERSION).tgz.sha256" \
	        "$${dir_storage}/"
	done < "$(FILE_STORE_PATHS_LIST)"

	true : Job done.

##
# A human at a terminal says yes - or no 'release'. The tag is checked here
# too, not after the builds: one more of the same version would fail at
# 'git tag', with the artifacts built again.
#
release-ask:
	@PS4="●:make:$(@): "
	set -xeu
	if git rev-parse --quiet --verify "refs/tags/$(VCS_TAG)" >/dev/null ; then
	    echo "○:make:$(@): The tag '$(VCS_TAG)' exists - a new version in 'debian/changelog' first." >&2
	    exit 1
	fi
	[ -t 0 ] || { echo "○:make:$(@): Not a terminal - no one to ask." >&2 ; exit 1 ; }
	whiptail \
	    --title "question" \
	    --defaultno \
	    --yesno "Release\n$(VCS_TAG)\n?" \
	    0 0

	true : Job done.

unrelease:
	@PS4="●:make:$(@): "
	set -xeu

	PACKAGE_VERSION_DEVEL="0.0.0"
	VCS_TAG_DEVEL="$(PACKAGE_NAME)_$${PACKAGE_VERSION_DEVEL}"

	git tag --delete "$${VCS_TAG_DEVEL}"

	true : Job done.
