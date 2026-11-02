#!/usr/bin/env bash
# Terraform root·bootstrap 을 안전하게 적용한다. "적용되는 것 = origin/main 에 있는 것"을 보장한다.
#
#   scripts/tf-apply.sh root      [--plan-only] [-y]   # VPC·EKS·IAM 등 AWS (eks.dev.tfvars)
#   scripts/tf-apply.sh bootstrap [--plan-only] [-y]   # Argo CD·seed (bootstrap/dev.tfvars)
#
# 막는 것:
#   - main 이 아닌 브랜치, origin/main 보다 뒤처지거나 앞선 상태, commit 안 한 Terraform·GitOps 파일에서 적용
#   - root 적용이 노드 수를 바꾸는 것(지금 노드 수를 그대로 넘긴다. 노드 켜고 끄기는 scripts/cluster.sh)
#   - 삭제·교체가 있는 plan 을 확인 없이 적용(직접 문구를 입력해야 한다. -y 로도 넘어가지 않는다)
# 적용 뒤 다시 plan 을 돌려 남은 변경이 없는지 확인한다.
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT_DIR=$(pwd)

export AWS_PROFILE="${AWS_PROFILE:-nerdnam-infra}"
unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN TF_DATA_DIR

REGION=ap-northeast-2
CLUSTER=nerdnam-dev

log() { printf '\n\033[1m== %s\033[0m\n' "$*"; }
warn() { printf '\033[33m%s\033[0m\n' "$*"; }
die() { printf '\n\033[31m중단: %s\033[0m\n' "$*" >&2; exit 1; }
usage() { sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }

TARGET="${1:-}"; shift || true
PLAN_ONLY=0; YES=0
for a in "$@"; do
  case "$a" in --plan-only) PLAN_ONLY=1 ;; -y|--yes) YES=1 ;; *) usage ;; esac
done
case "$TARGET" in
  root) DIR="$ROOT_DIR"; VARS=eks.dev.tfvars ;;
  bootstrap) DIR="$ROOT_DIR/bootstrap"; VARS=dev.tfvars ;;
  *) usage ;;
esac

# Terraform 이 읽는 파일. 여기 commit 안 한 변경이 있으면 리뷰·기록 없는 것이 적용된다.
TRACKED_PATHS=(':(glob)*.tf' ':(glob)*.tf.json' '.terraform.lock.hcl' modules bootstrap gitops iam)

check_git() {
  log "1. Git 상태 확인"
  git fetch -q origin main || die "origin/main 을 가져오지 못했습니다(네트워크·권한 확인)."
  local branch head remote dirty
  branch=$(git rev-parse --abbrev-ref HEAD)
  [ "$branch" = main ] || die "지금 브랜치가 '$branch' 입니다. main 에서만 적용합니다(git switch main && git pull)."
  head=$(git rev-parse HEAD); remote=$(git rev-parse origin/main)
  if [ "$head" != "$remote" ]; then
    if git merge-base --is-ancestor HEAD origin/main; then
      die "로컬 main 이 origin/main 보다 뒤처졌습니다. git pull --ff-only 후 다시 실행하세요."
    else
      die "로컬 main 에 origin 에 없는 commit 이 있습니다. PR 로 merge 한 것만 적용합니다."
    fi
  fi
  dirty=$(git status --porcelain --untracked-files=all -- "${TRACKED_PATHS[@]}")
  [ -z "$dirty" ] || die "commit 안 한 Terraform·GitOps 변경이 있습니다:
$dirty"
  echo "main = origin/main = $(git rev-parse --short HEAD), 변경 없음"
}

# root 는 노드 수를 지금 그대로 넘긴다. 기본값(1)으로 내려 둔 노드가 켜지는 것을 막는다.
EXTRA=()
node_count_args() {
  local n
  if ! n=$(aws eks describe-nodegroup --region "$REGION" --cluster-name "$CLUSTER" --nodegroup-name app \
             --query 'nodegroup.scalingConfig.desiredSize' --output text 2>&1); then
    if grep -q ResourceNotFoundException <<<"$n"; then
      echo "노드 그룹이 아직 없습니다(첫 설치). 기본 노드 수(1)로 만듭니다."
      return
    fi
    die "노드 그룹 상태를 읽지 못했습니다: $n"
  fi
  [[ "$n" =~ ^[01]$ ]] || die "예상 밖의 노드 수: $n"
  EXTRA=(-var "eks_node_count=$n")
  echo "지금 노드 수 $n 을 유지합니다(노드 켜고 끄기는 scripts/cluster.sh)."
}

# bootstrap 은 클러스터(Argo CD)에 Helm 으로 설치한다. API 에 닿고 노드가 떠 있어야 한다.
check_cluster() {
  local ip allowed running
  ip=$(curl -fsS -4 --max-time 10 https://checkip.amazonaws.com | tr -d '[:space:]')
  allowed=$(aws eks describe-cluster --region "$REGION" --name "$CLUSTER" \
    --query 'cluster.resourcesVpcConfig.publicAccessCidrs' --output text)
  tr '\t' '\n' <<<"$allowed" | grep -qx "$ip/32" \
    || die "지금 IP $ip 가 EKS API 허용 목록에 없습니다. eks.dev.tfvars 를 고치고 먼저 'scripts/tf-apply.sh root'."
  running=$(aws ec2 describe-instances --region "$REGION" \
    --filters "Name=tag:eks:cluster-name,Values=$CLUSTER" Name=instance-state-name,Values=running \
    --query 'length(Reservations[].Instances[])' --output text)
  [ "$running" -ge 3 ] || die "노드가 떠 있지 않습니다(실행 중 EC2 $running). scripts/cluster.sh up 먼저."
  echo "관리 IP $ip 허용, 노드 $running 대 실행 중"
}

PLAN=$(mktemp -t "nerdnam-$TARGET")
trap 'rm -f "$PLAN"' EXIT

check_git
log "2. 사전 확인"
[ -f "$DIR/$VARS" ] || die "$DIR/$VARS 가 없습니다(git 밖 입력 파일. *.example 참고)."
if [ "$TARGET" = root ]; then node_count_args; else check_cluster; fi

log "3. plan ($TARGET @ $(git rev-parse --short HEAD))"
cd "$DIR"
terraform plan -input=false -no-color -var-file="$VARS" ${EXTRA[@]+"${EXTRA[@]}"} -out="$PLAN" >/dev/null
SUMMARY=$(terraform show -json "$PLAN" | jq -r '
  [.resource_changes[] | select(.change.actions != ["no-op"] and .change.actions != ["read"])]
  | map("  " + (.change.actions | join("+")) + "\t" + .address) | .[]')
OUTPUTS=$(terraform show -json "$PLAN" | jq -r '[.output_changes // {} | to_entries[] | select(.value.actions != ["no-op"]) | .key] | join(", ")')
if [ -z "$SUMMARY" ] && [ -z "$OUTPUTS" ]; then
  echo "변경 없음. 적용할 것이 없습니다."
  exit 0
fi
echo "${SUMMARY:-  (리소스 변경 없음)}"
[ -n "$OUTPUTS" ] && echo "  output 변경: $OUTPUTS"

[ "$PLAN_ONLY" = 1 ] && { echo; echo "--plan-only: 적용하지 않고 끝냅니다."; exit 0; }

if grep -qE '(^|[ +])delete' <<<"$SUMMARY"; then
  echo
  warn "삭제 또는 교체(delete)가 있습니다. 위 목록에서 무엇이 지워지는지 확인하세요."
  read -r -p "정말 적용하려면 'apply-with-delete' 를 입력하세요: " ans
  [ "$ans" = apply-with-delete ] || die "취소했습니다."
elif [ "$YES" != 1 ]; then
  read -r -p "위 변경을 적용할까요? [y/N] " ans
  [[ "$ans" =~ ^[yY]$ ]] || die "취소했습니다."
fi

log "4. apply"
terraform apply -input=false -no-color "$PLAN" | grep -E '^(Apply complete|Error)' || true

log "5. 적용 뒤 남은 변경 확인"
set +e
terraform plan -input=false -no-color -detailed-exitcode -var-file="$VARS" ${EXTRA[@]+"${EXTRA[@]}"} >/dev/null 2>&1
rc=$?
set -e
case $rc in
  0) echo "남은 변경 없음. 적용 완료 ($TARGET @ $(git -C "$ROOT_DIR" rev-parse --short HEAD))" ;;
  2) die "적용 뒤에도 변경이 남아 있습니다. terraform plan 으로 확인하세요." ;;
  *) die "확인용 plan 이 실패했습니다." ;;
esac
