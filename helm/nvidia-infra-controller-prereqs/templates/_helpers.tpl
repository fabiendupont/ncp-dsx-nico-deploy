{{/*
SPDX-FileCopyrightText: Copyright (c) 2026 Red Hat, Inc. All rights reserved.
SPDX-License-Identifier: Apache-2.0
*/}}

{{- define "nvidia-infra-controller-prereqs.labels" -}}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: nvidia-infra-controller
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
{{- end }}
