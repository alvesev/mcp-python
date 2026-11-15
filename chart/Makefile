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
# Helm chart of "mcp-python" - the chart, its packages, and a test launch in
# a K3s cluster - a Docker container at this host. Run here ('make -C chart
# ...') or from the project root ('make chart-...').
#
# The launch - by the launcher of this directory, 'mcp-python-chart' (see
# mcp-python-chart(1)): the cluster, the image loaded into it, the Secrets
# and the release - with the secrets of the development tree, see
# 'DIR_BUILD_DATA' in 'variables.mk'. The image of the server is not pulled -
# it is copied from the local Docker ('make container' at the root). The
# check of the Ingress - printed at the launch.
#
# The K3s container is privileged - it has full access to this host while it
# runs.
#
##
#
# Typical usage, at the project root:
#
#     make container                  # The image of the server, once per change of it.
#     make chart-mcp-launch           # The cluster, the image, the release - HTTPS at https://localhost:8443/mcp.
#     make chart-mcp-test             # 'helm test' - the listener accepts connections.
#     make chart-mcp-forward          # The listeners at 127.0.0.1, until Ctrl C.
#     make chart-mcp-stop             # The release removed, the cluster stays.
#     make chart-k3s-down             # All gone.
#
# 'k3s-up', 'k3s-image-load', 'mcp-tokens' - the same as 'mcp-launch', the
# names of before: the launcher does all the steps at once, each again only
# if needed. One more client - its token at
# 'build/mcp-python/clients/NAME.token' - no restart of the pods:
#
#     make chart-mcp-launch MCP_CLIENT=NAME
#
# HTTPS listener of the server too:
#
#     make chart-mcp-launch MCP_TLS=yes
#     make chart-mcp-forward MCP_TLS=yes
#
# Other values of the chart:
#
#     make chart-mcp-launch HELM_ARGS="--set networkPolicy.enabled=true"
#
# After a change of the server - 'make container', then 'make chart-mcp-launch'
# again. The image has the same tag, so the pods are not replaced by Helm:
#
#     chart/mcp-python-chart kubectl --namespace mcp-python rollout restart deployment
#
# 'kubectl' and 'helm' by hand - 'chart/mcp-python-chart kubectl ...', or
# 'export KUBECONFIG=build/mcp-python/k3s/kubeconfig.yaml' first.
#
# The chart as a package - '<chart name>-<PACKAGE_VERSION>.tgz' in 'artifacts'
# of in the top level directory; parent 'Makefile' may call the corresponding
# target from this 'Makefile' for packaging:
#
#     make chart-package
#
# The same, as the Deb package '$(PACKAGE_NAME_CHART)' ('debian-chart'), with
# the launcher.
#
# Without the 'chart-%' rule at the root - 'make -C chart mcp-launch' and so on.
#
##

SHELL := /usr/bin/bash
.ONESHELL:

# The variables of the project - the same as at the root, with the paths
# relative to the root: here they are used as '$(DIR_ROOT)/...'.
include ../variables.mk

# The chart - relative to this directory.
DIR_CHART := $(CHART_NAME)

# The Deb package of the chart - its 'debian' directory and the stage it is
# built in ('package-deb').
DIR_DEBIAN := $(DIR_ROOT)/debian-chart
DIR_BUILD_DEB := $(DIR_ROOT)/$(DIR_BUILD)/deb-chart
CHART_TGZ := $(CHART_NAME)-$(PACKAGE_VERSION).tgz

# The chart, packed once - for 'artifacts' ('package') and for the Deb
# package ('package-deb'). Packed again after a change of the chart only.
DIR_BUILD_CHART := $(DIR_ROOT)/$(DIR_BUILD)/chart
CHART_TGZ_BUILT := $(DIR_BUILD_CHART)/$(CHART_TGZ)

# The launcher - and the values of the release it gives.
LAUNCHER := ./mcp-python-chart
VALUES := mcp-python-chart-values.yaml
# HTTPS listener of the server - 'yes' (both listeners) or 'no'.
MCP_TLS ?= no
# More 'helm upgrade' options, e.g. HELM_ARGS="--set networkPolicy.enabled=true".
HELM_ARGS ?=

.PHONY: lint package deb-version-check package-deb k3s-up k3s-down k3s-image-load mcp-launch mcp-tokens mcp-test mcp-forward mcp-stop

lint:
	@PS4="●:make:$(@): "
	set -xeu
	helm lint "$(DIR_CHART)"
	helm lint "$(DIR_CHART)" --set auth.secretName=lint
	helm lint "$(DIR_CHART)" --set auth.enabled=false
	helm lint "$(DIR_CHART)" --set auth.secretName=lint,tls.enabled=true,tls.secretName=lint,networkPolicy.enabled=true,ingress.enabled=true
	helm lint "$(DIR_CHART)" --values "$(VALUES)"

	true : Job done.

##
# The chart package - '<chart name>-<PACKAGE_VERSION>.tgz', the name of
# 'Chart.yaml'. Both versions of the chart - 'version' and 'appVersion' - are
# 'PACKAGE_VERSION', as the Deb package and the image of the same build
# have; the ones of 'Chart.yaml' are for the chart taken from the source
# tree. Packed into '$(DIR_BUILD)/chart' - after a change of the chart only;
# 'artifacts' and the Deb package get that file.
#
package: $(CHART_TGZ_BUILT)
	@PS4="●:make:$(@): "
	set -xeu
	if [ ! -d "$(DIR_ROOT)/$(DIR_ARTIFACTS)" ] ; then mkdir "$(DIR_ROOT)/$(DIR_ARTIFACTS)" ; fi
	cp "$(CHART_TGZ_BUILT)" "$(DIR_ROOT)/$(DIR_ARTIFACTS)/"

	true : Job done.

$(CHART_TGZ_BUILT): $(shell find $(DIR_CHART) -type f) | lint
	@PS4="●:make:$(@): "
	set -xeu
	mkdir -p "$(DIR_BUILD_CHART)"
	helm package "$(DIR_CHART)" \
	    --version "$(PACKAGE_VERSION)" \
	    --app-version "$(PACKAGE_VERSION)" \
	    --destination "$(DIR_BUILD_CHART)"

	true : Job done.

##
# The versions of both changelogs - the one of 'debian-chart' is kept by
# hand, the chart is of the one of 'debian'.
#
deb-version-check:
	@PS4="●:make:$(@): "
	set -xeu
	version="$$( dpkg-parsechangelog --file "$(DIR_DEBIAN)/changelog" -S Version )"
	if [ "$${version}" != "$(PACKAGE_VERSION)" ] ; then
	    { set +x ; } 2>/dev/null
	    echo "○:make:$(@): The version of 'debian-chart/changelog' is '$${version}', of 'debian/changelog' - '$(PACKAGE_VERSION)'. Add an entry:" >&2
	    echo "    dch --changelog debian-chart/changelog --newversion '$(PACKAGE_VERSION)'" >&2
	    exit 1
	fi

	true : Job done.

##
# The Deb package '$(PACKAGE_NAME_CHART)' - '<package>_<version>_all.deb' in
# 'artifacts' of the root, with the hash file. Built in a stage of its own,
# where 'debian-chart' is 'debian' - see 'debian-chart/README.source'.
#
package-deb: deb-version-check $(CHART_TGZ_BUILT)
	@PS4="●:make:$(@): "
	set -xeu
	stage="$(DIR_BUILD_DEB)/$(PACKAGE_NAME_CHART)-$(PACKAGE_VERSION)"
	test "$(DIR_BUILD_DEB)" != '/' || exit 1
	rm -rf "$(DIR_BUILD_DEB)"
	mkdir -p "$${stage}/chart"
	# '-L' - the symbolic links to the files of 'debian' become the files.
	cp -rL "$(DIR_DEBIAN)" "$${stage}/debian"
	cp -r . "$${stage}/chart/"
	cp "$(CHART_TGZ_BUILT)" "$${stage}/"
	# The name of the chart - for the launcher.
	sed -i "s#@CHART_NAME@#$(CHART_NAME)#g" "$${stage}/chart/mcp-python-chart"

	( cd "$${stage}" && fakeroot dpkg-buildpackage -b -us -uc )

	mv --force "$(DIR_BUILD_DEB)/$(PACKAGE_NAME_CHART)_$(PACKAGE_VERSION)_"*".deb"       "$(DIR_ROOT)/$(DIR_ARTIFACTS)/"
	mv --force "$(DIR_BUILD_DEB)/$(PACKAGE_NAME_CHART)_$(PACKAGE_VERSION)_"*".changes"   "$(DIR_ROOT)/$(DIR_ARTIFACTS)/"
	mv --force "$(DIR_BUILD_DEB)/$(PACKAGE_NAME_CHART)_$(PACKAGE_VERSION)_"*".buildinfo" "$(DIR_ROOT)/$(DIR_ARTIFACTS)/"
	rm -rf "$(DIR_BUILD_DEB)"
	cd "$(DIR_ROOT)/$(DIR_ARTIFACTS)"
	for f in "$(PACKAGE_NAME_CHART)_$(PACKAGE_VERSION)_"*".deb" ; do
	    sha256sum -b "$${f}" > "$${f}.sha256"
	done

	true : Job done.

##
# The cluster, the image in it, the Secrets of the secrets of the development
# tree, the release with 'VALUES' - 'mcp-python-chart up'. Waits for the
# pods. Again - each step only if needed; a changed client is applied.
#
mcp-launch k3s-up k3s-image-load mcp-tokens:
	@PS4="●:make:$(@): "
	set -xeu
	tls_args=()
	if [ "$(MCP_TLS)" = "yes" ] ; then
	    tls_args=(--set tls.enabled=true --set tls.secretName=mcp-python-tls)
	fi
	$(LAUNCHER) --chart "$(DIR_CHART)" up "$${tls_args[@]}" $(HELM_ARGS)

	true : Job done.

mcp-test:
	@PS4="●:make:$(@): "
	set -xeu
	$(LAUNCHER) test

	true : Job done.

##
# The listeners of the service at the local host - until Ctrl C.
#
mcp-forward:
	@PS4="●:make:$(@): "
	set -xeu
	ports=(8765:8765)
	if [ "$(MCP_TLS)" = "yes" ] ; then ports+=(8766:8766) ; fi
	exec $(LAUNCHER) kubectl --namespace mcp-python port-forward \
	    "service/mcp-python-$(CHART_NAME)" "$${ports[@]}"

	true : Job done.

# The release removed - the cluster stays.
mcp-stop:
	@PS4="●:make:$(@): "
	set -xeu
	$(LAUNCHER) helm uninstall mcp-python --namespace mcp-python --wait

	true : Job done.

# The cluster removed, with all its state.
k3s-down:
	@PS4="●:make:$(@): "
	set -xeu
	$(LAUNCHER) down

	true : Job done.
