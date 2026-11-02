# 작업 방식

- 현재는 Terraform 및 배포 코드를 작성·검증하는 단계다. 실제 인프라가 없어도 코드 작업을 계속한다.
- 사용자가 해당 변경의 실제 실행을 명시적으로 요청하지 않는 한 `terraform apply`, `terraform destroy`, AWS 리소스 생성·변경·삭제, IAM 정책 연결을 실행하지 않는다. 적용은 사용자가 직접 한다.
- 코드 확인, 읽기 전용 AWS 조회, `terraform plan`, fmt/validate, mock provider를 사용하는 `terraform test`는 수행할 수 있다. mock 테스트의 apply는 실제 AWS apply와 구분한다.
- 실제 적용을 막기 위해 리소스 활성화 스위치나 가짜 운영 기본값을 추가하지 않는다. 배포에 필요한 미확정 값은 입력 변수와 예시 파일로 표현한다.
- 코드 검증과 배포 후 검증 결과를 구분한다. 실제 노드 Ready, 네트워크 통신, PVC 영속성 등은 AWS 배포 없이 완료됐다고 기록하지 않는다.
- PostgreSQL S3 일일 백업·새 PVC 복원 시험은 후속 작업이다.
- 각 작업 단계에서 검증 후 커밋한다. push는 별도 요청이 있을 때 수행한다.
