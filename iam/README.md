# Terraform 실행 그룹 권한

2026-10-28. `nerdnam-infra` IAM 그룹의 **현재 VPC 단계** 권한이다. 파일을 준비한 것이며 AWS 정책 생성·그룹 연결은 수행하지 않았다.

| 고객 관리형 정책 이름 | JSON 파일 | 범위 |
| --- | --- | --- |
| `NerdnamTerraformStateDev` | [state 정책](policies/nerdnam-terraform-state-dev.json) | 기존 bucket 목록 조회, dev state 읽기/쓰기, 해당 잠금 객체 읽기/쓰기/삭제 |
| `NerdnamTerraformNetworkDev` | [network 정책](policies/nerdnam-terraform-network-dev.json) | 서울 EC2 조회와 현재 VPC 모듈에 필요한 네트워크 생성/변경/삭제 |

## 적용

1. IAM 관리 권한이 있는 사용자가 IAM → 정책 → 정책 생성 → JSON에서 파일 내용을 붙여 넣고 위 이름으로 저장한다.
2. IAM → 사용자 그룹 → `nerdnam-infra` → 권한 → 정책 연결에서 두 정책을 연결한다.
3. Terraform 실행 사용자를 그룹에 추가한다. 로컬 프로필은 새 사용자를 선택한다.
4. STS 신원, state HeadObject, Terraform init/plan 순서로 확인한다. 액세스 키 원문은 저장소나 채팅에 넣지 않는다.

```sh
aws sts get-caller-identity --profile nerdnam-terraform
aws s3api head-object --bucket nerdnam-terraform-082139775699-ap-northeast-2-an --key dev/terraform.tfstate --profile nerdnam-terraform
```

## 정책의 범위와 제한

- S3 객체 권한은 state와 lock 두 경로에 한정한다. state 자체의 DeleteObject, 다른 bucket 접근, S3 bucket 생성/삭제 권한은 부여하지 않는다. ListBucket은 이 bucket의 객체 이름 조회를 허용하되 다른 객체 본문 읽기는 허용하지 않는다. 기본 workspace만 사용하는 현재 backend 기준이다.
- S3 native lock을 사용하므로 DynamoDB 권한은 필요 없다. 고객 관리형 KMS 키를 쓰는 bucket이라면 해당 키의 Encrypt/Decrypt/GenerateDataKey 권한과 키 정책을 별도 확인한다. 현재 파일에는 추측한 KMS ARN을 넣지 않았다.
- network 정책은 리전과 작업 종류를 제한한다. `Resource: "*"`이므로 **nerdnam 태그가 있는 리소스에만 한정되는 정책은 아니다.** 서울의 다른 네트워크도 변경할 수 있고 EC2 태그도 변경할 수 있다. 프로젝트 격리는 리소스별 ARN/태그 조건을 추가 검증하는 후속 작업이다. 이를 완전한 최소 권한 정책이라고 부르지 않는다.
- default security group 규칙을 비우는 코드 때문에 revoke 권한이 필요하고, 설정 변경/복구 경로를 위해 authorize도 포함한다. EC2 인스턴스 실행·종료, SG 신규 생성, IAM 관리 권한은 현재 파일에 없다.
- 기존 AmazonEC2FullAccess/AdministratorAccess 등 넓은 정책을 함께 붙이면 이 파일의 제한이 사용자 전체 권한 제한이 되지 않는다. 그룹·사용자에 연결된 전체 정책을 함께 확인한다.
- 현재 S3 403은 신규 사용자만 만든다고 해결되지 않는다. 정확한 bucket/key, identity policy, bucket policy, permissions boundary/SCP의 deny, KMS 사용 여부를 확인한다.
- JSON 구조와 현재 Terraform 리소스/API 목록은 대조했지만 AWS IAM Access Analyzer 검사나 실제 plan/apply로 권한 충분성을 검증한 상태는 아니다.

## 후속 단계에서 추가할 권한

| 단계 | 추가 범위 |
| --- | --- |
| EKS/MNG | EKS cluster/nodegroup/add-on/access entry/Pod Identity, EC2 Launch Template·전용 SG, 필요한 service-linked role, 이름 제한 IAM role/policy 및 PassRole |
| 이미지 CI | ECR repository 관리와 별도의 CI push 역할. GitHub OIDC trust |
| 관측/Secret | 로그/trace S3 bucket, CloudWatch, Secrets Manager 메타데이터 및 workload별 IAM 역할 |
| DNS | 사용할 Route53 zone/record와 cert-manager 역할 |
| DB 백업 | 사용자 요청으로 후속 보류. 현재 S3 백업 bucket/Job 권한을 추가하지 않음 |

Terraform 실행자의 역할 생성 권한과 실제 AI Pod의 Bedrock 호출 권한은 구분한다. 후자는 AI ServiceAccount 전용 역할에 부여한다. EKS 서비스 역할용 AWS 관리형 정책을 Terraform 사용자에게 붙이는 것으로 실행자 권한을 대체하지 않는다.

근거: [Terraform S3 backend 권한](https://developer.hashicorp.com/terraform/language/backend/s3), [EC2 작업·종속 권한](https://docs.aws.amazon.com/service-authorization/latest/reference/list_ec2.html), [EC2 리전 제한](https://docs.aws.amazon.com/IAM/latest/UserGuide/reference_policies_examples_ec2_region.html).
