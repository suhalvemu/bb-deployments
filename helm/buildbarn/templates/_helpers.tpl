{{/*
Chart name, truncated/sanitized for use in Kubernetes object names.
*/}}
{{- define "buildbarn.name" -}}
{{- .Chart.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Common labels applied to every object this chart creates.
*/}}
{{- define "buildbarn.labels" -}}
helm.sh/chart: {{ printf "%s-%s" (include "buildbarn.name" .) .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: {{ include "buildbarn.name" . }}
{{- end -}}

{{/*
Selector labels for a given component. Selector labels must be immutable
across upgrades, so this stays separate from buildbarn.labels (which
includes the chart version). Call as:
  {{ include "buildbarn.selectorLabels" (dict "root" $ "component" "storage") }}
*/}}
{{- define "buildbarn.selectorLabels" -}}
app.kubernetes.io/name: {{ include "buildbarn.name" .root }}
app.kubernetes.io/component: {{ .component }}
{{- end -}}

{{/*
The namespace every object should land in.
*/}}
{{- define "buildbarn.namespace" -}}
{{- .Values.namespace.name -}}
{{- end -}}

{{/*
Jsonnet snippet: a `shards` object with one entry per storage replica,
pointing at each storage pod's stable StatefulSet DNS name. Used by
common.libsonnet wherever it needs to address the sharded storage backend.
Call as: {{ include "buildbarn.storageShards" $ }}
*/}}
{{- define "buildbarn.storageShards" -}}
{
{{- range $i := until (int .Values.storage.replicas) }}
  "{{ $i }}": {
    backend: { grpc: { client: { address: 'storage-{{ $i }}.storage.{{ include "buildbarn.namespace" $ }}:8981' } } },
    weight: 1,
  },
{{- end }}
}
{{- end -}}

{{/*
Name of the Secret holding the postgres password -- either the
user-supplied existingSecret, or the one this chart creates itself.
*/}}
{{- define "buildbarn.postgresSecretName" -}}
{{- if .Values.postgres.existingSecret -}}
{{- .Values.postgres.existingSecret -}}
{{- else -}}
postgres-credentials
{{- end -}}
{{- end -}}

{{/*
Name of the ConfigMap holding the synced JWKS.
*/}}
{{- define "buildbarn.jwksConfigMapName" -}}
buildbarn-jwks
{{- end -}}

{{/*
Jsonnet snippet for a gRPC server's `authenticationPolicy` field.
Renders the real JWT policy when oidc.enabled, otherwise `allow: {}`
(matching every component's pre-OIDC default). Deliberately kept as a
single line -- this is substituted inline inside a YAML block scalar
(the embedded Jsonnet config), so multi-line output without explicit
nindent/indent handling at every call site would silently de-indent
and break the surrounding YAML. Call as:
  authenticationPolicy: {{ include "buildbarn.authenticationPolicy" $ }},
*/}}
{{- define "buildbarn.authenticationPolicy" -}}
{{- if .Values.oidc.enabled -}}
{ jwt: { jwksFile: '/jwks/jwks.json', maximumCacheSize: 1000, cacheReplacementPolicy: 'LEAST_RECENTLY_USED', claimsValidationJmespathExpression: { expression: "payload.aud == '{{ .Values.oidc.audience }}'" }, metadataExtractionJmespathExpression: { expression: '{"public": {"subject": payload.sub}}' } } }
{{- else -}}
{ allow: {} }
{{- end -}}
{{- end -}}

{{/*
Volume + mount for the synced JWKS ConfigMap. Only meaningful when
oidc.enabled -- callers should guard inclusion with that same check.
*/}}
{{- define "buildbarn.jwksVolume" -}}
- name: jwks
  configMap:
    name: {{ include "buildbarn.jwksConfigMapName" . }}
{{- end -}}

{{- define "buildbarn.jwksVolumeMount" -}}
- mountPath: /jwks/
  name: jwks
  readOnly: true
{{- end -}}
