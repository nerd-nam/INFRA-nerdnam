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
| Grafana 3번 재시작(05:03:57, 05:05:57, 05:11:57) | 부하 대시보드(패널 18개, 10초마다 새로 고침)를 여는 순간 메모리 240→510Mi, 상한 512Mi 에서 OOMKilled. 시험 변수 기본값 "All"(`testid=~".*"`)이 라벨 없는 모든 k6 시계열과 맞아 조회가 컸다 | 처리: 메모리 상한 1Gi(요청 256Mi), 새로 고침 30초, 시험 변수 "All" 없앰(아래 줄) |
| 부하 대시보드 "시험" 선택·VU 패널이 빔 | k6-operator 가 `--tag instance_id --tag testrun_name` 으로 실행 → k6 는 명령줄 태그가 있으면 스크립트 `options.tags`(testid·mode)를 쓰지 않는다. 클러스터 지표에는 `testrun_name` 만 있다 | 처리: 시험 변수를 `testrun_name`(최근 순)으로, VU 패널은 이름 앞부분으로, `load-test.sh` 링크도 TestRun 이름으로 |
| web CPU 요청 100m | 실제 0.4~1.7코어. 스케줄러가 여유를 잘못 계산하고 HPA 기준(요청 대비 %)으로 쓸 수 없다 | 500m 로 |

## 6. 조치: web HPA (1~2개)

| 항목 | 이전 | 이후 | 이유 |
| --- | --- | --- | --- |
| replica | 1 고정 | **HPA 1~2** | 처리량 = Pod 수. app 노드 1대(3.92코어)라 최대 2 |
| HPA 기준 | — | CPU 요청 대비 평균 **120%**(≈ 0.6코어 ≈ web 요청 45/초). 재시험 뒤 **100%**(≈ 0.5코어)로 낮춤(8절) | 늘어나는 데 약 1분(지표 15~30초 + 판단 15초 + 기동). 한계(115/초) 훨씬 앞에서 늘린다 |
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

## 8. 재시험 결과 (2026-11-03 06:38 UTC, TestRun `rate-dr75l`, HPA 1~2 적용 후)

| 단계(초당 반복) | web 처리/초 | api 요청/초 | web p95 | api p95 | 실패 | web Pod(CPU) | app 노드 남는 CPU |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 25 | 25 | 50 | 20ms | 10ms | 0 | 1개(0.34) | 3.2코어 |
| 50 | 50 | 100 | 20ms | 10ms | 0 | 1개(0.65) | 2.7코어 |
| 100 | 100 | 200 | 70ms | 10ms | 0 | **2개**(0.73 + 0.82) | 1.2코어 |
| 150 | **119** | 235 | 3.46초 | 2.44초 | `/api/projects` **500 약 16.5/초** | 2개(0.71 + 1.02) | **0.2코어** |

k6 전체: 요청 72,984, 실패 3.0%(전부 `/api/projects` 500), 못 보낸 반복 1,672, web `/` 실패 **0**.

**좋아진 것**

- web 재시작 0, web 502·503 0(이전: 재시작 1회, `/` 실패 8%). liveness 완화가 효과.
- HPA 가 web 을 2개로 늘렸다(06:41:32 생성, 06:41:43 replica 2).

**새로 드러난 것**

1. **한계가 web Pod → app 노드 CPU 로 옮겨 갔다.** 마지막 단계에서 app 노드(3.92코어)에 0.2코어만 남았다(web 2개 + api + traefik + coredns 등). web 처리량은 115 → 119/초로 거의 늘지 않았다 — Pod 를 늘려도 노드 CPU 가 다 차서 Pod 마다 받는 CPU 가 줄었다. **지금 app 노드 1대의 한계는 초당 반복 약 110~120(요청 약 330~360/초)** 이다.
2. **HPA 가 기준을 넘고 약 1분 뒤에 늘렸다.** 06:40:28 에 122%/120% 였지만 HPA 는 기준에서 10% 넘게 벗어나야(허용 오차) 움직여 132% 를 넘은 06:41:32 에야 늘렸다. 더 일찍 늘리려면 기준을 100%(0.5코어) 정도로 낮춘다.
3. **BE 가 `/api/projects`(비로그인 401 경로)에 500 을 돌려줬다(약 7%). 원인은 Redis 메모리 가득 참이다(9절).** BE 로그(Loki): `RedisSystemException … OOM command not allowed when used memory > 'maxmemory'`. Spring Security 가 401 때 원래 요청을 세션에 저장하는데, 그 세션 쓰기가 거절됐다. (처음엔 `kubectl logs` 가 비어 원인을 못 찾았고 Loki 에서 찾았다.)

**다음 후보**

| 후보 | 효과 | 비용·영향 |
| --- | --- | --- |
| HPA 기준 120% → 100% (**적용**, 같은 PR) | 약 1분 일찍 늘어남(실제로는 110% 에서 늘어난다) | 없음 |
| **BE: 비로그인 API 요청이 세션을 만들지 않게**(BE 이슈, 9절) | 500·Redis 가득 참 제거. 실제 서비스 장애 원인 | BE 작업 |
| app 노드 m7i.xlarge → m7i.2xlarge(8코어) | 노드 CPU 한계 2배, web 2개가 제 성능 | 시간당 비용 약 2배(app 노드만) |
| FE `/` 첫 화면 캐시 | 요청당 CPU 감소(가장 큰 효과) | FE 작업 |

## 9. 장애: Redis 가득 참으로 로그인 사용자 화면 500 (2026-11-03)

| 시각(UTC) | 일 |
| --- | --- |
| 11-02 ~ 11-03 05:09 | 부하 시험(smoke·rate) 들이 비로그인 `/api/projects` 를 반복 → 세션 6.6만 개 누적 |
| 06:38 ~ 06:44 | rate 재시험(`rate-dr75l`) → 세션 4.4만 개 추가, **06:44 Redis 256MiB(상한) 도달** |
| 06:43 ~ | BE 가 세션 쓰기에서 `OOM command not allowed` → 500. 로그인한 사용자 화면(web 서버 렌더링 → BE)이 에러 |
| (발견) | 사용자가 `https://nerdnam.click/` 에러 보고 |
| 정리 | 로그인 정보(`SPRING_SECURITY_CONTEXT`)가 없는 세션 110,660 개 삭제, 로그인 세션 3 개 유지 → Redis 256MiB → 1.87MiB, 메인 200·비로그인 API 401 복구, BE OOM 오류 0 |

**원인**

1. Spring Security 는 로그인 안 한 요청이 보호된 경로(`/api/**`)에 오면 401 을 주면서 **원래 요청을 세션에 저장**한다(`SPRING_SECURITY_SAVED_REQUEST`, RequestCache). 로그인 뒤 돌아가기 위한 기본 동작이다.
2. 세션 수명이 **7일**(`spring.session.timeout: 7d`)이라 그 세션이 Redis 에 7일 남는다.
3. 그래서 **비로그인 API 요청 1번 = 7일짜리 세션 1개**. 부하 시험(반복마다 `/api/projects`)으로 11만 개가 쌓였다. Redis 는 `noeviction` 이라 가득 차면 모든 쓰기를 거절한다.
4. 로그인한 사용자도 요청마다 세션의 마지막 접근 시각을 쓰므로, Redis 가 가득 차면 **로그인·로그인 후 사용이 모두 500** 이 된다. 세션이 7일 남아 **저절로 풀리지 않는다**.

부하 시험만의 문제가 아니다. 누구든 비로그인으로 API 를 반복해서 부르면 같은 장애가 난다(쉽게 서비스를 마비시킬 수 있는 구멍).

**조치·후속**

| 항목 | 상태 |
| --- | --- |
| 비로그인 세션 정리 | 완료(위) |
| BE: `/api/**` 401 때 요청을 세션에 저장하지 않음(`NullRequestCache` 등), 비로그인 요청이 세션을 만들지 않게 | BE 이슈 |
| 부하 시험 | BE 수정 전까지 돌리지 않는다(돌리면 다시 쌓인다) |
| 알림 | 동작함: `NerdnamRedisRejectingWrites` 06:45 부터(쓰기 거절 직후), `NerdnamRedisMemoryHigh` 06:53 부터(10분 지속 조건) firing, Discord 전송 실패 0. 알림은 장애 1~2분 만에 갔지만 조치는 사용자 보고 뒤에 했다 — Discord 채널 확인을 운영 습관으로 |
