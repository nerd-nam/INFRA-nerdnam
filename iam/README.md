# Terraform 실행 그룹 권한

2026-10-28. `nerdnam-infra` IAM 그룹에서 VPC와 EKS 코드를 실행하기 위한 정책 파일이다. 현재는 코드 작성 단계이며 이 문서에 따른 AWS 정책 생성·연결을 수행하지 않는다. 정책 연결은 로컬 검증과 후속 코드 작성의 선행 조건이 아니다.

| 고객 관리형 정책 이름 | JSON 파일 | 범위 |
| --- | --- | --- |
| `NerdnamTerraformStateDev` | [state 정책](policies/nerdnam-terraform-state-dev.json) | 기존 bucket 목록 조회, dev state 읽기/쓰기, 해당 잠금 객체 읽기/쓰기/삭제 |
| `NerdnamTerraformNetworkDev` | [network 정책](policies/nerdnam-terraform-network-dev.json) | 서울 EC2 조회와 현재 VPC 모듈에 필요한 네트워크 생성/변경/삭제 |
| `NerdnamTerraformEksDev` | [EKS 정책 초안](policies/nerdnam-terraform-eks-dev.json) | 프로젝트 EKS·역할·ECR 관리, 서울 Launch Template, 필요한 서비스 연결 역할 |
| `NerdnamTerraformPlatformDev` | [platform 정책 초안](policies/nerdnam-terraform-platform-dev.json) | 공통 controller 역할과 런타임 Secret 생성·관리 |
| `NerdnamTerraformWorkloadDev` | [workload 정책 초안](policies/nerdnam-terraform-workload-dev.json) | AI Bedrock 역할·CI 역할 3개의 생성·inline 정책, AI 역할 PassRole(Pod Identity), GitHub OIDC provider 관리 |
| `NerdnamTerraformObservabilityDev` | [observability 정책 초안](policies/nerdnam-terraform-observability-dev.json) | Loki 로그·Tempo trace bucket 2개의 생성·설정·삭제, Loki·Tempo 역할과 inline 정책, 두 역할 PassRole(Pod Identity). 객체 읽기·쓰기는 넣지 않음 |
| `NerdnamTerraformBootstrapStateDev` | [bootstrap state 정책](policies/nerdnam-terraform-bootstrap-state-dev.json) | 별도 dev/bootstrap.tfstate와 잠금 객체 |

## 적용

1. IAM 관리 권한이 있는 사용자가 IAM → 정책 → 정책 생성 → JSON에서 파일 내용을 붙여 넣고 위 이름으로 저장한다.
2. 실제 실행 권한을 준비하는 시점에 IAM → 사용자 그룹 → `nerdnam-infra` → 권한 → 정책 연결에서 필요한 정책을 연결한다. AWS 루트는 state/network/EKS/platform/workload/observability 정책을 사용한다. bootstrap에는 별도 state 정책과 기존 AWS state 읽기, EKS 관리자 인증이 필요하다.
3. Terraform 실행 사용자를 그룹에 추가한다. 로컬 프로필은 새 사용자를 선택한다.
4. STS 신원, state HeadObject, Terraform init/plan 순서로 확인한다. 액세스 키 원문은 저장소나 채팅에 넣지 않는다.

```sh
aws sts get-caller-identity --profile nerdnam-infra
aws s3api head-object --bucket nerdnam-terraform-082139775699-ap-northeast-2-an --key dev/terraform.tfstate --profile nerdnam-infra
```

## 정책의 범위와 제한

- S3 객체 권한은 state와 lock 두 경로에 한정한다. state 자체의 DeleteObject, 다른 bucket 접근, S3 bucket 생성/삭제 권한은 부여하지 않는다. ListBucket은 이 bucket의 객체 이름 조회를 허용하되 다른 객체 본문 읽기는 허용하지 않는다. 기본 workspace만 사용하는 현재 backend 기준이다.
- S3 native lock을 사용하므로 DynamoDB 권한은 필요 없다. 고객 관리형 KMS 키를 쓰는 bucket이라면 해당 키의 Encrypt/Decrypt/GenerateDataKey 권한과 키 정책을 별도 확인한다. 현재 파일에는 추측한 KMS ARN을 넣지 않았다.
- network 정책은 리전과 작업 종류를 제한한다. `Resource: "*"`이므로 **nerdnam 태그가 있는 리소스에만 한정되는 정책은 아니다.** 서울의 다른 네트워크도 변경할 수 있고 EC2 태그도 변경할 수 있다. 프로젝트 격리는 리소스별 ARN/태그 조건을 추가 검증하는 후속 작업이다. 이를 완전한 최소 권한 정책이라고 부르지 않는다.
- default security group 규칙을 비우는 코드 때문에 revoke 권한이 필요하고, 설정 변경/복구 경로를 위해 authorize도 포함한다. EC2 인스턴스 실행·종료, SG 신규 생성, IAM 관리 권한은 현재 파일에 없다.
- 기존 AmazonEC2FullAccess/AdministratorAccess 등 넓은 정책을 함께 붙이면 이 파일의 제한이 사용자 전체 권한 제한이 되지 않는다. 그룹·사용자에 연결된 전체 정책을 함께 확인한다.
- 이전 사용자 `terraform`의 S3 403 이후 `nerdnam-infra` 사용자로 backend 접근과 VPC 생성에 성공했다. 403의 구체적인 원인과 각 연결 정책은 확인하지 않았다.
- 새 사용자로 VPC 생성 후 사용자의 요청에 따라 삭제했다. 삭제 도중 Elastic IP 연결 해제 권한 부족을 확인해 정책 파일에 `ec2:DisassociateAddress`를 추가했다. 이 수정은 AWS에 자동 반영되지 않는다. 실제 사용자에게 연결된 모든 정책은 확인하지 않았고, 수정된 정책만으로 모든 변경·삭제 경로가 동작하는지도 검증되지 않았다.

## 후속 단계에서 추가할 권한

platform 실행자 정책의 inline role policy·trust 변경은 지정한 세 controller 역할에 한정하지만, 그 역할에 부여할 수 있는 권한 내용 자체를 제한하는 boundary는 아니다. 신뢰하는 인프라 운영자용 초안이며 최소 권한을 보장한다고 해석하지 않는다. 또한 코드가 Secret 메타데이터만 선언하더라도 IAM의 CreateSecret/UpdateSecret API 권한은 Secret 값을 쓰는 데도 사용될 수 있다. 실제 secret 읽기 GetSecretValue는 이 실행자 정책에 넣지 않았다.

Bootstrap state 정책은 원격 AWS state와 다른 key를 사용한다. Kubernetes 배포 권한은 S3 정책으로 생기지 않으며 기존 EKS access entry가 필요하다. 실제 계정에 위 정책을 생성·연결하거나 검증하지 않았다.

EKS 실행자 정책은 계정 `082139775699`의 `nerdnam-dev` 클러스터와 그 하위 리소스, web/api/ai ECR, cluster/node/cni/ebs-csi 네 IAM 역할로 범위를 제한했다. 역할에 연결할 수 있는 정책은 코드에 사용하는 AWS 관리형 정책 5개로 제한하고 PassRole 대상 서비스도 제한했다. 역할 trust 수정과 클러스터 관리자 access entry 관리는 강한 권한이므로 신뢰하는 인프라 운영자에게 부여한다. 최소 권한이 완성됐다고 보지는 않는다.

Launch Template 관리 작업은 서울 리전 전체 범위이며 기존 network 정책의 EC2 조회·태그 권한을 함께 사용한다. EKS 카탈로그 조회는 리소스 ARN으로 제한할 수 없어 `Resource: "*"`다. CI 이미지 push, 앱 Bedrock 호출, S3 관측 저장소 등은 포함하지 않는다. JSON 구문과 고객 관리형 정책 크기는 확인했지만 IAM Access Analyzer 및 실제 EKS 생성·변경·삭제는 검증하지 않았다. 실제 plan에서 `eks:DescribeAddonVersions`가 거부되는 현재 상태도 코드 개발을 막지 않는다.

| 단계 | 추가 범위 |
| --- | --- |
| EKS/MNG | 초안을 위 파일로 준비. 실제 권한 검증과 운영 입력 확정은 배포 준비 시 수행 |
| 이미지 CI | workload 정책 초안으로 준비(6단계). CI 역할 자체의 push 권한은 Terraform 이 역할 inline 정책으로 부여 |
| 관측/Secret | 7단계: Loki bucket·역할(observability 정책), `nerdnam/dev/monitoring` Secret(platform 정책). 8단계: Tempo bucket·역할(같은 정책). CloudWatch 연계는 이후 |
| DNS | 사용할 Route53 zone/record와 cert-manager 역할 |
| DB 백업 | 사용자 요청으로 후속 보류. 현재 S3 백업 bucket/Job 권한을 추가하지 않음 |

관리형 노드 그룹이 시작 템플릿을 쓰면 EKS가 **호출자 권한으로** 인스턴스를 띄운다. 그래서 EKS 실행자 정책에 `ec2:RunInstances`(서울)와 시작 때의 `ec2:CreateTags`가 필요하다. 2026-10-29 첫 apply에서 이 권한이 없어 노드 그룹 3개가 `You are not authorized to launch instances with this launch template`로 실패해 추가했다.

workload 정책도 inline 정책 내용 자체를 제한하는 boundary가 아니다. 지정한 4개 역할에 어떤 inline 정책이든 넣을 수 있으므로 신뢰하는 인프라 운영자용이다. Pod Identity association 생성은 EKS 정책(`podidentityassociation/nerdnam-dev/*`)이 담당한다. Terraform 실행자의 역할 생성 권한과 실제 AI Pod의 Bedrock 호출 권한은 구분한다. 후자는 AI ServiceAccount 전용 역할에 부여한다. EKS 서비스 역할용 AWS 관리형 정책을 Terraform 사용자에게 붙이는 것으로 실행자 권한을 대체하지 않는다.

근거: [Terraform S3 backend 권한](https://developer.hashicorp.com/terraform/language/backend/s3), [EC2 작업·종속 권한](https://docs.aws.amazon.com/service-authorization/latest/reference/list_ec2.html), [EC2 리전 제한](https://docs.aws.amazon.com/IAM/latest/UserGuide/reference_policies_examples_ec2_region.html).
