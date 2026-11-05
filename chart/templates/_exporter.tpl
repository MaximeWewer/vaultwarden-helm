{{/* vaultwarden-exporter helpers (exporter.yaml) */}}

{{/* events.labels map as the exporter env format: k=v,k2=v2 (sorted) */}}
{{- define "vaultwarden.exporter.labelsEnv" -}}
{{- $out := list -}}
{{- range $k := keys . | sortAlpha -}}
{{- $out = append $out (printf "%s=%s" $k (index $ $k)) -}}
{{- end -}}
{{- join "," $out -}}
{{- end }}

{{/* Grants Job spec: rendered first so that the Job name can hash it */}}
{{- define "vaultwarden.exporter.grantsJob.spec" -}}
{{- $x := .Values.exporter }}
backoffLimit: 30
template:
  metadata:
    labels:
      app.kubernetes.io/component: exporter-grants
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
      - name: grants
        image: {{ include "vaultwarden.image" (dict "img" (dict "repository" "postgres" "tag" "17-alpine" "digest" "") "root" .) | quote }}
        imagePullPolicy: {{ .Values.image.pullPolicy }}
        command: ["/bin/sh", "-c"]
        args:
          - psql "$APP_URI" -X -q -v ON_ERROR_STOP=1 -v role={{ $x.database.role | quote }} -f /sql/grants.sql && echo "grants applied"
        env:
          - name: APP_URI
            valueFrom:
              secretKeyRef:
                name: {{ include "vaultwarden.cnpg.fullname" . }}-app
                key: uri
          - name: HOME
            value: /tmp
        securityContext:
          {{- toYaml .Values.containerSecurityContext | nindent 10 }}
        resources:
          requests:
            cpu: 10m
            memory: 32Mi
          limits:
            memory: 128Mi
        volumeMounts:
          - name: sql
            mountPath: /sql
            readOnly: true
          - name: tmp
            mountPath: /tmp
    volumes:
      - name: sql
        configMap:
          name: {{ include "vaultwarden.exporter.fullname" . }}-grants
      - name: tmp
        emptyDir: {}
{{- end }}
