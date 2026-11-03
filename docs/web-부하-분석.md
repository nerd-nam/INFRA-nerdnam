# web 부하 한도와 재시작 분석 (2026-11-03 rate 시험)

기준일: 2026-11-03. 부하 시험 `rate`(초당 반복 25 → 50 → 100 → 150)에서 web(Next.js)이 한도에 닿아 응답이 9초까지 느려지고, liveness 실패로 **재시작**해 502·503 이 났다. 같은 시간 Grafana 도 메모리 부족으로 3번 재시작했다. 무엇이 일어났고 왜 그랬는지, 무엇을 바꿨는지 정리한다.

## 1. 요약

| 항목 | 내용 |
| --- | --- |
| 시험 | `scripts/load-test.sh run rate` (TestRun `rate-bpjnp`, 05:02:59~05:08:58 UTC). 반복 1번 = `/`(web) + `/api/auth/csrf` + `/api/projects`(401) |
| 한도 | **web Pod 하나 = 약 115 요청/초**(서버 렌더링). 전체 요청으로는 약 300~350/초. api 는 끝까지 p95 25ms |
| 증상 | 마지막 단계에서 web p95 9.2초, 실패 2.5%(모두 web: 503 약 9/초·502 약 4/초), 못 보낸 반복 1,470 |
| 직접 원인 | web 메인 스레드(Node.js)가 꽉 참 → `/healthz` 도 3초 안에 답 못 함 → **liveness 3회 실패 → 컨테이너 재시작**(05:08:20, exit 143) → 재시작 중 502·503 |
| 같이 생긴 문제 | Grafana OOMKilled 3회(부하 대시보드 조회로 메모리 512Mi 상한 도달). 부하 대시보드 시험 선택이 비어 있음(k6-operator 가 붙이는 태그 때문에 `testid`·`mode` 라벨이 없음) |
| 조치 | web: **HPA 1~2개**(metrics-server), CPU 요청 100m→500m, liveness 완화(10초×6). quota 2→3코어. 후속: Grafana 메모리·부하 대시보드 |

## 2. 단계별 측정 (각 단계 유지 구간 끝, Prometheus)

| 단계(초당 반복) | 전체 요청/초 | web 처리(200)/초 | web p95 | api p95 | 실패 | web CPU | app 노드 남는 CPU |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 25 | 75 | 25 | 20ms | 6ms | 0 | 0.39 | 3.2코어 |
| 50 | 151 | 50 | 21ms | 5ms | 0 | 0.67 | 2.7코어 |
| 100 | 300 | 100 | 70ms | 6ms | 0 | 1.38 | 1.5코어 |
| 150 | 398 | **약 115에서 멈춤** | **9.2초** | 25ms | 503·502 | **1.72** | **1.4코어** |

- web 요청 1건당 CPU 는 약 14~15ms 로 일정했다(메인 스레드 렌더링 + GC·압축 보조 스레드).
- k6 부하 발생기는 한계가 아니었다(k6 Pod CPU 0.15코어).
- web 메모리는 최대 281Mi(상한 512Mi) — 메모리 문제는 아니다.

## 3. 왜 115/초·1.7코어에서 멈췄나

- web 컨테이너 안에는 Node.js 프로세스(`next-server`) 하나, 스레드 11개가 있다: **메인 스레드 1**(JavaScript·서버 렌더링 전부), `V8Worker` 4(GC·최적화 컴파일), `libuv-worker` 4(gzip 압축 등), 기타 2.
- 요청을 실제로 처리하는 건 메인 스레드 하나다. 요청 1건에 메인 스레드 약 8~9ms → **초당 약 115건이 최대**.
- 보조 스레드는 메인 스레드가 처리한 만큼만 일이 생긴다. 그래서 CPU 합계 = 115건 × 약 15ms ≈ **1.7코어**에서 같이 멈췄다.
- CPU 상한은 없었고 노드에도 1.4코어가 남아 있었다. "1.7코어까지만 쓸 수 있어서"가 아니라 **"메인 스레드 하나로 처리할 수 있는 양이 1.7코어어치"** 다. 처리량을 늘리려면 프로세스(Pod)를 늘려야 한다.

## 4. 왜 재시작했나 (05:08 UTC)

1. 처리 능력보다 많은 요청 → 메인 스레드 앞 대기열이 수 초로 길어짐.
2. `/healthz`(가벼운 상태 확인)도 같은 대기열에 섬 → liveness(20초 간격, 3초 제한, 3회) 실패: `Liveness probe failed: context deadline exceeded`.
3. kubelet 이 "멈췄다"고 판단 → SIGTERM → 재시작(exit 143). 메모리 부족(OOMKilled)이나 프로그램 오류가 아니다.
4. 재시작 동안: 처리 중 연결이 끊김(**502**), 받을 Pod 가 없음(**503**, `connection refused`).

**느려진 것**(과부하)과 **멈춘 것**(먹통)을 liveness 가 구분하지 못했다. 바쁠 때는 readiness 가 잠시 트래픽에서 빼고, liveness 는 정말 오래 먹통일 때만 재시작해야 한다.

## 5. 같이 드러난 문제

| 문제 | 원인 | 처리 |
| --- | --- | --- |
| Grafana 3번 재시작(05:03:57, 05:05:57, 05:11:57) | 부하 대시보드(패널 18개, 10초마다 새로 고침)를 여는 순간 메모리 240→510Mi, 상한 512Mi 에서 OOMKilled | 후속: 메모리 상한 1Gi, 부하 대시보드 새로 고침 30초 |
| 부하 대시보드 "시험" 선택·VU 패널이 빔 | k6-operator 가 `--tag instance_id --tag testrun_name` 으로 실행 → k6 는 명령줄 태그가 있으면 스크립트 `options.tags`(testid·mode)를 쓰지 않는다. 클러스터 지표에는 `testrun_name` 만 있다 | 후속: 대시보드·`load-test.sh` 링크를 `testrun_name` 기준으로 |
| web CPU 요청 100m | 실제 0.4~1.7코어. 스케줄러가 여유를 잘못 계산하고 HPA 기준(요청 대비 %)으로 쓸 수 없다 | 500m 로 |

## 6. 조치: web HPA (1~2개)

| 항목 | 이전 | 이후 | 이유 |
| --- | --- | --- | --- |
| replica | 1 고정 | **HPA 1~2** | 처리량 = Pod 수. app 노드 1대(3.92코어)라 최대 2 |
| HPA 기준 | — | CPU 요청 대비 평균 **120%**(≈ 0.6코어 ≈ web 요청 45/초) | 늘어나는 데 약 1분(지표 15~30초 + 판단 15초 + 기동). 한계(115/초) 훨씬 앞에서 늘린다 |
| 늘리기·줄이기 | — | 늘리기 즉시(15초마다 1개), 줄이기 5분 안정 후 1개씩 | 몰림에 빨리, 오르내림 반복 방지 |
| CPU 요청 | 100m | **500m** | 평소 사용량에 맞추고 HPA 기준으로 씀. 상한은 계속 없음 |
| liveness | 20초×3, 3초 제한(약 1분) | **20초×6, 10초 제한(약 2분)** | 과부하로 느린 것을 멈춤으로 보지 않게. readiness(10초, 3초 제한)는 그대로 빨리 뺀다 |
| Deployment `replicas` | 1 | **없음** | HPA 가 정한다. 있으면 Argo sync 때마다 HPA 값을 덮어쓴다 |
| nerdnam quota CPU 요청 | 2 | **3** | web 2 + 롤링 업데이트 1(500m×3) + api·ai·sample |
| metrics-server | 없음 | **EKS add-on v0.9.0-eksbuild.14**, platform 노드 | HPA 가 Pod CPU 를 읽는 API(metrics.k8s.io). `kubectl top` 도 된다 |

- 팀 결정 변경: 처음 계획은 "HPA·노드 자동 확장 없음, replica 1"([EKS-배포-계획.md](EKS-배포-계획.md))이었다. web 은 메인 스레드 한도 때문에 Pod 수로만 처리량이 늘어 HPA 를 도입한다. 다른 앱(api·ai)과 노드 수는 그대로 고정이다.
- 검토한 대안: **항상 2개**(새 구성 요소 없음, 몰림 전부터 2배, 재시작·배포 중 무중단). HPA 는 몰리기 시작해 약 1분 동안 Pod 1개가 받는다. 그래서 HPA 와 함께 liveness 를 완화했다(그 1분 동안 재시작하지 않도록).
- HPA 가 더 맞아지는 때: 노드를 여러 대로 늘리거나 노드 자동 확장(Karpenter 등)을 붙일 때, web 이 3개 이상 필요할 때. 그때는 maxReplicas·quota·노드 용량을 같이 올린다.

변경 파일: `modules/eks/main.tf`(metrics-server add-on), `gitops/apps/values.yaml`·`templates/workloads.yaml`(HPA·자원·probe·quota), `scripts/validate_gitops.py`(HPA 는 web 만, max 2, 요청·liveness·quota·용량 검사), `tests/*.tftest.hcl`.

## 7. 확인 방법 (배포 후)

```sh
kubectl --context nerdnam-dev top pods -n nerdnam                      # metrics-server 동작
kubectl --context nerdnam-dev -n nerdnam get hpa web                   # TARGETS 가 <unknown> 이 아니면 정상
scripts/load-test.sh run rate                                           # 같은 시험을 다시
kubectl --context nerdnam-dev -n nerdnam get hpa web -w                # 시험 중 REPLICAS 1 → 2
```

기대: 50 단계 무렵 web 2개로 늘어남, 150 단계 web 처리 약 115/초 → 약 230/초 근처, 재시작 없음. 결과는 이 문서 8절에 덧붙인다.

## 8. 재시험 결과

(배포 후 기록)
