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
# Variables of the project - the one place of them for the 'Makefile' at
# the root and the ones of the sub-directories (i.e. './*/Makefile',
# each includes this file. The paths are relative to the root of the
# project, where this file is: a 'Makefile' of a sub-directory puts
# '$(DIR_ROOT)/' before them.
#
# Exported - a recipe and a 'Makefile' it runs ('debian/rules') see them
# in the environment. A 'Makefile', which includes this file, sets them
# again from here, whatever the environment has - so a variable has the
# same meaning in every directory. Given at the command line ('make
# PACKAGE_VERSION=0.0.0 ...') - it wins everywhere, sub-makes included.
#

# The root of the project, as seen from the 'Makefile' which includes this
# file - '.' at the root, '..' in 'chart' and 'container'. Not exported: it differs per
# directory.
DIR_ROOT := $(patsubst %/,%,$(dir $(lastword $(MAKEFILE_LIST))))

# A universal name for a packages with classic types of hosting 
# and a prefix of a packages names targeted for a kinds of fencing
# (containerisation). 
export PACKAGE_NAME := mcp-python

# The Deb package of the container image and related stuff.
export PACKAGE_NAME_CONTAINER := $(PACKAGE_NAME)-container

# The Deb package of the Helm chart and its launcher.
export PACKAGE_NAME_CHART := $(PACKAGE_NAME)-chart

export PACKAGE_VERSION := $(shell dpkg-parsechangelog --file "$(DIR_ROOT)/debian/changelog" -S Version)
export DIR_ARTIFACTS := artifacts
export DIR_BUILD := build
# The secrets of the development tree - for the launchers
# ('container/mcp-python-container', '...-compose', 'chart/mcp-python-chart'),
# which the targets run: the TLS certificate, the token files, the token of
# the client 'dev', the K3s kubeconfig - see mcp-python-container(1), FILES.
# Not the ones of the user ('~/.local/share/mcp-python'). The image - the one
# of this version ('make container').
export DIR_BUILD_DATA := $(DIR_BUILD)/mcp-python
export MCP_DATA_DIR := $(abspath $(DIR_ROOT)/$(DIR_BUILD_DATA))
export MCP_CLIENT := dev
export MCP_IMAGE_TAG := $(PACKAGE_VERSION)
# The Helm chart - the directory 'chart/$(CHART_NAME)', the package
# '$(DIR_ARTIFACTS)/$(CHART_NAME)-$(PACKAGE_VERSION).tgz'.
export CHART_NAME := mcp-python-server
