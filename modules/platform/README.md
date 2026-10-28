# GitOps controller AWS 권한

Terraform은 controller별 Pod Identity 역할과 Secrets Manager의 빈 메타데이터만 선언한다. Kubernetes ServiceAccount와 컨트롤러는 GitOps 차트가 관리한다. namespace/service account 이름은 양쪽에서 동일해야 한다.

- LBC: kube-system/aws-load-balancer-controller
- cert-manager: cert-manager/cert-manager, 지정 hosted zone의 TXT 변경과 조회
- External Secrets: external-secrets/external-secrets, backend/data/ai 세 Secret의 GetSecretValue와 DescribeSecret

LBC 정책은 공식 v3.6.2 배포 정책 원문이다. 광범위한 조회와 서비스 연결 역할 생성 등이 포함되며 전부 프로젝트 ARN으로 제한된 정책은 아니다. 코드에 넣은 원문은 임의로 축소하지 않았다.

원문: https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/v3.6.2/docs/install/iam_policy.json

SHA256: `16f232c9d9f79366fe949c4550ad517a202380058a9e48d45a4e215044a20a6a`

Secret 값은 aws_secretsmanager_secret_version이나 Terraform 변수로 받지 않는다. Secret 생성/수정 API를 가진 인프라 운영자의 실효 권한과 controller의 읽기 권한은 별개다. Secret 값은 배포 준비 시 별도 경로로 공급하며 지금 생성하지 않는다.
