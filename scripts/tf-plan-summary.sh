#!/usr/bin/env bash
# Terraform plan 파일을 "무엇이 어떻게 바뀌는지"만 한 줄씩 요약한다. 값은 내지 않는다(공개 저장소 Actions 로그·PR 코멘트에 쓴다).
#
#   scripts/tf-plan-summary.sh <plan 파일>      (그 plan 을 만든 Terraform 디렉터리에서 실행)
#
# 출력 형식(탭 구분):  <create|update|delete|replace>  <주소>  [바뀌는 속성 이름 목록]
# 마지막 줄에 output 변경 이름. 변경이 없으면 아무것도 출력하지 않는다.
set -euo pipefail
[ $# -eq 1 ] || { echo "사용법: $0 <plan 파일>" >&2; exit 2; }

terraform show -json "$1" | jq -r '
  def changed_keys:
    (.change.before // {}) as $b | (.change.after // {}) as $a | (.change.after_unknown // {}) as $u
    | ([$a, $b] | map(if type == "object" then keys else [] end) | add | unique)
    | map(select(($b[.] != $a[.]) or ($u[.] != null and $u[.] != false)));
  ( .resource_changes[]
    | select(.change.actions != ["no-op"] and .change.actions != ["read"])
    | (if (.change.actions | index("delete")) and (.change.actions | index("create")) then "replace"
       else .change.actions[0] end) as $act
    | [$act, .address,
       (if $act == "update" then (changed_keys | join(", "))
        elif $act == "replace" then ([.change.replace_paths[]? | map(tostring) | join(".")] | join(", "))
        else "" end)]
    | @tsv ),
  ( [.output_changes // {} | to_entries[] | select(.value.actions != ["no-op"]) | .key]
    | select(length > 0) | "output\t" + join(", ") )'
