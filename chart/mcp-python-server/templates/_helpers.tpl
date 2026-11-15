{{- /*
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
*/ -}}
{{/*
Expand the name of the chart.
*/}}
{{- define "mcp-python-server.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
We truncate at 63 chars because some Kubernetes name fields are limited to this (by the DNS naming spec).
If release name contains chart name it will be used as a full name.
*/}}
{{- define "mcp-python-server.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "mcp-python-server.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "mcp-python-server.labels" -}}
helm.sh/chart: {{ include "mcp-python-server.chart" . }}
{{ include "mcp-python-server.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "mcp-python-server.selectorLabels" -}}
app.kubernetes.io/name: {{ include "mcp-python-server.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Create the name of the service account to use
*/}}
{{- define "mcp-python-server.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "mcp-python-server.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
Listeners - 'MCP_HTTP_VARIANT': HTTP, HTTPS or both.
*/}}
{{- define "mcp-python-server.httpVariant" -}}
{{- if .Values.tls.enabled }}
{{- if .Values.tls.only }}HTTPS{{ else }}both{{ end }}
{{- else }}HTTP{{ end }}
{{- end }}

{{/*
Name of the port of the first listener - for the probes, the Ingress and the test.
*/}}
{{- define "mcp-python-server.listenerPort" -}}
{{- if eq (include "mcp-python-server.httpVariant" .) "HTTPS" }}https{{ else }}http{{ end }}
{{- end }}

{{/*
A probe - the port of the first listener for a 'tcpSocket' without one.
*/}}
{{- define "mcp-python-server.probe" -}}
{{- $probe := deepCopy .probe }}
{{- if and (hasKey $probe "tcpSocket") (not (dig "tcpSocket" "port" "" $probe)) }}
{{- $_ := set $probe "tcpSocket" (dict "port" (include "mcp-python-server.listenerPort" .root)) }}
{{- end }}
{{- toYaml $probe }}
{{- end }}

{{/*
Container security context. With TLS - root, SETUID and SETGID: the server
reads the key, then drops to 'MCP_USER' itself.
*/}}
{{- define "mcp-python-server.securityContext" -}}
{{- $ctx := deepCopy (.Values.securityContext | default dict) }}
{{- if .Values.tls.enabled }}
{{- $_ := set $ctx "runAsUser" 0 }}
{{- $_ := set $ctx "runAsGroup" 0 }}
{{- $_ := set $ctx "runAsNonRoot" false }}
{{- $caps := deepCopy ($ctx.capabilities | default dict) }}
{{- $_ := set $caps "add" (concat ($caps.add | default list) (list "SETUID" "SETGID") | uniq) }}
{{- $_ := set $ctx "capabilities" $caps }}
{{- end }}
{{- toYaml $ctx }}
{{- end }}
