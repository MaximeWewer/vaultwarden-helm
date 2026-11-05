{{/* Shared pieces of the restic backup CronJob and restore Job. */}}

{{/* restic env: repository, password, backup S3 credentials. */}}
{{- define "vaultwarden.restic.env" -}}
- name: RESTIC_REPOSITORY
  value: {{ include "vaultwarden.backup.resticRepo" . | quote }}
- name: RESTIC_PASSWORD
  valueFrom:
    secretKeyRef:
      name: {{ printf "%s-restic" (include "vaultwarden.fullname" .) }}
      key: RESTIC_PASSWORD
- name: AWS_ACCESS_KEY_ID
  valueFrom:
    secretKeyRef:
      name: {{ include "vaultwarden.backup.secretName" . }}
      key: {{ include "vaultwarden.backup.accessKeyKey" . }}
- name: AWS_SECRET_ACCESS_KEY
  valueFrom:
    secretKeyRef:
      name: {{ include "vaultwarden.backup.secretName" . }}
      key: {{ include "vaultwarden.backup.secretKeyKey" . }}
- name: AWS_DEFAULT_REGION
  value: {{ .Values.backup.s3.region | quote }}
- name: RESTIC_OPTS
  value: {{ printf "-o s3.region=%s%s" .Values.backup.s3.region (ternary " -o s3.bucket-lookup=path" "" .Values.backup.s3.forcePathStyle) | quote }}
- name: RESTIC_HOST
  value: {{ include "vaultwarden.fullname" . | quote }}
- name: RESTIC_CACHE_DIR
  value: /cache
- name: HOME
  value: /tmp
{{- end }}

{{/* rclone remote "vw" = the vaultwarden data bucket (storage.mode=s3). */}}
{{- define "vaultwarden.rclone.env" -}}
- name: RCLONE_CONFIG
  value: /tmp/rclone.conf
- name: RCLONE_CONFIG_VW_TYPE
  value: s3
- name: RCLONE_CONFIG_VW_PROVIDER
  value: {{ ternary "Other" "AWS" (ne (include "vaultwarden.s3.internalEndpoint" .) "") | quote }}
{{- with (include "vaultwarden.s3.internalEndpoint" .) }}
- name: RCLONE_CONFIG_VW_ENDPOINT
  value: {{ . | quote }}
{{- end }}
- name: RCLONE_CONFIG_VW_REGION
  value: {{ .Values.storage.s3.region | quote }}
- name: RCLONE_CONFIG_VW_FORCE_PATH_STYLE
  value: {{ (not .Values.storage.s3.virtualHostStyle) | quote }}
- name: RCLONE_CONFIG_VW_ACCESS_KEY_ID
  valueFrom:
    secretKeyRef:
      name: {{ include "vaultwarden.s3.secretName" . }}
      key: {{ include "vaultwarden.s3.accessKeyKey" . }}
- name: RCLONE_CONFIG_VW_SECRET_ACCESS_KEY
  valueFrom:
    secretKeyRef:
      name: {{ include "vaultwarden.s3.secretName" . }}
      key: {{ include "vaultwarden.s3.secretKeyKey" . }}
- name: HOME
  value: /tmp
{{- end }}

{{- define "vaultwarden.backup.podSecurityContext" -}}
runAsNonRoot: true
runAsUser: {{ .Values.podSecurityContext.runAsUser | default 1000 }}
runAsGroup: {{ .Values.podSecurityContext.runAsGroup | default 1000 }}
fsGroup: {{ .Values.podSecurityContext.fsGroup | default 1000 }}
fsGroupChangePolicy: OnRootMismatch
seccompProfile:
  type: RuntimeDefault
{{- end }}

{{/* storage.mode=rwo: the RWO volume is only attachable on the node running
     vaultwarden, so the job pod must land on that node. */}}
{{- define "vaultwarden.backup.rwoAffinity" -}}
{{- if eq .Values.storage.mode "rwo" }}
affinity:
  podAffinity:
    requiredDuringSchedulingIgnoredDuringExecution:
      - topologyKey: kubernetes.io/hostname
        labelSelector:
          matchLabels:
            app.kubernetes.io/component: server
            {{- include "vaultwarden.selectorLabels" . | nindent 12 }}
{{- end }}
{{- end }}
