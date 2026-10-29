#!/bin/bash
# argocd CLI 없이 Application 을 수동 sync 하고 끝날 때까지 기다린다(runbook 5절).
#   scripts/argo-sync.sh <application>...   (kubectl 컨텍스트: KUBE_CONTEXT, 기본 nerdnam-dev)
# Application 의 syncOptions(CreateNamespace·ServerSideApply)를 operation 에 옮긴다. 빠뜨리면 namespace 가 안 생기고
# 큰 CRD 가 annotation 크기 제한(262144 bytes)에 걸린다(2026-10-29 첫 배포에서 확인).
K="kubectl --context ${KUBE_CONTEXT:-nerdnam-dev} -n argocd"
for app in "$@"; do
  # argocd CLI 처럼 Application 의 syncOptions(CreateNamespace·ServerSideApply 등)를 operation 에 옮긴다
  opts=$($K get application "$app" -o jsonpath='{.spec.syncPolicy.syncOptions}')
  [ -z "$opts" ] && opts='[]'
  $K patch application "$app" --type merge -p "{\"operation\":{\"initiatedBy\":{\"username\":\"runbook\"},\"sync\":{\"syncOptions\":$opts}}}" >/dev/null
done
for app in "$@"; do
  for i in $(seq 1 200); do
    phase=$($K get application "$app" -o jsonpath='{.status.operationState.phase}')
    sync=$($K get application "$app" -o jsonpath='{.status.sync.status}')
    health=$($K get application "$app" -o jsonpath='{.status.health.status}')
    if [ "$phase" = Failed ] || [ "$phase" = Error ]; then break; fi
    if [ "$phase" = Succeeded ] && [ "$health" = Healthy ]; then break; fi
    sleep 3
  done
  echo "$app phase=$phase sync=$sync health=$health"
  [ "$health" = Healthy ] || $K get application "$app" -o jsonpath='{.status.operationState.message}{"\n"}{range .status.resources[?(@.health.status!="Healthy")]}{.kind}/{.namespace}/{.name} {.health.status} {.health.message}{"\n"}{end}' | head -15
done
