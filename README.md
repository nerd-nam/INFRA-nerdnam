# nerdnam 인프라

Terraform으로 AWS 기반을 만들고 Argo CD로 EKS 애플리케이션과 관측 도구를 배포하기 위한 저장소입니다.

- [현재 구축 계획: EKS · GitOps · 관측](docs/EKS-GitOps-관측-구축계획.md)
- 현재 구현: Terraform S3 backend·AWS provider 초기화. VPC·EKS·GitOps는 아직 계획 단계입니다.
- 초기 구성: 동일 EKS의 고정 CPU 워커 3대(app/platform/data). PostgreSQL·Redis도 data 워커의 StatefulSet으로 배포합니다. AI는 FastAPI를 통해 Bedrock Nova 2 Lite와 Titan V2를 호출합니다.
- 다음 구현: 퍼블릭/프라이빗 서브넷 각 1개를 서로 다른 AZ에 두는 VPC 기반 구성.

- PostgreSQL S3 일일 백업·새 PVC 복원 시험은 후속 작업으로 보류합니다.
- 각 구현 단계는 검증 후 커밋합니다.
