# 4단계: GitOps 기반 코드 작성과 검증

2026-10-28. 실제 AWS·Kubernetes·DNS·Git 원격 저장소에는 변경하지 않았다. 현재는 코드와 오프라인 검증 결과다. EKS가 없어도 다음 단계 코드를 작성한다.

## 관리 범위

| 위치 | 관리 대상 |
| --- | --- |
| Terraform 루트 `modules/platform` | LBC·cert-manager·External Secrets IAM/Pod Identity, backend/data/ai Secret 메타데이터 |
| `bootstrap/` 별도 Terraform 루트 | Argo CD Helm release와 seed chart. state는 `dev/bootstrap.tfstate` |
| `gitops/seed` | AppProject와 Git의 `gitops/root`를 읽는 root Application |
| `gitops/root` | 컨트롤러 4개 및 foundation/secrets/sample Application |
| `gitops/foundation` | namespace·gp3-retain StorageClass·ClusterIssuer·ClusterSecretStore·기본 NetworkPolicy |
| `gitops/secrets` | backend/data/ai ExternalSecret (Secret ARN만 참조) |
| `gitops/sample` | 비권한 whoami Deployment·ClusterIP Service·Certificate·HTTPS Ingress·Traefik 허용 정책 |

Argo CD 자체는 bootstrap이 소유하고 Argo가 자기 Helm release를 동시에 관리하지 않는다. Helm provider가 AWS 리소스 생성과 섞이지 않도록 별도 루트를 유지한다. bootstrap은 기존 AWS state의 EKS endpoint/CA, VPC/subnet, zone/secret ARN outputs를 읽고 `aws eks get-token`으로 인증한다. 비밀값·정적 AWS 키를 Terraform에 넣지 않는다.

## 차트 고정

| 차트 | 차트 버전 | 앱 버전 |
| --- | --- | --- |
| argo-cd | 10.11.6 | v3.5.6 |
| aws-load-balancer-controller | 3.6.2 | v3.6.2 |
| traefik | 42.1.3 | v3.7.16 |
| cert-manager | v1.21.3 | v1.21.3 |
| external-secrets | 2.14.0 | v2.14.0 |

공식 index에서 조회한 URL·SHA256은 `gitops/charts.lock.json`에 기록했다. 검증 스크립트는 다운로드한 패키지의 digest를 확인한다. Argo CD 버전도 이 lock에서 읽는다. 나머지 Application targetRevision은 root values에 고정하며 검증에서 lock과 일치하는지 확인한다. upstream 버전 갱신 시 함께 수정하고 렌더링·실행 검증을 다시 수행한다. 샘플 이미지 `traefik/whoami:v1.11.0`은 시험용 고정 태그이며 실제 앱 릴리스의 digest 고정은 6단계다.

## 배치와 요청 경로

- Argo CD 및 LBC/cert-manager/External Secrets는 platform 선택자와 해당 taint toleration을 사용한다. ApplicationSet·Dex·알림은 현재 사용하지 않고 Argo UI는 ClusterIP만 제공한다. 초기 관리 화면은 인증 후 port-forward로 접근한다.
- Traefik과 샘플은 app 워커에 배치한다. Traefik Service는 `service.k8s.aws/nlb`, internet-facing, IP target, 지정한 public-a subnet을 사용한다. NLB와 관련 SG는 LBC가 생성·관리하며 Terraform에서 같은 NLB를 따로 선언하지 않는다.
- NLB는 TCP 80·443만 전달한다. HTTP는 HTTPS로 리다이렉트하고 TLS는 Traefik에서 종료한다. 인증서는 cert-manager가 Route53 DNS01으로 발급한다. Traefik 관리 포트·Argo UI는 공개하지 않는다.
- 도메인의 실제 A alias/CNAME → NLB DNS 연결은 배포 후 NLB 주소를 확인해 설정해야 한다. DNS01 TXT 인증은 웹 트래픽용 DNS 레코드를 대신하지 않는다. ExternalDNS나 웹 도메인 레코드를 임의로 생성하지 않았다.
- VPC CNI NetworkPolicy 기능을 활성화하는 코드를 추가했다. nerdnam/data namespace는 기본 ingress/egress 차단과 CoreDNS 접근만 허용하고, 샘플에는 Traefik namespace에서 8080으로 들어오는 경로를 허용한다. 5~8단계에서 DB·앱·Bedrock·관측의 실제 경로를 추가한다. CNI의 초기 standard enforcement 창과 실제 동작은 배포 후 검증한다.
- gp3-retain은 암호화·WaitForFirstConsumer·Retain·볼륨 확장을 사용한다. namespace와 StorageClass는 Argo prune/delete에서 보호한다. 아직 업무 PVC나 DB를 생성하지 않는다.

## Secret와 신뢰 경계

- AWS에는 `nerdnam/dev/backend`, `nerdnam/dev/data`, `nerdnam/dev/ai`의 메타데이터만 선언한다. 값이나 버전은 만들지 않으며 후속 앱/DB 계약에 맞춘 JSON 값을 배포 준비 시 별도로 공급한다.
- External Secrets는 controller ServiceAccount의 Pod Identity를 사용하므로 ClusterSecretStore에 정적 키, JWT serviceAccountRef, 별도 AssumeRole을 설정하지 않는다. 접근 가능한 Secret ARN은 세 개로 제한한다.
- ClusterSecretStore 사용 namespace는 nerdnam/data로 제한한다. 동일 controller가 세 Secret을 읽으므로 두 namespace 사이의 완전한 Secret 격리는 아니다. 해당 namespace에서 ExternalSecret을 작성할 수 있는 권한은 신뢰하는 운영자에게만 준다.
- ExternalSecret의 `deletionPolicy: Retain`은 원본 Secret이 사라진 경우의 동작이다. `creationPolicy: Owner`이므로 ExternalSecret 자체를 삭제하면 생성된 Kubernetes Secret도 삭제될 수 있다. 초기에는 자동 prune을 사용하지 않는다.
- private Git 저장소라면 Argo repository credential Secret을 bootstrap 시 별도로 공급해야 한다. 아직 ESO가 배포되지 않은 시점이므로 이 최초 자격 증명을 ESO에 의존시키지 않는다. 자격 증명 원문은 Git·Terraform state에 넣지 않는다.
- platform AppProject는 인프라용 CRD·ClusterRole 등을 만들 수 있는 강한 권한을 갖는다. 지정한 Git 저장소와 공식 chart repository만 허용하지만, 이 프로젝트를 수정할 수 있는 Git 권한 자체가 인프라 관리 권한이다.

## 초기 동기화 설계

root 및 자식 Application은 모두 초기 수동 sync다. 이는 EKS 코드 작성을 막는 활성화 스위치가 아니라 기존 계획의 초기 GitOps 운영 방식이다. 모든 Application은 선언돼 있으며 자동 prune/finalizer로 다른 리소스를 연쇄 삭제하지 않는다. 서로 다른 Application의 wave만으로 CRD·webhook·인증서 준비를 보장하지 않는다.

배포 후 검증 순서는 Argo/seed → root Application 등록 → LBC/cert-manager/External Secrets → Traefik → foundation → sample이다. controller Ready와 CRD/webhook 상태를 확인한 뒤 해당 CR Application을 동기화한다. secrets Application은 Secret 값이 공급된 뒤 확인하며 샘플과 분리돼 있다. readiness를 확인한 이후 자동 sync를 도입할지는 별도 운영 변경으로 다룬다.

## 코드 검증 재현

검증 도구는 Helm 3.19.0, Python 3.9 이상과 `scripts/requirements-validation.txt`의 라이브러리를 사용했다. chart archive와 렌더링 결과는 Git에 저장하지 않는다. 아래는 코드 검증 명령이며 클러스터에 연결하지 않는다.

```sh
terraform fmt -check -recursive
# 루트와 bootstrap 각각 임시 TF_DATA_DIR에서 init -backend=false 후 실행
terraform validate
terraform test

python3 scripts/validate_gitops.py --helm /path/to/helm --cache /tmp/nerdnam-chart-cache --fetch
# 이후 같은 cache에서는 --fetch 없이 검증 가능
```

검증 결과:

- AWS Terraform validate 및 mock 테스트 10개 통과, bootstrap validate 및 mock 테스트 1개 통과.
- 자체 Helm 차트 5개 lint/render, 고정한 공식 차트 5개 render 통과.
- 자체 Custom Resource 15개를 해당 공식 차트 CRD schema로 검증.
- controller workload 15개의 노드 선택자/toleration, 공개 NLB TCP 80·443, TLS Secret 연결, Secret 참조, 스토리지 보존, 필수 입력 누락 거절 검증.
- Traefik 차트의 변경된 `accessLog` 설정 형식에 맞췄다. 인증 헤더와 쿼리 문자열은 접근 로그에서 제외한다.

렌더링은 실제 webhook·AWS SDK·IAM 실효 권한·인증서 발급·DNS·네트워크 통신을 증명하지 않는다. native Kubernetes 리소스 전체에 대한 API server dry-run도 수행하지 않았다. 실제 Git sync·샘플 HTTPS 응답·Secret 동기화는 배포 후 별도 검증 항목이다.

## 아직 필요한 환경 정보

- root의 관리자 ARN/IP와 Route53 hosted zone ID, bootstrap의 배포 Git revision·샘플 DNS 이름·ACME 이메일.
- 실제 Git에 해당 revision이 올라가 있어야 Argo가 읽을 수 있다. 이번 작업은 로컬 커밋까지만 하며 push하지 않는다.
- AWS 실행자 정책과 Kubernetes 관리자 권한, private Git 최초 자격 증명, Secret JSON 값 및 도메인 레코드.
- 제안된 node 크기는 비용·부하 실측 전 후보다. 제어 도구와 관측 도구의 전체 requests 검토는 관측 구성 시 이어서 한다.

이 입력을 지금 공급하거나 AWS에 적용하지 않아도 5단계 PostgreSQL·Redis 코드를 작성할 수 있다. PostgreSQL 일일 S3 백업·새 PVC 복원 시험은 계속 보류한다.

근거: [Argo app-of-apps](https://argo-cd.readthedocs.io/en/stable/operator-manual/cluster-bootstrapping/), [LBC NLB](https://kubernetes-sigs.github.io/aws-load-balancer-controller/latest/guide/service/nlb/), [cert-manager Route53](https://cert-manager.io/docs/configuration/acme/dns01/route53/), [External Secrets AWS](https://external-secrets.io/latest/provider/aws-secrets-manager/).
