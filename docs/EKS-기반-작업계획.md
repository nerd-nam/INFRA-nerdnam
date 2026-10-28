# 3단계: EKS 기반 작업계획과 실행 안내

2026-10-28. 코드와 모의 검증을 준비했다. VPC는 이전 사용자 요청으로 삭제됐으며 EKS·노드·ECR은 아직 AWS에 생성하지 않았다. `terraform apply`는 사용자가 직접 실행한다.

## 목표와 범위

- 관리형 EKS 컨트롤 플레인 1개, app/platform/data Managed Node Group 각 1대. Auto Scaling 용량은 각 min/desired/max = 1이며 HPA/Karpenter/Cluster Autoscaler를 설치하지 않는다.
- app은 public-a, platform/data는 private-c. `workload` 라벨과 platform/data `dedicated:NoSchedule` taint로 후속 워크로드 배치를 구분한다. 실제 배치·toleration은 매니페스트 작성 후 검증한다.
- 초기 후보는 app/platform `m7i.xlarge`, data `m7i.large`이고 서울 a/c에 타입이 제공됨을 조회했다. 실제 잔여 용량을 보장하지 않으며 가격과 예산은 미확정이다.
- 노드 루트 디스크는 암호화 gp3 50 GiB, IMDSv2 필수·hop limit 1. EC2 SSH 키나 SSH 보안 그룹 규칙은 추가하지 않는다. 앱 워커는 public subnet의 공인 IP를 사용할 수 있다.
- EKS API private 활성화와 제한된 public 접근, IAM access entry를 사용한다. 관리자 IAM ARN과 공인 IP CIDR은 사용자가 지정해야 한다. 관리 권한은 선택한 주체에 클러스터 전체 관리자 권한이다.
- EKS managed add-on: VPC CNI, kube-proxy, CoreDNS, Pod Identity agent, EBS CSI. EBS CSI에는 전용 Pod Identity 역할을 연결한다. `AmazonEKS_CNI_Policy`는 현재 초기 부트스트랩을 위해 노드 역할에 붙는다. AWS 권고대로 별도 CNI 역할로 옮기고 노드 역할에서 제거하는 작업이 남아 있다. hostNetwork Pod 등 노드 자격 증명 접근 경로도 점검한다.
- ECR `nerdnam-dev/web`, `/api`, `/ai`는 태그 불변·push 시 스캔. CI push 역할, 로드밸런서, Argo CD, 앱, PVC, Bedrock workload 역할은 후속 단계다. PostgreSQL S3 백업과 복원 시험은 별도 후속 작업으로 보류한다.

## 사용자 실행 순서

1. AWS 계정·예산·관리 IP·관리자 IAM 주체를 확정한다. EKS, EC2 3대, 50 GiB 루트 볼륨 3개, NAT, 공인 IPv4 등 비용이 발생한다. ECR, 워크로드 볼륨, 로그, 전송량 등 추가 비용도 별도다. 보안 검토와 예산 확정 전 apply하지 않는다.
2. `nerdnam-infra` 프로필의 Terraform 실행 주체에 EKS, ECR, IAM 역할 생성·정책 연결·PassRole, 서비스 연결 역할, EC2 launch template/보안 그룹 등 권한을 부여한다. 기존 VPC 단계의 두 정책만으로는 부족하다. IAM 역할 위임은 권한 상승 위험이 있어 역할 ARN과 서비스별 PassRole 조건을 정한 뒤 관리자와 별도로 구성한다. EKS 조회(`eks:DescribeClusterVersions`, `eks:DescribeAddonVersions`)도 필요하다. 실행자 정책의 전체 권한 목록과 실제 적용 경로는 아직 검증하지 않았다.
3. 현재 기본 설정은 `enable_eks = false`다. VPC 2단계 plan을 검토하고 사용자가 직접 apply한다. 이후에는 생성된 VPC를 유지한다. 기존 backend와 bootstrap resource를 삭제하지 않는다.
4. 다음 설정을 저장소에 커밋되지 않는 `eks.dev.tfvars`에 작성한다. CIDR은 실제 관리자 공인 IPv4이며 예시 주소를 그대로 사용하면 접근할 수 없다. 기존 사용자 ARN은 예시로, 실제 사용할 관리 주체를 확인해야 한다. CI 또는 다른 관리자 접속 IP도 필요하면 추가한다.

```hcl
enable_eks             = true
eks_admin_principal_arn = "arn:aws:iam::082139775699:user/nerdnam-infra"
eks_public_access_cidrs = ["203.0.113.1/32"] # 예시: 실제 관리 IP로 변경
```

5. 선택한 Kubernetes 1.35 및 add-on과 운영 도구의 호환성, AWS 계정의 서비스 할당량·가용 용량을 확인한다. 기본값은 계정의 EKS 호환 기본 add-on 버전을 조회하므로 나중에 AWS 기본값이 변경되면 계획에 버전 변경이 나타날 수 있다. 적용 전에 `aws eks describe-addon-versions`로 각 버전을 조회하고 `eks_addon_versions` map에 모두 고정하는 것을 권장한다. 아직 실제 계정 조회 권한이 없어 호환 버전은 확인하지 못했다.
6. 실제 값과 권한을 갖춘 뒤 `terraform plan -var-file=eks.dev.tfvars`를 실행해 VPC에 의도하지 않은 변경 없이 EKS·ECR만 추가되는지 검토하고, 사용자가 직접 apply한다. VPC가 없다면 plan에는 VPC도 포함된다. 예시 주소로 만든 사전 plan은 배포용으로 쓰지 않는다.
7. 생성 후 `aws eks update-kubeconfig --region ap-northeast-2 --name nerdnam-dev --profile nerdnam-infra`와 `kubectl get nodes -o wide`, `kubectl get pods -n kube-system -o wide`로 노드 3대 Ready와 add-on 상태를 확인한다. 사용할 관리 주체와 실제 profile이 다른 경우 해당 profile로 변경한다.
8. 라벨·taint, CoreDNS 양쪽 가용 배치, 클러스터 내부 DNS와 Pod 간 통신, public/private 노드 외부 통신과 private 노드의 ECR pull, Pod Identity 및 EBS CSI 동적 PVC 생성·Pod 재연결을 실제 검증한다. 별도의 테스트 이미지/워크로드·ECR push 권한은 마련해야 한다. 이후 EBS 테스트 리소스를 정리한다.

## 검증 결과와 남은 한계

- 고정된 provider 6.70.0으로 fmt/validate, mock 테스트 총 5개 통과. mock은 AWS API, IAM과 부트스트랩 성공을 검증하지 않는다.
- VPC가 없는 실제 계정에서 기본 plan은 14개 생성, 예시 접근 값과 EKS 활성화 plan은 39개 생성·변경/삭제 0개다. network 모듈이 끝나야 EKS 쪽 데이터 조회가 이루어지도록 의존성을 두었으므로 EKS add-on 조회 및 실행 권한은 이 plan만으로 확인할 수 없다.
- 사용자 `nerdnam-infra`의 `eks:DescribeClusterVersions` 호출은 AccessDenied였다. 다른 EKS/IAM/ECR 권한은 전수 확인하지 않았다. 실제 EKS apply 및 3노드 Ready·통신/PVC 검증은 실행하지 않았다.
- CoreDNS는 기본 설정을 사용한다. platform taint에 대한 toleration과 app/platform 분산은 기본값으로 보장되지 않으며 실제 설정 검토·적용이 남았다. 현재 1대 장애에도 서비스 전체가 영향받을 수 있다.
- EBS CSI 역할은 AWS 관리형 `AmazonEBSCSIDriverPolicy`를 사용한다. 서비스 계정과 역할은 분리하지만 정책은 최소 권한으로 검증하지 않았다. 노드 루트 디스크와 업무 PVC의 삭제·보존 정책은 서로 다르다.

근거: [EKS 버전 수명주기](https://docs.aws.amazon.com/eks/latest/userguide/kubernetes-versions.html), [노드 및 CNI IAM 역할](https://docs.aws.amazon.com/eks/latest/userguide/create-node-role.html), [add-on Pod Identity](https://docs.aws.amazon.com/eks/latest/userguide/add-ons-iam.html), [관리형 노드 그룹 네트워크](https://docs.aws.amazon.com/eks/latest/userguide/managed-node-groups.html).
