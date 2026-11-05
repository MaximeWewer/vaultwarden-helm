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

{{/* Job specs (jobs.yaml): rendered first so the Job name can hash them. */}}
{{- define "vaultwarden.job.bucket.spec" -}}
{{- $rc := .Values.backup.files.rclone.image }}
backoffLimit: 10
template:
  metadata:
    labels:
      app.kubernetes.io/component: bucket-init
      {{- include "vaultwarden.selectorLabels" . | nindent 6 }}
  spec:
    restartPolicy: OnFailure
    serviceAccountName: {{ include "vaultwarden.serviceAccountName" . }}
    automountServiceAccountToken: false
    enableServiceLinks: false
    {{- with .Values.imagePullSecrets }}
    imagePullSecrets:
      {{- toYaml . | nindent 6 }}
    {{- end }}
    securityContext:
      {{- include "vaultwarden.backup.podSecurityContext" . | nindent 6 }}
    containers:
      - name: mkdir
        image: {{ include "vaultwarden.image" (dict "img" $rc "root" .) | quote }}
        imagePullPolicy: {{ .Values.image.pullPolicy }}
        args: ["mkdir", {{ printf "vw:%s" .Values.storage.s3.bucket | quote }}, "-v"]
        env:
          {{- include "vaultwarden.rclone.env" . | nindent 10 }}
        securityContext:
          {{- toYaml .Values.containerSecurityContext | nindent 10 }}
        resources:
          requests:
            cpu: 10m
            memory: 32Mi
          limits:
            memory: 128Mi
        volumeMounts:
          - name: tmp
            mountPath: /tmp
    volumes:
      - name: tmp
        emptyDir: {}
{{- end }}

{{- define "vaultwarden.job.restore.spec" -}}
{{- $f := .Values.backup.files }}
{{- $s3 := eq .Values.storage.mode "s3" }}
backoffLimit: 1
template:
  metadata:
    labels:
      app.kubernetes.io/component: restore
      {{- include "vaultwarden.selectorLabels" . | nindent 6 }}
  spec:
    restartPolicy: Never
    serviceAccountName: {{ include "vaultwarden.serviceAccountName" . }}
    automountServiceAccountToken: false
    enableServiceLinks: false
    {{- with .Values.imagePullSecrets }}
    imagePullSecrets:
      {{- toYaml . | nindent 6 }}
    {{- end }}
    securityContext:
      {{- include "vaultwarden.backup.podSecurityContext" . | nindent 6 }}
    {{- /* No rwo pod affinity here: vaultwarden is scaled to 0, the volume is free. */}}
    {{- if $s3 }}
    initContainers:
    {{- else }}
    containers:
    {{- end }}
      - name: restic
        image: {{ include "vaultwarden.image" (dict "img" $f.image "root" .) | quote }}
        imagePullPolicy: {{ .Values.image.pullPolicy }}
        command: ["/bin/sh", "-ec"]
        args:
          - |
            SNAP={{ $f.restore.snapshot | quote }}
            if [ "$SNAP" = "latest" ]; then SNAP="latest --host $RESTIC_HOST"; fi
            # Snapshots store absolute /data/... paths: restore to /restore/data.
            restic $RESTIC_OPTS restore $SNAP --target /restore --verify
            {{- if not $s3 }}
            # Copy entries (not the mount root itself: its owner/mode belong to the volume).
            for f in /restore/data/* /restore/data/.[!.]*; do if [ -e "$f" ]; then cp -a "$f" /data/; fi; done
            {{- if eq .Values.database.type "sqlite" }}
            # sqlite: the DB was backed up as a consistent copy in /snapshot.
            if [ -f /restore/snapshot/db.sqlite3 ]; then
              rm -f /data/db.sqlite3-wal /data/db.sqlite3-shm
              cp /restore/snapshot/db.sqlite3 /data/db.sqlite3
            fi
            {{- end }}
            {{- end }}
            echo "restore done"
        env:
          {{- include "vaultwarden.restic.env" . | nindent 10 }}
        securityContext:
          {{- toYaml .Values.containerSecurityContext | nindent 10 }}
        resources:
          {{- toYaml $f.resources | nindent 10 }}
        volumeMounts:
          - name: restore
            mountPath: /restore
          - name: cache
            mountPath: /cache
          - name: tmp
            mountPath: /tmp
          {{- if not $s3 }}
          - name: data
            mountPath: /data
          {{- end }}
    {{- if $s3 }}
    containers:
      # Push the restored objects back into the vaultwarden bucket.
      - name: push-bucket
        image: {{ include "vaultwarden.image" (dict "img" $f.rclone.image "root" .) | quote }}
        imagePullPolicy: {{ .Values.image.pullPolicy }}
        args:
          - copy
          - /restore/data
          - {{ printf "vw:%s" (include "vaultwarden.s3.basePath" .) | quote }}
          - --stats-one-line
          - -v
        env:
          {{- include "vaultwarden.rclone.env" . | nindent 10 }}
        securityContext:
          {{- toYaml .Values.containerSecurityContext | nindent 10 }}
        resources:
          {{- toYaml $f.resources | nindent 10 }}
        volumeMounts:
          - name: restore
            mountPath: /restore
          - name: tmp
            mountPath: /tmp
    {{- end }}
    volumes:
      - name: restore
        emptyDir:
          sizeLimit: {{ $f.rclone.scratchSizeLimit }}
      - name: cache
        emptyDir: {}
      - name: tmp
        emptyDir: {}
      {{- if not $s3 }}
      - name: data
        persistentVolumeClaim:
          claimName: {{ include "vaultwarden.pvcName" . }}
      {{- end }}
{{- end }}
