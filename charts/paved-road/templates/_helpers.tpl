{{/*
Everything the templates share. Two things here are load-bearing:

  paved-road.resources   the tier table. One map, one place to retune every
                         service on the cluster.
  paved-road.labels      the ownership labels the guardrails require. Rendered
                         onto every object, so a team cannot get a compliant
                         Deployment and a non-compliant Pod.
*/}}

{{- define "paved-road.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "paved-road.fullname" -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
The hostname this service answers on. The suffix is the platform's, not the
team's: a team choosing its own apex is a team that can collide with another
team, and the wildcard certificate only covers one suffix anyway.
*/}}
{{- define "paved-road.host" -}}
{{- $sub := .Values.ingress.subdomain | default (include "paved-road.fullname" .) -}}
{{- printf "%s.apps.platform.test" $sub -}}
{{- end -}}

{{/*
Selector labels: the minimum set, and never anything that changes on upgrade.
A Deployment's selector is immutable, so putting a version or a tier in here
would make every re-tier a delete-and-recreate.
*/}}
{{- define "paved-road.selectorLabels" -}}
app.kubernetes.io/name: {{ include "paved-road.fullname" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{- define "paved-road.labels" -}}
{{ include "paved-road.selectorLabels" . }}
app.kubernetes.io/version: {{ .Values.image.tag | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: paved-road
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version }}
platform.internal/team: {{ .Values.owner.team | quote }}
platform.internal/owner: {{ .Values.owner.contact | replace "@" "_at_" | replace "." "_" | trunc 63 | trimSuffix "-" | quote }}
platform.internal/tier: {{ .Values.resources.tier | quote }}
{{- end -}}

{{/*
The tier table.

Requests are what the scheduler places on. CPU limits are set well above
requests because CPU is compressible -- throttling a burst is better than
refusing to schedule for it. Memory limit equals a small multiple of the request
because memory is not compressible: exceeding it is an OOMKill, and a limit far
above the request just means the node is oversubscribed on the one resource that
cannot be reclaimed.

`custom` skips the table. It is validated in values.schema.json to require all
four numbers, because a partial override is how a service ends up with a memory
limit and no memory request.
*/}}
{{- define "paved-road.resources" -}}
{{- if .Values.resources.custom -}}
{{- toYaml .Values.resources.custom -}}
{{- else -}}
{{- $tiers := dict
  "nano"   (dict "requests" (dict "cpu" "10m"  "memory" "32Mi")  "limits" (dict "cpu" "200m"  "memory" "64Mi"))
  "small"  (dict "requests" (dict "cpu" "50m"  "memory" "128Mi") "limits" (dict "cpu" "500m"  "memory" "256Mi"))
  "medium" (dict "requests" (dict "cpu" "250m" "memory" "512Mi") "limits" (dict "cpu" "1000m" "memory" "1Gi"))
  "large"  (dict "requests" (dict "cpu" "500m" "memory" "1Gi")   "limits" (dict "cpu" "2000m" "memory" "2Gi"))
-}}
{{- $t := get $tiers .Values.resources.tier -}}
{{- if not $t -}}
{{- fail (printf "resources.tier must be one of nano, small, medium, large (got %q). Use resources.custom for a service that does not fit a tier." .Values.resources.tier) -}}
{{- end -}}
{{- toYaml $t -}}
{{- end -}}
{{- end -}}

{{/*
The observability wiring. This is the whole of what "the platform gives you
observability" means in practice: five environment variables the team never
writes, pointing at a collector whose address they never learn.
*/}}
{{- define "paved-road.observabilityEnv" -}}
{{- if .Values.observability.enabled }}
- name: OTEL_EXPORTER_OTLP_ENDPOINT
  value: {{ .Values.observability.otlpEndpoint | quote }}
- name: OTEL_SERVICE_NAME
  value: {{ .Values.observability.serviceName | default (include "paved-road.fullname" .) | quote }}
- name: SERVICE_NAMESPACE
  value: {{ .Release.Namespace | quote }}
- name: SERVICE_VERSION
  value: {{ .Values.image.tag | quote }}
- name: DEPLOYMENT_ENVIRONMENT
  value: {{ .Values.observability.environment | quote }}
- name: OTEL_RESOURCE_ATTRIBUTES
  value: {{ printf "service.namespace=%s,deployment.environment=%s,platform.team=%s" .Release.Namespace .Values.observability.environment .Values.owner.team | quote }}
{{- end }}
{{- end -}}
