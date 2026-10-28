# VPC 단계 작업 기록

2026-10-28. 코드 구현과 실제 AWS 적용 상태를 구분해 기록한다.

## 범위

- PostgreSQL S3 백업·새 PVC 복원 시험은 후속 작업이다. 백업 CronJob·bucket·IAM·snapshot은 생성하지 않는다.
- 기존 Terraform 루트/S3 backend/bootstrap resource를 유지하고 `modules/network`를 추가했다.
- VPC·서로 다른 AZ의 public/private subnet·IGW·NAT/EIP·route table/route/association·S3 Gateway endpoint를 선언했다.
- 새 VPC의 기본 SG는 비워 두고 EKS/NLB 전용 SG는 다음 단계에서 작성한다.
- CIDR은 정규화된 IPv4 /16만 허용하고 public /24·private /20을 겹치지 않게 계산한다.
- 대상 계정을 provider의 `allowed_account_ids`로 제한했다.

## 이전 계정 확인 기록

- STS 인증: 계정 `082139775699`, IAM 사용자 `terraform` 확인.
- 서울 리전 VPC 조회: 반환된 VPC 없음. 다른 리전·연결망 CIDR까지 확인한 결과는 아니다.
- 기존 backend `nerdnam-terraform-082139775699-ap-northeast-2-an/dev/terraform.tfstate` 읽기: S3 HeadObject **403 Forbidden**.
- 진단용 버킷 목록 조회도 `s3:ListAllMyBuckets` 권한 부족으로 거절됐다. 이 목록 권한 자체가 Terraform backend에 필수인 것은 아니다.
- 당시 기존 state를 읽을 수 없어 실제 계정 plan과 apply를 수행하지 못했다. backend 경로나 IAM을 임의 변경하지 않았다.

## 2026-10-28 실제 적용

- AWS CLI `nerdnam-infra` 프로필이 계정 `082139775699`의 IAM 사용자 `nerdnam-infra`임을 확인했고 기존 S3 state의 HeadObject와 Terraform init이 성공했다.
- 기존 원격 state를 사용해 계획을 확인한 후 저장된 plan으로 적용했다: **14개 생성, 변경·삭제 0개**.
- VPC `vpc-00a3041d1029ff3ce` (`10.20.0.0/16`), public-a `subnet-00da289e74bf79545` (`10.20.0.0/24`), private-c `subnet-03eb5fdcda1d637e9` (`10.20.16.0/20`)를 생성했다.
- NAT `nat-04cc580934c78f8bb`는 `available`이다. public 기본 경로는 IGW, private 기본 경로는 NAT이며 두 경로와 양쪽 S3 Gateway endpoint 경로가 `active`다.
- 적용 후 `terraform plan -detailed-exitcode` 결과 변경 없음(exit 0). NAT Gateway와 퍼블릭 IPv4는 요금이 발생한다.
- 실제 Pod 통신과 인터넷·S3 접근은 EKS 노드를 만든 이후 검증한다. 아직 EKS나 워커는 생성하지 않았다.

## 로컬 검증

S3 backend와 분리한 임시 `TF_DATA_DIR`에서 고정된 AWS provider 6.70.0으로 검증한다. `terraform test`는 mock provider만 사용하며 AWS 호출·실제 리소스 생성을 하지 않는다.

- Terraform 형식 검사: 통과.
- Terraform validate: 통과.
- 네트워크 격리, 동일 AZ 거절, 비정규 CIDR 거절 테스트: **3개 통과, 0개 실패**.
