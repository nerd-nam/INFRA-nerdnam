#!/usr/bin/env bash
# dev 인프라 노드 내리기·올리기. EKS·VPC·NAT·NLB·디스크는 그대로 두고 노드 그룹 3개만 0 ↔ 1 로 바꾼다.
#
#   scripts/cluster.sh down [-y]   # 노드 3대 끄기(하루 약 20달러 → 약 5달러)
#   scripts/cluster.sh up   [-y]   # 노드 3대 켜고 서비스가 열릴 때까지 확인
#   scripts/cluster.sh status      # 노드·EC2·서비스 상태만 본다
#
# -y 를 주지 않으면 terraform apply 전에 한 번 묻는다.
# plan 에 노드 그룹 변경 말고 다른 것이 있으면 apply 하지 않고 멈춘다.
set -euo pipefail

cd "$(dirname "$0")/.."

export AWS_PROFILE="${AWS_PROFILE:-nerdnam-infra}"
unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN TF_DATA_DIR

REGION=ap-northeast-2
CLUSTER=nerdnam-dev
CTX=nerdnam-dev
URL=https://nerdnam.click/
VARS=eks.dev.tfvars

kc() { kubectl --context "$CTX" "$@"; }
log() { printf '\n\033[1m== %s\033[0m\n' "$*"; }
die() { printf '\n\033[31m중단: %s\033[0m\n' "$*" >&2; exit 1; }
elapsed() { echo "$(( $(date +%s) - T0 ))초"; }

usage() { sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }

ACTION="${1:-}"; shift || true
YES=0
for a in "$@"; do
  case "$a" in -y|--yes) YES=1 ;; *) usage ;; esac
done

# 관리 IP 가 EKS API 허용 목록에 있는지. 없으면 kubectl·helm 이 timeout 으로 끊긴다.
check_ip() {
  local ip allowed
  ip=$(curl -fsS -4 --max-time 10 https://checkip.amazonaws.com | tr -d '[:space:]')
  allowed=$(aws eks describe-cluster --region "$REGION" --name "$CLUSTER" \
    --query 'cluster.resourcesVpcConfig.publicAccessCidrs' --output text)
  if ! tr '\t' '\n' <<<"$allowed" | grep -qx "$ip/32"; then
    die "지금 IP $ip 가 EKS API 허용 목록($allowed)에 없습니다.
  $VARS 의 eks_public_access_cidrs 에 \"$ip/32\" 를 넣고 아래를 먼저 실행하세요(내려 둔 상태면 -var eks_node_count=0 필수).
    scripts/tf-apply.sh root        (지금 노드 수를 그대로 유지한다)"
  fi
  echo "관리 IP $ip: 허용 목록 안"
}

running_instances() {
  aws ec2 describe-instances --region "$REGION" \
    --filters "Name=tag:eks:cluster-name,Values=$CLUSTER" \
              "Name=instance-state-name,Values=pending,running,stopping,shutting-down" \
    --query 'length(Reservations[].Instances[])' --output text
}

# 노드 수 N 으로 plan 을 만들고, 노드 그룹 3개 in-place 변경만 있는지 검사한다.
# 출력: 변경 개수(0 이면 이미 그 상태). plan 파일은 $PLAN 에 남는다.
PLAN=$(mktemp -t nerdnam-cluster)
trap 'rm -f "$PLAN"' EXIT
make_plan() {
  local n=$1
  terraform plan -input=false -no-color -var-file="$VARS" -var "eks_node_count=$n" -out="$PLAN" >/dev/null
  terraform show -json "$PLAN" | jq -r '
    [.resource_changes[] | select(.change.actions != ["no-op"] and .change.actions != ["read"])] as $c
    | if ($c | all(.type == "aws_eks_node_group" and .change.actions == ["update"]))
      then ($c | length | tostring)
      else "BAD\n" + ($c | map("  " + .address + " " + (.change.actions | join(","))) | join("\n"))
      end'
}

confirm() {
  [ "$YES" = 1 ] && return 0
  read -r -p "$1 [y/N] " ans
  [[ "$ans" =~ ^[yY]$ ]] || die "취소했습니다."
}

do_down() {
  T0=$(date +%s)
  log "1/5 확인"
  check_ip
  if [ "$(running_instances)" = 0 ]; then echo "이미 내려가 있습니다(EC2 0)."; exit 0; fi
  kc get nodes -L workload

  # 진행 중인 AI 작업이 있으면 내리지 않는다. 끝난 뒤 다시 실행한다.
  if kc -n nerdnam get deploy/api >/dev/null 2>&1; then
    local job
    job=$(kc -n nerdnam exec deploy/api -- curl -fsS --max-time 10 localhost:8081/actuator/aijob 2>/dev/null || echo '')
    echo "AI 작업: ${job:-조회 실패}"
    if [ -n "$job" ] && [ "$(jq -r '(.active // 0) + (.inFlight // 0) + (.queued // 0)' <<<"$job")" != 0 ]; then
      die "진행 중이거나 대기 중인 AI 작업이 있습니다. 끝난 뒤 다시 실행하세요."
    fi
  fi

  log "2/5 plan (노드 0)"
  local r; r=$(make_plan 0)
  [[ "$r" == BAD* ]] && die "plan 에 노드 그룹 말고 다른 변경이 있습니다. apply 하지 않습니다.
${r#BAD}"
  [ "$r" = 0 ] && { echo "Terraform 상 이미 노드 0 입니다."; exit 0; }
  echo "노드 그룹 ${r}개 변경만 있습니다."
  confirm "노드 3대를 내립니다. 서비스가 멈춥니다. 진행할까요?"

  log "3/5 data 노드 비우기 (PostgreSQL·Redis 정상 종료)"
  kc drain -l workload=data --ignore-daemonsets --delete-emptydir-data --timeout=5m

  log "4/5 app·platform 노드 비우기 (PDB 대기 없이)"
  # 다 내리는 중이라 coredns·ebs-csi-controller PDB 를 기다리지 않는다. 기다리면 AWS 가 노드마다 15분 대기한다.
  kc drain -l 'workload in (app,platform)' --ignore-daemonsets --delete-emptydir-data --disable-eviction --timeout=2m

  log "5/5 apply"
  terraform apply -input=false -no-color "$PLAN" | tail -n 3
  printf 'EC2 종료 기다리는 중'
  local t=0
  until [ "$(running_instances)" = 0 ]; do
    t=$((t + 15)); [ $t -gt 1500 ] && die "25분이 지나도 EC2 가 남아 있습니다. AWS 콘솔에서 노드 그룹 상태를 보세요."
    printf '.'; sleep 15
  done
  echo
  echo "EC2 0 ($(elapsed))"
  echo "남은 데이터 디스크:"
  aws ec2 describe-volumes --region "$REGION" \
    --filters Name=tag-key,Values=kubernetes.io/created-for/pvc/name \
    --query 'Volumes[].[Tags[?Key==`kubernetes.io/created-for/pvc/name`]|[0].Value,VolumeId,Size,State]' --output table
  log "내리기 완료 ($(elapsed))"
}

do_up() {
  T0=$(date +%s)
  log "1/4 확인"
  check_ip

  log "2/4 plan (노드 1)"
  local r; r=$(make_plan 1)
  [[ "$r" == BAD* ]] && die "plan 에 노드 그룹 말고 다른 변경이 있습니다. apply 하지 않습니다.
${r#BAD}"
  if [ "$r" = 0 ]; then
    echo "Terraform 상 이미 노드 1 입니다. 상태만 확인합니다."
  else
    echo "노드 그룹 ${r}개 변경만 있습니다."
    confirm "노드 3대를 올립니다(하루 약 20달러). 진행할까요?"
    log "3/4 apply"
    terraform apply -input=false -no-color "$PLAN" | tail -n 3
  fi

  log "4/4 서비스가 열릴 때까지 기다림 (보통 2분)"
  local t=0 ready
  until ready=$(kc get nodes --no-headers 2>/dev/null | awk '$2=="Ready"' | wc -l | tr -d ' ') && [ "$ready" -ge 3 ]; do
    t=$((t + 10)); [ $t -gt 600 ] && die "10분이 지나도 노드 3대가 Ready 가 아닙니다."
    sleep 10
  done
  echo "노드 3대 Ready ($(elapsed))"
  t=0
  until [ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$URL")" = 200 ]; do
    t=$((t + 10)); [ $t -gt 600 ] && die "10분이 지나도 $URL 가 200 이 아닙니다."
    sleep 10
  done
  echo "$URL 200 ($(elapsed))"
  t=0
  local notready
  # Running 이면서 컨테이너가 다 준비된 Pod, 또는 Completed 만 정상으로 본다.
  until notready=$(kc get pods -A --no-headers | awk '{split($3,r,"/")} !($4=="Completed" || ($4=="Running" && r[1]==r[2]))') && [ -z "$notready" ]; do
    t=$((t + 10)); [ $t -gt 600 ] && { echo "$notready"; die "10분이 지나도 Running 이 아닌 Pod 가 있습니다."; }
    sleep 10
  done
  echo "모든 Pod Running ($(elapsed))"

  echo
  kc get nodes -o 'custom-columns=NODE:.metadata.name,WORKLOAD:.metadata.labels.workload,ZONE:.metadata.labels.topology\.kubernetes\.io/zone,INTERNAL-IP:.status.addresses[?(@.type=="InternalIP")].address,EXTERNAL-IP:.status.addresses[?(@.type=="ExternalIP")].address'
  local pub
  pub=$(aws ec2 describe-instances --region "$REGION" \
    --filters "Name=tag:eks:cluster-name,Values=$CLUSTER" Name=instance-state-name,Values=running \
    --query 'Reservations[].Instances[?PublicIpAddress!=`null`].InstanceId' --output text)
  [ -z "$pub" ] && echo "노드 공인 IP: 없음" || echo "경고: 공인 IP 가 있는 노드: $pub"
  # LB·Ingress 상태가 늦게 반영돼 Argo 가 Progressing 에 머무는 일이 있다. 30초 뒤에도 그러면 refresh 를 요청한다(배포는 바뀌지 않음).
  t=0
  local apps
  until apps=$(kc -n argocd get applications --no-headers | awk '!($2=="Synced" && $3=="Healthy"){print $1}') && [ -z "$apps" ]; do
    t=$((t + 10)); [ $t -gt 300 ] && { echo "경고: 5분이 지나도 Synced·Healthy 가 아닌 Argo 앱: $apps"; break; }
    if [ $t = 30 ]; then
      for a in $apps; do kc -n argocd annotate application "$a" argocd.argoproj.io/refresh=normal --overwrite >/dev/null; done
    fi
    sleep 10
  done
  echo
  kc -n argocd get applications --no-headers | awk '{printf "%-28s %-10s %s\n", $1, $2, $3}'
  echo
  echo "BE readiness: $(kc -n nerdnam exec deploy/api -- curl -fsS --max-time 10 localhost:8081/actuator/health/readiness 2>/dev/null || echo 조회 실패)"
  log "올리기 완료 ($(elapsed))"
}

do_status() {
  echo "실행 중 EC2: $(running_instances)"
  kc get nodes -L workload 2>/dev/null || echo "(노드 없음 또는 클러스터 접속 불가)"
  echo "$URL → $(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$URL")"
}

case "$ACTION" in
  down) do_down ;;
  up) do_up ;;
  status) do_status ;;
  *) usage ;;
esac
