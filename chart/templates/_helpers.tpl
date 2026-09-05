{{/*
Shared helpers. Everything that was a hardcoded string in the Kustomize
manifests is derived here, so a rename or a rebuild only touches values.yaml.
*/}}

{{- define "l2lab.namePrefix" -}}
{{ .Values.global.namePrefix }}
{{- end -}}

{{/* Fully-qualified hostnames */}}
{{- define "l2lab.appHost" -}}
app.{{ .Values.global.domain }}
{{- end -}}

{{- define "l2lab.grafanaHost" -}}
grafana.{{ .Values.global.domain }}
{{- end -}}

{{/*
IRSA role ARN for a given suffix.

The role names are deterministic - terraform builds them as
"<var.name>-<suffix>" - so they can be derived rather than pasted. Previously
these were six hardcoded ARNs across three files; rename the project and every
pod silently gets AccessDenied at runtime.
*/}}
{{- define "l2lab.roleArn" -}}
{{- $ctx := index . 0 -}}
{{- $suffix := index . 1 -}}
arn:aws:iam::{{ $ctx.Values.global.accountId }}:role/{{ $ctx.Values.global.namePrefix }}-{{ $suffix }}
{{- end -}}

{{/* Secrets Manager secret id */}}
{{- define "l2lab.secretId" -}}
{{- $ctx := index . 0 -}}
{{- $name := index . 1 -}}
{{ $ctx.Values.global.namePrefix }}/{{ $name }}
{{- end -}}

{{/* In-cluster service DNS. Fully qualified so each lookup is ONE query
     instead of walking the search domains - at high request rates that
     difference is enough to overload CoreDNS. */}}
{{- define "l2lab.svcFqdn" -}}
{{- $ctx := index . 0 -}}
{{- $svc := index . 1 -}}
{{- $ns := index . 2 -}}
{{ $svc }}.{{ $ns }}.svc.cluster.local
{{- end -}}

{{- define "l2lab.appNs" -}}
{{ .Values.global.namespaces.app }}
{{- end -}}

{{- define "l2lab.obsNs" -}}
{{ .Values.global.namespaces.observability }}
{{- end -}}

{{/* Standard labels */}}
{{- define "l2lab.labels" -}}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: l2lab
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
{{- end -}}

{{/*
Resolve an image tag.

Falls back to .Chart.AppVersion when the value is empty, but a mutable tag is
never a good default - `helm upgrade` with an unchanged tag produces no pod
restart, so you can "deploy" and change nothing.
*/}}
{{- define "l2lab.image" -}}
{{- $ctx := index . 0 -}}
{{- $img := index . 1 -}}
{{ $img.repository }}:{{ $img.tag | default $ctx.Chart.AppVersion }}
{{- end -}}

{{/*
Pod security context for the `restricted` Pod Security Standard.
Callers pass the uid/gid, because the images disagree: postgres is 70, redis
999, grafana 472, loki/tempo 10001, nginx 101, our scratch images 65534.
*/}}
{{- define "l2lab.podSecurityContext" -}}
{{- $uid := index . 0 -}}
{{- $gid := index . 1 -}}
{{- $fsGroup := index . 2 -}}
runAsUser: {{ $uid }}
runAsGroup: {{ $gid }}
runAsNonRoot: true
{{- if $fsGroup }}
fsGroup: {{ $fsGroup }}
{{- end }}
seccompProfile:
  type: RuntimeDefault
{{- end -}}

{{- define "l2lab.containerSecurityContext" -}}
allowPrivilegeEscalation: false
capabilities:
  drop: ["ALL"]
{{- end -}}
