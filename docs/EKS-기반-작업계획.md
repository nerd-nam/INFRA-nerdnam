# 3단계: EKS 기반 코드 작성과 검증

2026-10-28. 현재는 인프라 코드를 작성하는 단계다. VPC나 EKS가 실제로 존재하지 않아도 후속 코드를 작성한다. AWS 배포 및 사용자의 apply는 코드 작업의 선행 조건이 아니다. 실제 리소스 생성·변경·삭제는 별도로 명시적인 실행 요청이 있을 때만 다룬다.

## 이번 검토에서 수정한 계획

- `enable_eks`와 모듈 `count`를 제거했다. 루트 설정에는 항상 VPC와 EKS가 함께 포함된다. 파일 작성·validate·mock 테스트는 AWS 리소스를 생성하지 않는다.
- VPC가 없는 것을 이유로 EKS/GitOps 코드 작성을 중단하지 않는다. 미확정 관리자 ARN·공인 IP는 필수 입력 변수로 남기고 운영 기본값을 임의로 채우지 않는다.
- 네트워크 모듈 전체의 `depends_on`을 없앴다. 서브넷 output에서 해당 라우팅·S3 endpoint 준비를 기다리므로 워커의 통신 경로 순서는 보존하며, add-on 카탈로그는 plan 시 조회할 수 있다.
- VPC CNI 권한을 노드 역할에서 제거하고 `aws-node` 전용 Pod Identity 역할로 분리했다. CNI보다 Pod Identity Agent를 먼저 선언하고, 두 add-on 준비 뒤 노드 그룹을 생성하는 의존성을 둔다. 실제 부트스트랩은 배포 이후 검증한다.
- CNI/EBS CSI 역할의 trust를 해당 클러스터 ARN·`kube-system` namespace·각 service account로 제한했다.
- CoreDNS 2개가 app/platform에만 배치되도록 affinity와 platform toleration을 추가했다. 노드·AZ 분산은 선호 조건이며 장애 시 살아 있는 노드에 함께 배치될 수 있다. 이것만으로 무중단 DNS를 보장하지 않는다.
- 지정한 add-on 버전은 그대로 사용하고 미지정 버전만 AWS 기본 호환 버전을 조회한다. add-on 설정은 Terraform 소유이므로 갱신 시 Terraform 설정으로 일치시킨다.

## 코드 구성

| 대상 | 작성한 설정 | 코드 밖에서 확인할 사항 |
| --- | --- | --- |
| EKS | Kubernetes 1.35 후보, API 인증·명시적 관리자 access entry, private API + 제한된 public API | 관리자 ARN/IP, 버전 지원 기간 및 도구 호환성 |
| app MNG | `m7i.xlarge`, public-a, `workload=app`, taint 없음 | 실제 자원 사용량·공인 IPv4 경로 |
| platform MNG | `m7i.xlarge`, private-c, `workload=platform`, `dedicated=platform:NoSchedule` | 운영 도구 requests와 toleration |
| data MNG | `m7i.large`, private-c, `workload=data`, `dedicated=data:NoSchedule` | PostgreSQL·Redis 부하와 영속 볼륨 |
| 노드 공통 | AL2023 x86_64, On-Demand, min/desired/max=1, encrypted gp3 root 50 GiB, IMDSv2·hop limit 1 | AMI release 고정, MNG 교체 중 일시 추가 EC2·용량/중단 |
| add-on | VPC CNI·kube-proxy·CoreDNS·Pod Identity Agent·EBS CSI | 실제 버전별 configuration schema·호환성·모든 노드의 DaemonSet |
| IAM | cluster/node/CNI/EBS CSI 역할, CNI·CSI Pod Identity | 조직 SCP/boundary, API별 실효 권한 |
| ECR | `nerdnam-dev/web`, `/api`, `/ai`, immutable tags, push scan | CI push 역할·이미지 digest는 6단계 |

m7i.large/xlarge가 서울 a/c에서 제공됨은 조회했다. 예약 용량이나 확정 가격을 확인한 것은 아니다. HPA/Karpenter/Cluster Autoscaler는 추가하지 않는다. SSM 접속 정책과 에이전트 구동은 아직 설정하지 않았으며 SSH도 열지 않는다.

기본 VPC 보안 그룹은 비어 있고 EKS는 자신의 cluster security group을 자동 생성해 MNG에 사용한다. 4단계에서 LBC가 NLB 관련 SG를 관리하는 구성과 VPC CNI NetworkPolicy 활성화, 기본 허용/차단 정책, gp3 StorageClass 코드를 추가했다. 샘플 PVC와 실제 저장소 시험은 후속이다. [GitOps 작업계획](GitOps-기반-작업계획.md)을 참고한다.

## 로컬 코드 검증

```sh
terraform fmt -check -recursive
# 원격 state 또는 AWS 자격 증명 없이 검증할 수 있는 별도 데이터 디렉터리
export TF_DATA_DIR="$(mktemp -d)"
terraform init -backend=false -input=false -lockfile=readonly
terraform validate
terraform test
unset TF_DATA_DIR
```

`terraform test`는 mock provider만 사용한다. 테스트용 ARN·IP·버전은 운영값이 아니며 AWS 리소스를 생성하지 않는다. 검증 항목은 VPC 격리·CIDR/AZ, 노드 수·서브넷·taint, API 접근 제한, CNI 권한 분리, DNS 배치 조건, 루트의 EKS 포함 및 add-on 버전 고정이다.

## 실제 plan을 준비할 때 필요한 입력

이 절차는 로컬 코드 작업을 계속하기 위한 조건이 아니다. 실제 계정 기준 계획을 확인하려는 시점에 사용한다.

1. `eks.dev.tfvars.example`을 참고해 ignored 파일 `eks.dev.tfvars`에 실제 관리자 IAM ARN과 공인 IPv4 CIDR을 작성한다. ARN은 영속적인 IAM user/role이어야 하며 STS 세션 ARN을 넣지 않는다. 예시 `203.0.113.1/32`를 운영값으로 사용하지 않는다.
2. 현재 S3/state·network 실행자 정책 외에 [EKS 실행자 정책](../iam/policies/nerdnam-terraform-eks-dev.json)을 준비했다. 파일 작성만 했으며 AWS 정책 생성·연결은 하지 않았다. `iam/README.md`의 범위와 한계를 확인한다.
3. 권한을 사용할 수 있게 되면 서울의 Kubernetes/add-on 호환 버전을 조회하고 `eks_addon_versions`에 고정한다. 미지정 값은 AWS 기본값을 조회하므로 시간이 지나면 계획이 달라질 수 있다. CoreDNS의 affinity/tolerations와 CNI/CSI의 Pod Identity 지원도 해당 버전의 schema로 대조한다.
4. 아래처럼 plan을 확인한다. apply는 실행하지 않는다. 비용 산정·운영 도메인·배포 commit 등 1단계의 미확정 정보는 배포 결정 전에 채운다.

```sh
unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
export AWS_PROFILE=nerdnam-infra
terraform init -input=false -lockfile=readonly
terraform plan -input=false -var-file=eks.dev.tfvars
```

VPC가 없는 현재 상태에서 plan에는 VPC와 EKS 모두 포함된다. 이전 코드의 `module.eks[0]`는 AWS에 적용한 적이 없어 state 이동은 필요하지 않다. 기존 S3 backend·bootstrap은 유지한다.

## 검증 결과와 배포 후 확인할 사항

- fmt/validate 및 mock 테스트 9개 통과. 정책 JSON 문법과 고객 관리형 정책 크기 제한도 확인했다.
- 실제 계정 plan은 `eks:DescribeAddonVersions` 권한 부족으로 완료되지 않았다. 이전의 네트워크 전체 의존성 아래 생성된 39개 plan은 add-on 조회가 지연된 결과였으며, 현재 코드에 대한 검증 결과로 사용하지 않는다.
- IAM 정책은 코드의 API 목록과 대조한 초안이다. AWS IAM Access Analyzer·실효 권한 시뮬레이션과 실제 생성/수정/삭제 경로는 검증하지 않았다. VPC가 없다고 임시 AWS 리소스를 만들어 검증하지 않는다.
- 배포 후 별도 확인: 노드 3대 Ready, CoreDNS 실제 분산과 DNS 조회, public/private Pod 외부 통신, private 노드 ECR pull, CNI/CSI Pod Identity, EBS 동적 PVC 및 Pod 재연결. 배포 없이 이 항목을 완료로 표시하지 않는다.
- Argo CD·Ingress·Secret 공급·StorageClass는 4단계 코드로 진행한다. PostgreSQL 일일 S3 백업과 새 PVC 복원 시험은 계속 후속 보류다.

근거: [EKS add-on IAM](https://docs.aws.amazon.com/eks/latest/userguide/add-ons-iam.html), [Pod Identity trust 조건](https://docs.aws.amazon.com/eks/latest/userguide/pod-id-role.html), [CoreDNS 설정](https://docs.aws.amazon.com/eks/latest/userguide/managing-coredns.html), [EKS 버전 수명주기](https://docs.aws.amazon.com/eks/latest/userguide/kubernetes-versions.html).
