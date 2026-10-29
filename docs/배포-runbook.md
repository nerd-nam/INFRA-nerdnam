# 배포 runbook (dev 첫 배포)

기준일: 2026-10-29. 단계별 문서(EKS·GitOps·데이터·앱·관측·추적)에 흩어진 배포 절차를 한 순서로 모았다. **모든 apply·sync는 사용자가 직접 실행한다.** 이 문서는 아직 실제로 실행해 본 적이 없다. 처음 실행할 때 명령·출력이 다르면 이 문서를 고친다.

각 단계는 "실행 → 확인 → 실패하면"으로 적었다. 확인이 통과하지 않으면 다음 단계로 가지 않는다.

## 0. 준비물

| 무엇 | 어디에 | 비고 |
| --- | --- | --- |
| 관리자 IAM ARN(영속 user/role), 공인 IPv4 CIDR | `eks.dev.tfvars`(git ignore) | STS 세션 ARN 금지, 예시 CIDR 금지 |
| Route53 hosted zone ID | `eks.dev.tfvars` `route53_zone_id` | |
| add-on 버전 | `eks.dev.tfvars` `eks_addon_versions` | 권한이 생긴 뒤 서울 호환 버전 조회해 고정 |
| 실행자 IAM 정책 7개 생성·연결 | IAM 콘솔 | [iam/README.md](../iam/README.md). state·network·EKS·platform·workload·observability·bootstrap state |
| GitHub OIDC provider 존재 여부 | IAM | 있으면 `terraform import module.workload.aws_iam_openid_connect_provider.github <ARN>` |
| 배포 Git revision | bootstrap `git_revision` | **원격에 push된 commit**이어야 Argo가 읽는다 |
| 서비스·샘플 도메인, ACME 이메일 | bootstrap `app_hostname`, `sample_hostname`, `acme_email`, `acme_server` | 처음엔 staging ACME로 확인 후 production |
| private Git 자격 증명 | Argo CD repository secret | ESO보다 먼저 필요. Git·state에 넣지 않는다 |
| Secret JSON 4개 | Secrets Manager (1단계 이후) | 아래 3절 |
| 이미지 digest 3개 | `gitops/apps/images.yaml` PR | 앱 CI 실행 요약에서 복사(팀 결정) |
| OAuth redirect URI 등록 | Google·Kakao 콘솔 | `https://<app_hostname>/login/oauth2/code/{google,kakao}` |
| 알림 수신 채널 | 미정 | 정해질 때까지 Alertmanager UI만 |

## 1. AWS 루트 (VPC·EKS·platform·workload·observability)

```sh
unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
export AWS_PROFILE=nerdnam-infra
terraform init -input=false -lockfile=readonly
terraform plan -input=false -var-file=eks.dev.tfvars -out=dev.plan    # 검토
terraform apply dev.plan
```

확인:

```sh
aws eks update-kubeconfig --name nerdnam-dev --region ap-northeast-2
kubectl get nodes -L workload,topology.kubernetes.io/zone     # 3대 Ready, app=2a, platform·data=2c
kubectl -n kube-system get pods                               # aws-node·kube-proxy·coredns·ebs-csi·pod-identity-agent Running
kubectl describe node -l workload=data | grep -A6 Allocatable # 운영-검증 문서 1절의 추정값과 비교
terraform output -json workload | jq .ci_role_arns            # 앱 저장소 변수에 넣을 값
terraform output -json observability                          # loki/tempo bucket 이름
```

실패하면: plan의 `eks:DescribeAddonVersions` 등 AccessDenied는 실행자 정책 문제다. 노드가 NotReady면 CNI·subnet route를 본다. 지운 뒤 다시 하려면 `terraform destroy`(데이터 PVC가 없을 때만).

## 2. 앱 저장소 CI 변수 (이미지 만들기)

| 저장소 | 저장소 변수 | 값 |
| --- | --- | --- |
| FE | `AWS_ROLE_ARN` | `ci_role_arns.web` |
| BE | `AWS_CI_ROLE_ARN_API` | `ci_role_arns.api` |
| AI | `AWS_CI_ROLE_ARN` | `ci_role_arns.ai` |

각 저장소 main에서 workflow를 다시 돌리고(`workflow_dispatch`), 실행 요약의 digest 3개를 받아 둔다. 확인: `aws ecr describe-images --repository-name nerdnam-dev/api`.

## 3. Secrets Manager 값 (Terraform 밖)

메타데이터는 1단계에서 생겼다. 값만 넣는다(콘솔 또는 `aws secretsmanager put-secret-value`, 셸 기록에 남지 않게 파일·stdin으로). 32자 이상 무작위 값.

| Secret | JSON 키 |
| --- | --- |
| `nerdnam/dev/backend` | `GOOGLE_CLIENT_ID`, `GOOGLE_CLIENT_SECRET`, `KAKAO_CLIENT_ID`, `KAKAO_CLIENT_SECRET` (DB·Redis 비밀번호는 넣지 않는다) |
| `nerdnam/dev/data` | `postgres-superuser-password`, `postgres-migrator-password`, `postgres-app-password`, `redis-api-password`, `postgres-exporter-password`, `redis-exporter-password` |
| `nerdnam/dev/ai` | (현재 비어 있어도 된다. AI는 Pod Identity로 Bedrock 호출) |
| `nerdnam/dev/monitoring` | `grafana-admin-user`, `grafana-admin-password` |

**DB 비밀번호는 PostgreSQL 첫 초기화 때만 쓰인다.** 2절 이후 바꾸려면 데이터 문서 4절의 회전 절차를 따른다.

## 4. bootstrap (Argo CD·seed)

```sh
cd bootstrap
terraform init -input=false -lockfile=readonly
terraform plan -input=false -var git_revision=<commit> -var app_hostname=<도메인> -var sample_hostname=<샘플 도메인> \
  -var acme_email=<메일> -out=bootstrap.plan
terraform apply bootstrap.plan
kubectl -n argocd get applications          # root 와 자식 Application 이 보인다. 모두 OutOfSync(수동 sync)
```

Argo UI: `kubectl -n argocd port-forward svc/argocd-server 8080:443`. 초기 비밀번호는 `argocd-initial-admin-secret`(로그인 후 바꾸고 Secret 삭제).

## 5. Argo 수동 sync 순서

한 번에 하나씩 sync하고 확인한다. CRD·webhook이 준비되기 전에 그 CR을 쓰는 Application을 sync하지 않는다.

| 순서 | Application | 확인 |
| --- | --- | --- |
| 1 | `aws-load-balancer-controller`, `cert-manager`, `external-secrets` | `kubectl get pods -A -l app.kubernetes.io/instance in (...)` Ready, webhook Service endpoint 있음 |
| 2 | `traefik` | NLB 생성(`kubectl -n traefik get svc` EXTERNAL-IP), 대상 그룹 healthy |
| 3 | `nerdnam-foundation` | StorageClass `gp3-retain`, ClusterIssuer Ready, ClusterSecretStore `Valid`, namespace 3개 + NetworkPolicy |
| 4 | `nerdnam-secrets` | `kubectl get externalsecret -A` 모두 `SecretSynced` |
| 5 | `nerdnam-sample` | 샘플 도메인 DNS → NLB, 인증서 Ready, `curl https://<샘플>` 200 (HTTPS·ESO·Ingress 경로 확인용) |
| 6 | `kube-prometheus-stack` | CRD 생성, operator·Prometheus·Alertmanager·Grafana Ready, PVC Bound(gp3-retain) |
| 7 | `loki` → `tempo` → `alloy` | Loki·Tempo `/ready`, Pod Identity로 S3 접근(로그에 AccessDenied 없음), Alloy Ready |
| 8 | `nerdnam-data` | postgres-0·redis-0 Ready, PVC Bound, exporter 2개 Ready. 아래 데이터 확인 |
| 9 | `images.yaml` digest PR merge → `nerdnam-apps` | web·api·ai Ready. BE 첫 기동 때 Flyway V1~V8 |
| 10 | `nerdnam-observability` | Prometheus targets(api·postgres-exporter·redis-exporter·loki·tempo·alloy) up, 대시보드 2개 보임 |

데이터 확인(8):

```sh
kubectl -n data exec postgres-0 -- psql -U postgres -d nerdnam -c '\dx'        # vector, pg_trgm
kubectl -n data exec postgres-0 -- psql -U postgres -c '\du'                   # nerdnam_migrator·app·exporter
kubectl -n data exec redis-0 -- redis-cli --user api ping                       # PONG (컨테이너의 REDISCLI_AUTH 사용)
```

앱 확인(9):

```sh
kubectl -n nerdnam logs deploy/api | grep -i flyway                            # 처음엔 V1~V8 적용 로그
kubectl -n nerdnam exec deploy/api -- curl -s localhost:8081/actuator/health/readiness
```

DNS: `app_hostname`의 A(alias) 레코드를 NLB로 만든다(자동 생성 없음). 인증서 Ready 확인 → OAuth redirect URI 등록 → 브라우저 로그인.

## 6. 첫 배포 뒤 확인 (서비스)

1. 로그인(Google·Kakao) → 라이브러리 화면.
2. 이력서·공고 등록 → 분석 1건 → 리포트 → 가이드 탭 5개. **Bedrock 요금이 든다.** 소량만.
3. Grafana(`kubectl -n monitoring port-forward svc/grafana 3000:80`):
   - `nerdnam 서비스`: 요청 수·응답 시간·AI 작업 진행이 움직인다.
   - Explore → Tempo: `service.name=api` trace, 그 안의 `nerdnam.ai.job` span.
   - Explore → Loki `{namespace="nerdnam", app="api"}`: JSON 줄의 `trace_id`를 눌러 Tempo로 이동.
4. Alertmanager(`port-forward svc/monitoring-alertmanager 9093`): 기본 규칙 외에 울리는 것이 없는지(Watchdog만).

## 7. 되돌리기

| 상황 | 방법 |
| --- | --- |
| 앱 이미지 문제 | `images.yaml`을 이전 digest로 되돌리는 PR → `nerdnam-apps` sync. DB schema는 되돌아가지 않는다 |
| 설정(차트) 문제 | Git revert → 해당 Application sync. 자동 prune이 없어 지운 리소스는 남는다(직접 확인 후 삭제) |
| controller upgrade 문제 | `root/values.yaml`·`charts.lock.json`의 이전 버전으로 revert |
| 데이터 | **백업이 아직 없다**(보류). PVC·StatefulSet 삭제, 파괴적 migration을 하지 않는다. PVC는 Retain이라 Application을 지워도 남는다 |
| 전체 철거 | Application 삭제 → bootstrap destroy → 루트 destroy. EBS(Retain PV)와 S3 bucket(Loki·Tempo)은 수동 삭제 대상으로 남는다 |

## 8. 이후 배포 (앱 업데이트)

1. 앱 저장소 main merge → CI가 ECR push → 실행 요약 digest.
2. BE를 바꿀 때만: AI 작업 비우기(앱-배포 문서 8절, `POST /actuator/aijob {"state":"drain"}` → `drained:true`). drain 중에도 다른 API는 동작한다(BE #52).
3. `images.yaml` PR merge → `nerdnam-apps` sync. BE는 Recreate라 기동까지(수십 초) 중단된다.
4. 대시보드에서 5xx·응답 시간·AI 작업 실패를 배포 전후로 비교한다.
