{{/* ECR 이미지 참조: 필수이며 digest 고정이어야 한다. */}}
{{- define "apps.image" -}}
{{- $ref := required (printf "images.%s is required (gitops/apps/images.yaml)" .name) (index (.root.Values.images | default dict) .name) -}}
{{- if not (regexMatch "^[0-9]{12}\\.dkr\\.ecr\\.[a-z0-9-]+\\.amazonaws\\.com/[a-z0-9./_-]+@sha256:[a-f0-9]{64}$" $ref) -}}
{{- fail (printf "images.%s must be an ECR image pinned by @sha256 digest" .name) -}}
{{- end -}}
{{- $ref -}}
{{- end -}}

{{/* 공통 Pod 보안·배치. */}}
{{- define "apps.podSecurity" -}}
automountServiceAccountToken: false
enableServiceLinks: false
nodeSelector: {{ toYaml .root.Values.placement.nodeSelector | nindent 2 }}
securityContext:
  runAsNonRoot: true
  runAsUser: {{ .app.uid }}
  runAsGroup: {{ .app.gid }}
  seccompProfile: {type: RuntimeDefault}
{{- end -}}

{{- define "apps.containerSecurity" -}}
allowPrivilegeEscalation: false
readOnlyRootFilesystem: true
capabilities: {drop: [ALL]}
{{- end -}}

{{- define "apps.publicOrigin" -}}
https://{{ required "environment.appHostname is required" .Values.environment.appHostname }}
{{- end -}}
