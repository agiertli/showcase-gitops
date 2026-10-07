{{- define "evalhub-infra.fullname" -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "evalhub-infra.namespace" -}}
{{- .Values.namespace | default .Release.Namespace }}
{{- end }}

{{- define "evalhub-infra.s4Host" -}}
s4-service.{{ include "evalhub-infra.namespace" . }}.svc.cluster.local
{{- end }}

{{- define "evalhub-infra.postgresHost" -}}
evalhub-postgres.{{ include "evalhub-infra.namespace" . }}.svc.cluster.local
{{- end }}

{{- define "evalhub-infra.dbUrl" -}}
postgres://{{ .Values.postgres.user }}:{{ .Values.postgres.password }}@{{ include "evalhub-infra.postgresHost" . }}:5432/{{ .Values.postgres.database }}
{{- end }}
