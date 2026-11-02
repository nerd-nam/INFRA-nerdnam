# Terraform CI (GitHub Actions + 사람 승인)

기준일: 2026-11-02. Terraform **root(AWS)** 를 GitHub Actions 에서 plan·apply 한다. 적용 전에 반드시 사람이 승인한다. "적용된 것 = main 에 있는 것"이 되고, 누가 언제 무엇을 승인·적용했는지 Actions 기록에 남는다.

## 1. 흐름

```text
PR 열기/고치기
  └─ check : fmt · validate · terraform test (root·bootstrap, mock — AWS 호출 없음)
  └─ plan  : 읽기 전용 역할로 plan → PR 에 변경 요약 코멘트(값 없이 주소·속성 이름)

PR merge → main
  └─ check
  └─ plan  : 읽기 전용 역할. 변경이 없으면 여기서 끝
  └─ ⏸ 승인 대기 : Environment "dev-infra" 의 Required reviewers 가 Actions 화면에서 Approve
  └─ apply : 쓰기 역할. 다시 plan 을 만들어 **승인한 요약과 같을 때만** 적용 → 남은 변경 없는지 확인
```

- 수동 실행: Actions → terraform → Run workflow(main). 관리 IP·입력값만 바꿨을 때(코드 변경 없음) 쓴다.
- 승인 화면에서 볼 것: 같은 실행의 **plan** 작업 요약(Summary). 삭제·교체가 있으면 경고가 맨 위에 뜬다.
- 승인 뒤 apply 가 다시 만든 plan 이 다르면(그사이 누가 로컬에서 적용했거나 노드 수가 바뀜) 적용하지 않고 실패한다. 다시 실행해 새 plan 을 승인한다.
- apply 는 한 번에 하나만 돈다(concurrency).
- 노드 수는 지금 값을 그대로 넘긴다. 노드 켜고 끄기는 여전히 `scripts/cluster.sh` 가 한다.

## 2. 역할과 보안

| 역할 | 받을 수 있는 작업(OIDC sub) | 권한 |
| --- | --- | --- |
| `nerdnam-dev-tf-plan` | 이 저장소의 `pull_request`, `ref:refs/heads/main` | AWS `ReadOnlyAccess` + **데이터 읽기 차단**(state 말고 S3 객체, CloudWatch 로그, SSM 파라미터, Secret 값, KMS 복호화, ECR 이미지, DynamoDB 항목 등) |
| `nerdnam-dev-tf-apply` | 이 저장소의 `environment:dev-infra` **만** | Terraform 실행자와 같은 고객 관리형 정책 7개(state·network·EKS·platform·workload·observability·CI) |

- **공개 저장소**라 Actions 로그·PR 코멘트를 누구나 본다. plan·apply 출력은 버리고 요약(동작·주소·바뀌는 속성 이름)만 낸다. 관리 IP·ARN 같은 값은 로그에 나오지 않는다. 오류 메시지에는 값이 섞일 수 있다.
- plan 역할에 데이터 읽기 차단을 둔 이유: 쓰기 권한이 있는 사람이 PR 에서 workflow 를 바꿔 plan 역할로 Loki 로그 S3 등을 읽어 공개 로그에 출력하는 것을 막는다.
- fork PR 은 OIDC 토큰이 없어 plan 을 건너뛴다(검사만).
- apply 역할의 trust 가 Environment 이름에 묶여 있어, 승인 없는 작업(브랜치·PR)은 apply 역할을 받을 수 없다. Environment 에는 main 브랜치만 배포 가능하도록 건다.
- 입력값(`eks.dev.tfvars`: 관리자 ARN·관리 IP·zone ID·add-on 버전)은 저장소 secret `EKS_DEV_TFVARS` 에 **base64 한 줄**로 둔다(로그에서 가려진다. 여러 줄로 넣으면 줄마다 가려져 로그의 `}` 등이 `***` 로 바뀐다).
- apply 역할은 자기 자신(trust 포함)을 바꿀 수 있다. 그 변경도 PR 리뷰와 승인을 거친다.

## 3. 처음 한 번 준비 (순서대로)

1. **IAM 정책**(IAM 관리자): `iam/policies/nerdnam-terraform-ci-dev.json` 으로 고객 관리형 정책 `NerdnamTerraformCiDev` 를 만들고 `nerdnam-infra` 그룹에 연결한다. CI 역할 2개를 만들고, plan 역할에는 ReadOnlyAccess 만, apply 역할에는 실행자 정책 7개만 붙일 수 있는 권한이다.
2. 이 PR 을 main 에 merge. 아직 역할이 없어 CI 는 check 만 돌고 plan 은 건너뛴다.
3. 로컬에서 역할 생성: `scripts/tf-apply.sh root` (11개 생성: 역할 2, inline 정책 1, 정책 연결 8).
4. GitHub 설정:
   ```sh
   base64 < eks.dev.tfvars | tr -d '\n' | gh secret set EKS_DEV_TFVARS --repo nerd-nam/INFRA-nerdnam   # 한 줄(base64)
   gh variable set TF_PLAN_ROLE_ARN  --repo nerd-nam/INFRA-nerdnam --body "$(terraform output -json terraform_ci | jq -r .plan_role_arn)"
   gh variable set TF_APPLY_ROLE_ARN --repo nerd-nam/INFRA-nerdnam --body "$(terraform output -json terraform_ci | jq -r .apply_role_arn)"
   ```
   Environment `dev-infra`: Settings → Environments → New environment
   - **Required reviewers**: 승인할 사람(최대 6명). 혼자 운영하면 자기 승인을 막지 않는다("Prevent self-review" 끔).
   - **Deployment branches and tags**: Selected → `main`
5. 확인: Actions → terraform → Run workflow(main) → plan "변경 없음" → apply 작업이 생기지 않으면 정상.

## 4. 평소

| 하고 싶은 일 | 방법 |
| --- | --- |
| AWS 리소스 변경(코드) | PR → plan 요약 리뷰 → merge → Actions 에서 승인 |
| 관리 IP 변경 | 로컬 `eks.dev.tfvars` 수정 → `base64 < eks.dev.tfvars \| tr -d '\n' \| gh secret set EKS_DEV_TFVARS --repo nerd-nam/INFRA-nerdnam` → Run workflow → 승인. 이어서 로컬 `scripts/tf-apply.sh bootstrap` → `scripts/argo-sync.sh nerdnam-foundation` |
| 노드 켜고 끄기 | `scripts/cluster.sh up\|down` (CI 와 무관) |
| 급할 때 로컬 적용 | `scripts/tf-apply.sh root` (main = origin/main 일 때만). 로컬 `eks.dev.tfvars` 와 secret 이 같아야 CI plan 이 이어서 "변경 없음"이 된다 |
| bootstrap(Argo CD·seed) | 로컬 `scripts/tf-apply.sh bootstrap`. EKS API 가 관리 IP 에서만 열려 있어 CI 실행기는 닿지 않는다 |

## 5. 남은 일

- plan 역할은 ReadOnlyAccess 에 차단 목록을 더한 방식이라 최소 권한이 아니다. 실제 plan 에 필요한 조회만 남기는 정책으로 줄이는 것이 다음 단계다.
- bootstrap 을 CI 로 옮기려면 클러스터에 닿는 실행기(VPC 안 self-hosted runner 등)가 필요하다.
- `eks.dev.tfvars` 는 로컬 파일과 secret 두 곳에 있다. 한쪽만 고치면 plan 에 차이가 나온다.
