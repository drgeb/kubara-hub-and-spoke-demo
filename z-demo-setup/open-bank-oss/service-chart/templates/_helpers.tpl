{{- define "svc.name" -}}
{{- required "name is required" .Values.name -}}-service
{{- end -}}

{{- define "svc.labels" -}}
app.kubernetes.io/name: {{ include "svc.name" . }}
app.kubernetes.io/part-of: openbank
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}

{{- define "svc.selector" -}}
app.kubernetes.io/name: {{ include "svc.name" . }}
{{- end -}}
