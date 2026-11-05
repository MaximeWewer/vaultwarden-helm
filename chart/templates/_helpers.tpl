{{- define "vaultwarden.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "vaultwarden.fullname" -}}
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

{{- define "vaultwarden.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "vaultwarden.labels" -}}
helm.sh/chart: {{ include "vaultwarden.chart" . }}
{{ include "vaultwarden.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: vaultwarden
{{- with .Values.commonLabels }}
{{ toYaml . }}
{{- end }}
{{- end }}

{{/* metadata.annotations: commonAnnotations merged with the resource's own
     annotations (dict {root, extra}; extra wins). Renders nothing when empty. */}}
{{- define "vaultwarden.annotations" -}}
{{- $a := merge (deepCopy (.extra | default dict)) (.root.Values.commonAnnotations | default dict) -}}
{{- with $a }}
annotations:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- end }}

{{/* Render a value that may contain templates (extraObjects, sidecars...). */}}
{{- define "vaultwarden.tplValue" -}}
{{- if typeIs "string" .value -}}
{{- tpl .value .root -}}
{{- else -}}
{{- tpl (toYaml .value) .root -}}
{{- end -}}
{{- end }}

{{- define "vaultwarden.selectorLabels" -}}
app.kubernetes.io/name: {{ include "vaultwarden.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{- define "vaultwarden.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "vaultwarden.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/* Chart-managed Secret holding the vaultwarden secrets. */}}
{{- define "vaultwarden.secretName" -}}
{{- if .Values.config.existingSecret -}}
{{- .Values.config.existingSecret -}}
{{- else -}}
{{- printf "%s-secret" (include "vaultwarden.fullname" .) -}}
{{- end -}}
{{- end }}

{{/* Component names. */}}
{{- define "vaultwarden.cnpg.fullname" -}}{{ printf "%s-db" (include "vaultwarden.fullname" .) }}{{- end }}
{{- define "vaultwarden.cnpg.objectStore" -}}{{ printf "%s-db-backup" (include "vaultwarden.fullname" .) }}{{- end }}
{{- define "vaultwarden.pvcName" -}}
{{- .Values.storage.persistence.existingClaim | default (printf "%s-data" (include "vaultwarden.fullname" .)) -}}
{{- end }}

{{/* Effective replica count: forced to 1 when storage or database cannot be shared. */}}
{{- define "vaultwarden.replicas" -}}
{{- if or (eq .Values.storage.mode "rwo") (eq .Values.database.type "sqlite") -}}
1
{{- else -}}
{{- .Values.replicas -}}
{{- end -}}
{{- end }}

{{/* True ("true") when more than one pod can run (replicas or HPA). */}}
{{- define "vaultwarden.multiPod" -}}
{{- if or (gt (int (include "vaultwarden.replicas" .)) 1) (and .Values.autoscaling.enabled (gt (int .Values.autoscaling.maxReplicas) 1) (ne .Values.storage.mode "rwo") (ne .Values.database.type "sqlite")) -}}
true
{{- end -}}
{{- end }}

{{/* Image ref helper: dict {img:{repository,tag,digest}, root}. */}}
{{- define "vaultwarden.image" -}}
{{- $img := .img -}}
{{- $reg := .root.Values.image.registry -}}
{{- $ref := $img.repository -}}
{{- if $reg -}}{{- $ref = printf "%s/%s" $reg $img.repository -}}{{- end -}}
{{- if $img.digest -}}
{{- printf "%s@%s" $ref $img.digest -}}
{{- else -}}
{{- printf "%s:%s" $ref (toString ($img.tag | default .root.Chart.AppVersion)) -}}
{{- end -}}
{{- end }}

{{/* Vaultwarden image: s3Repository when storage.mode=s3 (official image lacks the s3 feature). */}}
{{- define "vaultwarden.appImage" -}}
{{- $tag := .Values.image.tag | default (printf "%s-alpine" .Chart.AppVersion) -}}
{{- $img := dict "repository" .Values.image.repository "tag" $tag "digest" .Values.image.digest -}}
{{- if eq .Values.storage.mode "s3" -}}
{{- $_ := set $img "repository" .Values.image.s3Repository -}}
{{- end -}}
{{- include "vaultwarden.image" (dict "img" $img "root" .) -}}
{{- end }}

{{/* ---------- S3 (vaultwarden data) ---------- */}}

{{/* RustFS sub-chart Service name (mirrors rustfs.fullname + "-svc"). */}}
{{- define "vaultwarden.rustfs.host" -}}
{{- $r := .Values.rustfs -}}
{{- $base := "" -}}
{{- if $r.fullnameOverride -}}
{{- $base = $r.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- $name := default "rustfs" $r.nameOverride -}}
{{- if contains $name .Release.Name -}}
{{- $base = .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- $base = printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}
{{- printf "%s-svc" $base -}}
{{- end }}

{{/* Origin (scheme://host[:port]) of config.domain, path stripped. */}}
{{- define "vaultwarden.domainOrigin" -}}
{{- regexFind "^https?://[^/]+" .Values.config.domain -}}
{{- end }}

{{/* S3 endpoint used by VAULTWARDEN. With S3 storage, clients download attachments
     and Sends straight from presigned URLs built on this endpoint, so it MUST be
     reachable by end users. Bundled RustFS default: the vaultwarden public origin,
     the Ingress/HTTPRoute routing /<bucket>/ to RustFS (same-origin, no CORS). */}}
{{- define "vaultwarden.s3.endpoint" -}}
{{- if .Values.storage.s3.endpoint -}}
{{- .Values.storage.s3.endpoint | trimSuffix "/" -}}
{{- else if .Values.rustfs.enabled -}}
{{- include "vaultwarden.domainOrigin" . -}}
{{- end -}}
{{- end }}

{{/* S3 endpoint used by the chart JOBS (bucket init, wait, backup, restore): the
     in-cluster RustFS Service when bundled, else the vaultwarden endpoint. */}}
{{- define "vaultwarden.s3.internalEndpoint" -}}
{{- if .Values.rustfs.enabled -}}
{{- printf "http://%s.%s.svc:9000" (include "vaultwarden.rustfs.host" .) .Release.Namespace -}}
{{- else -}}
{{- include "vaultwarden.s3.endpoint" . -}}
{{- end -}}
{{- end }}

{{/* True when the chart routes /<bucket>/ to the bundled RustFS. */}}
{{- define "vaultwarden.rustfs.routed" -}}
{{- if and .Values.rustfs.enabled (not .Values.storage.s3.endpoint) -}}true{{- end -}}
{{- end }}

{{- define "vaultwarden.s3.secretName" -}}
{{- if .Values.rustfs.enabled -}}
{{- required "rustfs.secret.existingSecret is required" .Values.rustfs.secret.existingSecret -}}
{{- else if .Values.storage.s3.existingSecret -}}
{{- .Values.storage.s3.existingSecret -}}
{{- else -}}
{{- printf "%s-s3" (include "vaultwarden.fullname" .) -}}
{{- end -}}
{{- end }}
{{- define "vaultwarden.s3.accessKeyKey" -}}
{{- if .Values.rustfs.enabled -}}RUSTFS_ACCESS_KEY{{- else if .Values.storage.s3.existingSecret -}}{{ .Values.storage.s3.accessKeyIdKey }}{{- else -}}AWS_ACCESS_KEY_ID{{- end -}}
{{- end }}
{{- define "vaultwarden.s3.secretKeyKey" -}}
{{- if .Values.rustfs.enabled -}}RUSTFS_SECRET_KEY{{- else if .Values.storage.s3.existingSecret -}}{{ .Values.storage.s3.secretAccessKeyKey }}{{- else -}}AWS_SECRET_ACCESS_KEY{{- end -}}
{{- end }}

{{/* Bucket + prefix path, no scheme: bucket[/prefix] */}}
{{- define "vaultwarden.s3.basePath" -}}
{{- $s := .Values.storage.s3 -}}
{{- if $s.prefix -}}
{{- printf "%s/%s" $s.bucket ($s.prefix | trimAll "/") -}}
{{- else -}}
{{- $s.bucket -}}
{{- end -}}
{{- end }}

{{/* OpenDAL S3 URI for a sub-folder: dict {root, folder}.
     s3://bucket/prefix/<folder>?endpoint=..&region=..&enable_virtual_host_style=..&default_storage_class=.. */}}
{{- define "vaultwarden.s3.uri" -}}
{{- $root := .root -}}
{{- $s := $root.Values.storage.s3 -}}
{{- $q := list (printf "region=%s" $s.region) (printf "enable_virtual_host_style=%t" $s.virtualHostStyle) -}}
{{- with (include "vaultwarden.s3.endpoint" $root) -}}
{{- $q = prepend $q (printf "endpoint=%s" .) -}}
{{- end -}}
{{- with $s.storageClass -}}
{{- $q = append $q (printf "default_storage_class=%s" .) -}}
{{- end -}}
{{- printf "s3://%s/%s?%s" (include "vaultwarden.s3.basePath" $root) .folder (join "&" $q) -}}
{{- end }}

{{/* ---------- Backup S3 target ---------- */}}

{{- define "vaultwarden.backup.secretName" -}}
{{- .Values.backup.s3.existingSecret | default (printf "%s-backup" (include "vaultwarden.fullname" .)) -}}
{{- end }}
{{- define "vaultwarden.backup.accessKeyKey" -}}
{{- if .Values.backup.s3.existingSecret -}}{{ .Values.backup.s3.accessKeyIdKey }}{{- else -}}AWS_ACCESS_KEY_ID{{- end -}}
{{- end }}
{{- define "vaultwarden.backup.secretKeyKey" -}}
{{- if .Values.backup.s3.existingSecret -}}{{ .Values.backup.s3.secretAccessKeyKey }}{{- else -}}AWS_SECRET_ACCESS_KEY{{- end -}}
{{- end }}

{{- define "vaultwarden.backup.dbEnabled" -}}
{{- if and .Values.backup.database.enabled (eq .Values.database.type "cnpg") -}}true{{- end -}}
{{- end }}
{{- define "vaultwarden.backup.filesEnabled" -}}
{{- if .Values.backup.files.enabled -}}true{{- end -}}
{{- end }}
{{- define "vaultwarden.backup.anyEnabled" -}}
{{- if or (include "vaultwarden.backup.dbEnabled" .) (include "vaultwarden.backup.filesEnabled" .) -}}true{{- end -}}
{{- end }}

{{/* restic repository: s3:<endpoint>/<bucket>/<path> */}}
{{- define "vaultwarden.backup.resticRepo" -}}
{{- $b := .Values.backup.s3 -}}
{{- $ep := $b.endpoint | default (printf "https://s3.%s.amazonaws.com" $b.region) | trimSuffix "/" -}}
{{- printf "s3:%s/%s/%s" $ep $b.bucket (.Values.backup.files.path | trimAll "/") -}}
{{- end }}

{{/* ---------- Validation (fail fast at render time) ---------- */}}
{{- define "vaultwarden.validate" -}}
{{- $mode := .Values.storage.mode -}}
{{- $db := .Values.database.type -}}
{{- if not (has $mode (list "rwx" "rwo" "s3")) -}}
{{- fail (printf "storage.mode must be one of rwx|rwo|s3 (got %q)" $mode) -}}
{{- end -}}
{{- if not (has $db (list "cnpg" "external" "sqlite")) -}}
{{- fail (printf "database.type must be one of cnpg|external|sqlite (got %q)" $db) -}}
{{- end -}}
{{- if not .Values.config.domain -}}
{{- fail "config.domain is required (public URL, e.g. https://vault.example.com)" -}}
{{- end -}}
{{- if not (regexMatch "^https?://" .Values.config.domain) -}}
{{- fail "config.domain must start with https:// (or http:// for local tests)" -}}
{{- end -}}
{{- if and (gt (int .Values.replicas) 1) (eq $mode "rwo") -}}
{{- fail "replicas > 1 needs a shared data store: set storage.mode=rwx (RWX StorageClass) or storage.mode=s3, or replicas=1 for rwo" -}}
{{- end -}}
{{- if and (gt (int .Values.replicas) 1) (eq $db "sqlite") -}}
{{- fail "replicas > 1 needs a network database: database.type=cnpg or external (sqlite is single-writer)" -}}
{{- end -}}
{{- if and (eq $mode "s3") (eq $db "sqlite") -}}
{{- fail "database.type=sqlite cannot live in S3: use cnpg/external, or storage.mode=rwx|rwo" -}}
{{- end -}}
{{- if and .Values.rustfs.enabled (ne $mode "s3") -}}
{{- fail "rustfs.enabled=true only makes sense with storage.mode=s3" -}}
{{- end -}}
{{- if and (eq $mode "s3") (not .Values.rustfs.enabled) (not .Values.storage.s3.existingSecret) (not (and .Values.storage.s3.accessKeyId .Values.storage.s3.secretAccessKey)) -}}
{{- fail "storage.mode=s3 needs credentials: storage.s3.existingSecret, inline storage.s3.accessKeyId/secretAccessKey, or rustfs.enabled=true" -}}
{{- end -}}
{{- if and (include "vaultwarden.rustfs.routed" .) (has .Values.storage.s3.bucket (list "api" "identity" "admin" "attachments" "icons" "notifications" "alive" "images" "app" "events" "sends" "vw_static" "locales" "fonts")) -}}
{{- fail (printf "storage.s3.bucket %q collides with a vaultwarden route: the bundled RustFS is served on /<bucket>/ of config.domain, pick another name" .Values.storage.s3.bucket) -}}
{{- end -}}
{{- if and (eq $mode "s3") (not .Values.storage.s3.bucket) -}}
{{- fail "storage.s3.bucket is required with storage.mode=s3" -}}
{{- end -}}
{{- if and (eq $db "external") (not .Values.externalDatabase.url) (not .Values.externalDatabase.existingSecret) -}}
{{- fail "database.type=external needs externalDatabase.url or externalDatabase.existingSecret" -}}
{{- end -}}
{{- if and .Values.cnpg.recovery.enabled (eq $db "cnpg") (not .Values.cnpg.recovery.objectStore) -}}
{{- fail "cnpg.recovery.enabled needs cnpg.recovery.objectStore (barman-cloud ObjectStore with the source backups)" -}}
{{- end -}}
{{- if include "vaultwarden.backup.anyEnabled" . -}}
{{- if not .Values.backup.s3.bucket -}}
{{- fail "Backups are enabled by default and need an off-site S3 target: set backup.s3.bucket (+ endpoint, credentials). To opt out explicitly: backup.database.enabled=false (CNPG) and/or backup.files.enabled=false (e.g. Velero snapshots the PVC)" -}}
{{- end -}}
{{- if and (not .Values.backup.s3.existingSecret) (not (and .Values.backup.s3.accessKeyId .Values.backup.s3.secretAccessKey)) -}}
{{- fail "backup.s3 needs credentials: backup.s3.existingSecret or inline backup.s3.accessKeyId/secretAccessKey" -}}
{{- end -}}
{{- end -}}
{{- if and .Values.config.sso.enabled (or (not .Values.config.sso.authority) (not .Values.config.sso.clientId)) -}}
{{- fail "config.sso.enabled needs config.sso.authority and config.sso.clientId" -}}
{{- end -}}
{{- if and .Values.config.push.enabled (not .Values.config.push.installationId) -}}
{{- fail "config.push.enabled needs config.push.installationId (+ push-installation-key secret)" -}}
{{- end -}}
{{- end }}

{{- /*
  Per-key value resolution, highest priority first:
    1. Inline value in values (deterministic, recommended with ArgoCD, whose
       `lookup` is unreliable during diff/sync and would otherwise re-roll randoms).
    2. Existing in-cluster Secret (preserves a previously generated value on upgrade).
    3. Freshly generated (only for values the chart can generate).
*/ -}}
{{- define "vaultwarden.resolve" -}}
{{- $v := .inline | default "" -}}
{{- if and (not $v) .existing (hasKey .existing.data .key) -}}
{{- $v = index .existing.data .key | b64dec -}}
{{- end -}}
{{- $v -}}
{{- end -}}

{{/* Dedicated scheduler Deployment: only when several server pods can run. */}}
{{- define "vaultwarden.scheduler.enabled" -}}
{{- if and .Values.scheduler.enabled (include "vaultwarden.multiPod" .) -}}true{{- end -}}
{{- end }}

{{/* Checksum of the secret material set inline in values (rolls the pods on change). */}}
{{- define "vaultwarden.inlineSecretsChecksum" -}}
{{- $s := dict "config" .Values.config.secrets "db" .Values.externalDatabase.url "s3" (list .Values.storage.s3.accessKeyId .Values.storage.s3.secretAccessKey) -}}
{{- toJson $s | sha256sum | trunc 16 -}}
{{- end }}

{{/* Port of a URL origin: explicit :port, else 443 (https) / 80 (http). */}}
{{- define "vaultwarden.urlPort" -}}
{{- $p := regexFind ":[0-9]+$" (regexFind "^[a-z]+://[^/]+" .) | trimPrefix ":" -}}
{{- if $p -}}{{ $p }}{{- else if hasPrefix "http://" . -}}80{{- else -}}443{{- end -}}
{{- end }}

{{/* NetworkPolicy peers "anywhere": external IPs (v4/v6) and in-cluster pods (some
     CNIs, e.g. Cilium, do not match pod IPs with an ipBlock 0.0.0.0/0). */}}
{{- define "vaultwarden.netpol.anywhere" -}}
- ipBlock:
    cidr: 0.0.0.0/0
- ipBlock:
    cidr: ::/0
- namespaceSelector: {}
{{- end }}
