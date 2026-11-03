#!/usr/bin/env bash
# 부하 시험(k6-operator TestRun) 실행 도우미. 사용법·결과 읽는 법: docs/부하-시험-실행.md
#
#   scripts/load-test.sh run <smoke|rate|concurrency|ai-analysis|ai-guide> [옵션]
#                                    시험 하나를 끝까지 돌리고 요약·Grafana 링크를 낸다. ai-* 는 실제 Bedrock 을 부른다(요금)
#       --stages "<목표:시간,...>"   rate·concurrency 단계 바꾸기 (예: "80:20s,80:1m,100:20s,100:1m,0:20s")
#       --env 이름=값                 TestRun 환경 변수 바꾸기(여러 번). ai-* 는 POSTING_IDS 필수 (예: --env POSTING_IDS=3,4,5)
#       --session                    로그인 경로까지(시험 계정 SESSION 쿠키를 입력받아 Secret 으로 넣고 끝나면 지운다)
#       --keep                       끝난 뒤 TestRun 을 지우지 않는다(로그를 더 볼 때)
#       --dry-run                    만들 TestRun 을 서버에서 검사만 하고 끝낸다(부하 없음)
#       -y                           시작 전 확인을 묻지 않는다
#   scripts/load-test.sh status      지금 시험·Pod·quota
#   scripts/load-test.sh logs [이름] k6 요약(이름이 없으면 가장 최근 시험)
#   scripts/load-test.sh stop        도는 시험을 모두 멈추고 지운다
#
# 시험 도중 Ctrl+C 를 누르면 시험도 함께 멈춘다(부하만 남지 않게).
set -euo pipefail

cd "$(dirname "$0")/.."

CTX="${KUBE_CONTEXT:-nerdnam-dev}"
NS=load-test
GRAFANA=https://grafana.nerdnam.click
DASHBOARD_UID=nerdnam-load
SESSION_SECRET=k6-session

kc() { kubectl --context "$CTX" "$@"; }
log() { printf '\n\033[1m== %s\033[0m\n' "$*"; }
warn() { printf '\033[33m%s\033[0m\n' "$*"; }
die() { printf '\n\033[31m중단: %s\033[0m\n' "$*" >&2; exit 1; }
usage() { sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }

# "50:20s,50:1m" 같은 단계 목록의 전체 시간(초)
stages_seconds() {
  local total=0 item dur n unit
  IFS=',' read -r -a items <<<"$1"
  for item in "${items[@]}"; do
    dur=${item#*:}; n=${dur%[smh]}; unit=${dur: -1}
    case $unit in s) total=$((total + n)) ;; m) total=$((total + n * 60)) ;; h) total=$((total + n * 3600)) ;; esac
  done
  echo "$total"
}
duration_seconds() { stages_seconds "0:$1"; }

# 끝나지 않은 시험 이름 목록
active_runs() {
  kc -n "$NS" get testrun -o json | jq -r '.items[] | select(.status.stage != "finished" and .status.stage != "error") | .metadata.name'
}

preflight() {
  log "1. 확인"
  kc get namespace "$NS" >/dev/null 2>&1 \
    || die "클러스터에 닿지 않습니다. 노드가 꺼져 있으면 scripts/cluster.sh up, 관리 IP 가 바뀌었으면 docs/운영-중지-재개.md 4절."
  local ready
  ready=$(kc get nodes --no-headers 2>/dev/null | awk '$2=="Ready"' | wc -l | tr -d ' ')
  [ "$ready" -ge 3 ] || die "Ready 노드가 $ready 대입니다(3대 필요). scripts/cluster.sh up 먼저."
  kc -n k6-operator get deploy -o jsonpath='{.items[0].status.readyReplicas}' 2>/dev/null | grep -q '^1$' \
    || die "k6-operator 가 준비되지 않았습니다(Argo 의 k6-operator 앱 확인)."
  kc -n "$NS" get configmap k6-scripts k6-env >/dev/null 2>&1 || die "k6-scripts·k6-env ConfigMap 이 없습니다(Argo 의 nerdnam-load 앱 sync)."
  local active
  active=$(active_runs)
  [ -z "$active" ] || die "다른 시험이 진행 중입니다: $(echo $active). 끝날 때까지 기다리거나 'scripts/load-test.sh stop'."
  # 끝난 시험(finished·error)은 지운다. 지표는 Prometheus 에 남는다.
  local old
  old=$(kc -n "$NS" get testrun -o name 2>/dev/null || true)
  [ -z "$old" ] || { kc -n "$NS" delete $old >/dev/null; echo "끝난 시험 정리: $(echo $old | sed 's#testrun.k6.io/##g')"; }
  echo "클러스터 정상(노드 $ready 대), k6-operator 준비됨, 도는 시험 없음"
  if git fetch -q origin main 2>/dev/null && ! git diff --quiet origin/main -- "gitops/load/testruns/$SCENARIO.yaml" 2>/dev/null; then
    warn "로컬 gitops/load/testruns/$SCENARIO.yaml 이 origin/main 과 다릅니다(git pull 또는 의도한 수정인지 확인)."
  fi
}

cmd_run() {
  SCENARIO="${1:-}"; shift || true
  case "$SCENARIO" in smoke|rate|concurrency|ai-analysis|ai-guide) ;; *) usage ;; esac
  local stages="" session=0 keep=0 dry=0 yes=0 extra='{}'
  while [ $# -gt 0 ]; do
    case "$1" in
      --stages) stages="${2:-}"; shift 2 ;;
      --env)
        [[ "${2:-}" =~ ^([A-Z_][A-Z0-9_]*)=(.*)$ ]] || die "--env 형식: 이름=값 (예: POSTING_IDS=3,4,5)"
        extra=$(jq --arg k "${BASH_REMATCH[1]}" --arg v "${BASH_REMATCH[2]}" '. + {($k): $v}' <<<"$extra"); shift 2 ;;
      --session) session=1; shift ;;
      --keep) keep=1; shift ;;
      --dry-run) dry=1; shift ;;
      -y|--yes) yes=1; shift ;;
      *) usage ;;
    esac
  done
  if [ -n "$stages" ]; then
    [[ "$SCENARIO" =~ ^(rate|concurrency)$ ]] || die "--stages 는 rate·concurrency 만 받습니다(ai-* 는 --env RATE_NORMAL=·RATE_SURGE=)."
    [[ "$stages" =~ ^([0-9]+:[0-9]+[smh],)*[0-9]+:[0-9]+[smh]$ ]] || die "--stages 형식: \"목표:시간,목표:시간,...\" (시간은 20s·1m·1h)"
  fi

  preflight

  # 대시보드는 TestRun 이름(testrun_name, k6-operator 가 지표에 붙임)으로 시험을 고른다. 이름은 만든 뒤에 정해진다.
  local manifest
  manifest=$(kc create --dry-run=client -f "gitops/load/testruns/$SCENARIO.yaml" -o json | jq --arg st "$stages" --argjson extra "$extra" '
    def setenv($n; $v): map(select(.name != $n)) + [{name: $n, value: $v}];
    (if $st != "" then {STAGES: $st} else {} end) + $extra as $set
    | reduce ($set | to_entries[]) as $e (.; .spec.runner.env |= setenv($e.key; $e.value) | .spec.initializer.env |= setenv($e.key; $e.value))')
  local ai=0; [[ "$SCENARIO" == ai-* ]] && ai=1
  if [ "$ai" = 1 ] && [ "$dry" != 1 ]; then
    [ -n "$(jq -r '.spec.runner.env[] | select(.name=="POSTING_IDS") | .value' <<<"$manifest")" ] \
      || die "ai-* 는 공고 id 가 필요합니다: --env POSTING_IDS=3,4,5 (분석이 한 번 끝난 시험 계정 공고)"
    [ "$session" = 1 ] || kc -n "$NS" get secret "$SESSION_SECRET" >/dev/null 2>&1 \
      || die "ai-* 는 시험 계정 로그인이 필요합니다: --session"
  fi

  local env_stages env_duration est target
  env_stages=$(jq -r '.spec.runner.env[] | select(.name=="STAGES") | .value' <<<"$manifest")
  env_duration=$(jq -r '.spec.runner.env[] | select(.name=="DURATION") | .value' <<<"$manifest")
  local env_of; env_of() { jq -r --arg n "$1" '.spec.runner.env[] | select(.name==$n) | .value' <<<"$manifest"; }
  local job_timeout=0
  if [ "$ai" = 1 ]; then
    est=$(( $(duration_seconds "$(env_of DURATION_NORMAL | sed 's/^$/5m/')") + $(duration_seconds "$(env_of PAUSE | sed 's/^$/2m/')") + $(duration_seconds "$(env_of DURATION_SURGE | sed 's/^$/5m/')") ))
    job_timeout=$(env_of JOB_TIMEOUT_SECONDS); job_timeout=${job_timeout:-600}
  elif [ -n "$env_stages" ]; then est=$(stages_seconds "$env_stages"); else est=$(duration_seconds "${env_duration:-2m}"); fi
  target=$(kc -n "$NS" get configmap k6-env -o jsonpath='{.data.BASE_URL}')

  log "2. 시험 내용"
  echo "시험      : $SCENARIO"
  echo "대상      : $target (실제 서비스)"
  if [ "$ai" = 1 ]; then
    echo "흐름      : 정상 분당 $(env_of RATE_NORMAL | sed "s/^$/기본/")건 → 쉼 → 몰림 분당 $(env_of RATE_SURGE | sed "s/^$/기본/")건 (기본: analysis 2→5, guide 3→6)"
    echo "공고      : $(env_of POSTING_IDS)"
    echo "예상 시간 : 약 $(( (est + 59) / 60 ))분 + 남은 작업 마무리 최대 $(( job_timeout / 60 ))분 (+ 준비 1분)"
  else
    [ -n "$env_stages" ] && echo "단계      : $env_stages" || echo "고정      : 초당 반복 $(env_of RATE)회, ${env_duration}"
    echo "예상 시간 : 약 $(( (est + 59) / 60 ))분 (+ 준비 1분)"
  fi
  echo "로그인 경로: $([ $session = 1 ] && echo 포함 || echo '제외(비로그인 경로만)')"

  if [ "$dry" = 1 ]; then
    kc create --dry-run=server -f - <<<"$manifest" >/dev/null && echo; echo "--dry-run: 서버 검사 통과. 시험은 만들지 않았습니다."
    return
  fi

  if [ "$yes" != 1 ]; then
    if [ "$ai" = 1 ]; then
      warn "실제 Bedrock 을 부릅니다(요금: analysis 약 35건 / guide 약 225회). 실행 시간대를 팀에 공지했는지, 문서 업로드·다른 AI 사용을 멈췄는지 확인하세요."
      warn "몰림 단계에서 AI 작업이 실패하거나 밀리는 것이 목적입니다(재현). 한동안 쉬던 뒤라면 시험 직전 AI 요청 몇 개로 데우세요."
    elif [ "$SCENARIO" != smoke ]; then
      warn "마지막 단계는 일부러 서버 한계를 넘깁니다. 시험 중에는 실제 사용자도 느려질 수 있습니다."
    fi
    read -r -p "시작할까요? [y/N] " ans
    [[ "$ans" =~ ^[yY]$ ]] || die "취소했습니다."
  fi

  local secret_made=0 name=""
  cleanup() {
    [ -n "$name" ] && [ "$keep" != 1 ] && kc -n "$NS" delete testrun "$name" --ignore-not-found >/dev/null 2>&1 || true
    [ "$secret_made" = 1 ] && kc -n "$NS" delete secret "$SESSION_SECRET" --ignore-not-found >/dev/null 2>&1 || true
  }
  on_interrupt() {
    echo; warn "Ctrl+C: 시험을 멈추고 지웁니다."
    keep=0; cleanup; exit 130
  }
  trap on_interrupt INT TERM

  if [ "$session" = 1 ]; then
    local cookie
    read -r -s -p "시험 계정 SESSION 쿠키 값(화면에 안 보임): " cookie; echo
    [ -n "$cookie" ] || die "쿠키 값이 비었습니다."
    kc -n "$NS" delete secret "$SESSION_SECRET" --ignore-not-found >/dev/null
    kc -n "$NS" create secret generic "$SESSION_SECRET" --from-literal=SESSION="$cookie" >/dev/null
    unset cookie; secret_made=1
  fi

  log "3. 진행"
  local start; start=$(date +%s)
  name=$(kc create -f - -o jsonpath='{.metadata.name}' <<<"$manifest")
  echo "만듦: $name   (대시보드 '시험' 에서 이 이름을 고른다. 멈추려면 Ctrl+C)"
  local stage prev="" waited limit=$((est + job_timeout + 300))
  while :; do
    stage=$(kc -n "$NS" get testrun "$name" -o jsonpath='{.status.stage}' 2>/dev/null || echo "")
    waited=$(( $(date +%s) - start ))
    if [ "$stage" != "$prev" ]; then printf '  %3d초  %s\n' "$waited" "${stage:-대기}"; prev=$stage; fi
    case "$stage" in
      finished) break ;;
      error)
        echo; warn "시험이 실패했습니다(error). 원인:"
        kc -n "$NS" get pods -l "k6_cr=$name" --no-headers 2>/dev/null | sed 's/^/  /'
        kc -n "$NS" logs -l "k6_cr=$name" --all-containers --tail=15 2>/dev/null | grep -iE 'error|level=' | tail -8 | sed 's/^/  /'
        cleanup; die "initializer·runner 로그를 확인하세요(docs/부하-시험-실행.md 문제 해결)." ;;
    esac
    # 시작 전 단계에서 오래 멈춰 있으면 quota 에 막혔는지 본다(시험은 한 번에 하나).
    if [ "$stage" != started ] && [ "$waited" -gt 120 ]; then
      if kc -n "$NS" get events --field-selector reason=FailedCreate -o jsonpath='{.items[*].message}' 2>/dev/null | grep -q 'exceeded quota'; then
        cleanup; die "quota 에 막혔습니다(exceeded quota). 다른 시험이 돌고 있지 않은지 'status' 로 확인하세요."
      fi
    fi
    [ "$waited" -le "$limit" ] || { cleanup; die "예상 시간보다 5분 넘게 끝나지 않아 멈췄습니다."; }
    sleep 10
  done
  local end; end=$(date +%s)

  log "4. k6 요약"
  kc -n "$NS" logs -l "k6_cr=$name,runner=true" --tail=45 2>/dev/null || warn "runner 로그를 읽지 못했습니다."

  log "5. 결과 (Grafana)"
  local dash=$DASHBOARD_UID; [ "$ai" = 1 ] && dash=nerdnam-ai
  echo "$GRAFANA/d/$dash?var-testrun=$name&from=$(( (start - 60) * 1000 ))&to=$(( (end + 60) * 1000 ))"
  echo "읽는 법: docs/부하-시험-실행.md 4절. BE 패널은 30초 늦게 따라온다."

  trap - INT TERM
  cleanup
  [ "$keep" = 1 ] && echo "TestRun $name 을 남겼습니다(정리: scripts/load-test.sh stop)." || echo "정리 완료. 지표는 Prometheus 에 7일 남습니다."
}

cmd_status() {
  echo "== 시험"; kc -n "$NS" get testrun 2>&1
  echo; echo "== Pod"; kc -n "$NS" get pods 2>&1
  echo; echo "== quota (Used / Hard). requests.cpu 는 시험 하나만 들어가게 잡혀 있다"
  kc -n "$NS" describe resourcequota | sed -n '/^Resource/,$p'
}

cmd_logs() {
  local name="${1:-}"
  [ -n "$name" ] || name=$(kc -n "$NS" get testrun --sort-by=.metadata.creationTimestamp -o jsonpath='{.items[-1:].metadata.name}' 2>/dev/null)
  [ -n "$name" ] || die "시험이 없습니다(끝난 시험은 run 이 지운다. 남기려면 --keep)."
  kc -n "$NS" logs -l "k6_cr=$name,runner=true" --tail=60
}

cmd_stop() {
  local runs; runs=$(kc -n "$NS" get testrun -o name 2>/dev/null || true)
  if [ -z "$runs" ]; then echo "도는 시험이 없습니다."; else kc -n "$NS" delete $runs; fi
  kc -n "$NS" delete secret "$SESSION_SECRET" --ignore-not-found
}

ACTION="${1:-}"; shift || true
case "$ACTION" in
  run) cmd_run "$@" ;;
  status) cmd_status ;;
  logs) cmd_logs "$@" ;;
  stop) cmd_stop ;;
  *) usage ;;
esac
