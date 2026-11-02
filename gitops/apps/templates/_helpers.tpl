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

{{/* 8단계 trace: 표준 OTEL_* 환경 변수. 지표는 Prometheus, 로그는 stdout → Loki 라 OTLP 로는 trace 만 보낸다. */}}
{{- define "apps.otelEnv" -}}
{{- $t := .root.Values.tracing -}}
- name: K8S_POD_NAME
  valueFrom: {fieldRef: {fieldPath: metadata.name}}
- {name: OTEL_SERVICE_NAME, value: {{ .name | quote }}}
- {name: OTEL_RESOURCE_ATTRIBUTES, value: "k8s.cluster.name={{ required "environment.clusterName is required" .root.Values.environment.clusterName }},k8s.namespace.name=nerdnam,k8s.pod.name=$(K8S_POD_NAME)"}
- {name: OTEL_EXPORTER_OTLP_ENDPOINT, value: "http://{{ $t.alloyHost }}:{{ $t.otlpHttpPort }}"}
- {name: OTEL_EXPORTER_OTLP_PROTOCOL, value: http/protobuf}
- {name: OTEL_TRACES_EXPORTER, value: otlp}
- {name: OTEL_METRICS_EXPORTER, value: none}
- {name: OTEL_LOGS_EXPORTER, value: none}
- {name: OTEL_TRACES_SAMPLER, value: parentbased_traceidratio}
- {name: OTEL_TRACES_SAMPLER_ARG, value: {{ $t.sampleRatio | quote }}}
{{- end -}}

{{/* 8단계: 각 앱 → monitoring/alloy OTLP HTTP. */}}
{{- define "apps.otlpEgress" -}}
- to:
    - namespaceSelector:
        matchLabels: {kubernetes.io/metadata.name: monitoring}
      podSelector:
        matchLabels: {app.kubernetes.io/name: alloy}
  ports: [{protocol: TCP, port: {{ .Values.tracing.otlpHttpPort }}}]
{{- end -}}
