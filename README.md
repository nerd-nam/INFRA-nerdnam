# nerdnam 인프라

Terraform으로 AWS 기반을 만들고 Argo CD로 EKS 애플리케이션과 관측 도구를 배포하기 위한 저장소입니다.

- [현재 구축 계획: EKS · GitOps · 관측](docs/EKS-GitOps-관측-구축계획.md)
- 현재 구현: Terraform S3 backend·AWS provider, VPC network 모듈. EKS·GitOps는 다음 단계입니다. AWS 적용은 아직 하지 않았습니다.
- 초기 구성: 동일 EKS의 고정 CPU 워커 3대(app/platform/data). PostgreSQL·Redis도 data 워커의 StatefulSet으로 배포합니다. AI는 FastAPI를 통해 Bedrock Nova 2 Lite와 Titan V2를 호출합니다.
- 현재 단계: VPC 코드 검증 후 기존 S3 state 접근 문제를 해결하고 실제 plan을 확인합니다.

- PostgreSQL S3 일일 백업·새 PVC 복원 시험은 후속 작업으로 보류합니다.
- 각 구현 단계는 검증 후 커밋합니다.

## VPC 구성

| 항목 | 값 |
| --- | --- |
| AWS 대상 | `082139775699`, `ap-northeast-2` |
| VPC | `10.20.0.0/16`, DNS support/hostnames 활성화 |
| public | `10.20.0.0/24`, `ap-northeast-2a`, 공인 IP 자동 부여 |
| private | `10.20.16.0/20`, `ap-northeast-2c`, 공인 IP 미부여 |
| 외부 경로 | public → IGW, private → public의 NAT Gateway 1개 |
| S3 | Gateway endpoint를 두 route table에 연결 |
| 기본 SG | ingress/egress 없음. EKS/NLB SG는 다음 단계에서 구성 |

서브넷 CIDR은 IPv4 /16 VPC에서 자동 계산해 중첩을 방지합니다. `vpc_cidr`와 `availability_zones`를 바꿀 수 있으며 두 AZ는 달라야 합니다. `providers.tf`의 계정 제한은 다른 계정에 실수로 생성하는 것을 막습니다.

## 검증과 실행

저장소 루트에서 실행합니다. 기존 backend key `dev/terraform.tfstate`와 lockfile을 유지합니다.

```sh
terraform init -input=false -lockfile=readonly
terraform fmt -check -recursive
terraform validate
terraform test
terraform plan -out=dev.tfplan
terraform show dev.tfplan
```

`terraform test`는 mock AWS provider만 사용합니다. 테스트 안의 apply는 메모리의 가짜 리소스를 만드는 동작이며 AWS 리소스를 생성하지 않습니다. 실제 생성은 검토한 plan에 대해 `terraform apply dev.tfplan`을 실행할 때 이루어집니다. 적용 후 `terraform output network`로 다음 단계 입력값을 확인합니다.

NAT Gateway·EIP는 적용 시점부터 비용이 발생합니다. private-c가 public-a NAT를 사용하므로 AZ 간 전송과 단일 NAT 장애 영향도 고려합니다. 이번 코드에는 EKS·EC2·NLB·DB 백업 리소스가 없습니다.

S3 backend 접근이 막혀 있어도 로컬 검증은 별도 Terraform 데이터 디렉터리에서 가능합니다. 이 방식으로 실제 plan/apply를 우회하지 않습니다.

```sh
export TF_DATA_DIR="$(mktemp -d)"
terraform init -backend=false -input=false -lockfile=readonly
terraform validate
terraform test
unset TF_DATA_DIR
```

현재 확인 결과와 재개 조건은 [VPC 단계 작업 기록](docs/VPC-단계-작업기록.md)을 참고합니다.
