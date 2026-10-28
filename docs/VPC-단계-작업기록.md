# VPC 단계 작업 기록

2026-10-28. 코드 구현과 실제 AWS 적용 상태를 구분해 기록한다.

## 범위

- PostgreSQL S3 백업·새 PVC 복원 시험은 후속 작업이다. 백업 CronJob·bucket·IAM·snapshot은 생성하지 않는다.
- 기존 Terraform 루트/S3 backend/bootstrap resource를 유지하고 `modules/network`를 추가했다.
- VPC·서로 다른 AZ의 public/private subnet·IGW·NAT/EIP·route table/route/association·S3 Gateway endpoint를 선언했다.
- 새 VPC의 기본 SG는 비워 두고 EKS/NLB 전용 SG는 다음 단계에서 작성한다.
- CIDR은 정규화된 IPv4 /16만 허용하고 public /24·private /20을 겹치지 않게 계산한다.
- 대상 계정을 provider의 `allowed_account_ids`로 제한했다.

## 실제 계정 확인

- STS 인증: 계정 `082139775699`, IAM 사용자 `terraform` 확인.
- 서울 리전 VPC 조회: 반환된 VPC 없음. 다른 리전·연결망 CIDR까지 확인한 결과는 아니다.
- 기존 backend `nerdnam-terraform-082139775699-ap-northeast-2-an/dev/terraform.tfstate` 읽기: S3 HeadObject **403 Forbidden**.
- 진단용 버킷 목록 조회도 `s3:ListAllMyBuckets` 권한 부족으로 거절됐다. 이 목록 권한 자체가 Terraform backend에 필수인 것은 아니다.
- 기존 state를 읽을 수 없어 실제 계정 plan과 apply는 수행하지 못했다. backend 경로나 IAM을 임의 변경하지 않았다.

## 재개 조건

1. 기존 bucket 이름/key가 맞는지와 현재 IAM 주체의 접근을 확인한다.
2. backend에 필요한 bucket ListBucket, state 객체 GetObject/PutObject, `.tflock` 객체 GetObject/PutObject/DeleteObject 권한을 해당 경로로 제한해 확인한다. bucket policy·SCP·명시적 deny·KMS 암호화를 사용한다면 관련 키 권한도 확인한다. 403만으로 원인을 하나로 단정하지 않는다.
3. 정상 backend로 `terraform init -lockfile=readonly`와 `terraform plan`을 다시 실행한다. 기존 bootstrap/state와 새 네트워크 변경만 포함되는지 확인한다.
4. NAT/EIP 및 후속 서비스 비용을 확인한 후 실제 적용으로 진행한다. state 없이 만든 임시 plan을 운영 적용에 사용하지 않는다.
5. 적용 후 subnet/route/endpoint 상태와 NAT available을 확인한다. 실제 Pod 통신은 EKS 노드를 만든 다음 단계에서 검증한다.

## 로컬 검증

S3 backend와 분리한 임시 `TF_DATA_DIR`에서 고정된 AWS provider 6.70.0으로 검증한다. `terraform test`는 mock provider만 사용하며 AWS 호출·실제 리소스 생성을 하지 않는다.

- Terraform 형식 검사: 통과.
- Terraform validate: 통과.
- 네트워크 격리, 동일 AZ 거절, 비정규 CIDR 거절 테스트: **3개 통과, 0개 실패**.
