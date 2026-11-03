# AI 작업 큐 Redis (ADR-0009)

기준일: 2026-11-03. AI 작업을 Redis Streams 큐로 보내는 구조(SPEC ADR-0009)의 INFRA 몫이다. 이슈 #32, 결정은 SPEC #101·BE #67·AI #52·#53, AI 구현은 AI #54.

## 1. 구조

```text
api(BE, nerdnam) ──XADD ai:req:{llm|embed|embed-bg}──▶ redis-queue (data) ◀──XREADGROUP── ai(nerdnam)
api ◀──XREAD ai:res:{BE Pod 이름}────────────────────── redis-queue ◀──XADD (reply_to)── ai
```

| 항목 | 값 | 이유 |
| --- | --- | --- |
| 배치 | data namespace, data 노드, Deployment 1개(Recreate) | 세션 Redis(`data/redis`)와 분리. 큐가 밀려도 로그인 세션 쓰기가 실패하지 않게 |
| 디스크 | **없음**(PVC 없음, `appendonly no`, `save ""`) | 요청 본문에 이력 원문이 있다. 재시작하면 메시지가 사라지고 BE 가 같은 `id` 로 다시 넣는다 |
| 메모리 | `maxmemory 256mb`, `noeviction`, 컨테이너 요청 320Mi·상한 512Mi | 넘쳐도 작업을 지우지 않는다. 꽉 차면 `XADD` 실패 → BE 가 그 작업을 `GPU_UNAVAILABLE` 로 끝낸다 |
| 정리 | 처리한 쪽이 `XDEL`(요청 = AI, 결과 = BE + 키 만료 1시간) | Streams 는 `XACK` 해도 메시지를 지우지 않는다. 안 지우면 256MB 에 닿는다(SPEC #101) |
| 지표 | `redis-queue-exporter`(redis_exporter, 세션과 같은 이미지) | 메모리·접속·쓰기 거부 알림 |

`cluster.sh down` 으로 노드를 내리면 큐 내용은 사라진다(디스크 없음). 이때 진행 중이던 작업은 BE 가 다시 넣거나 `TIMEOUT` 으로 끝낸다.

## 2. 계정과 권한 (ACL)

`gitops/data/files/redis-queue-start.sh`. 명령은 쓰는 것만 연다(`+@all` 없음, 검증 스크립트가 막는다).

| 사용자 | 키 | 명령 |
| --- | --- | --- |
| `api` | `ai:req:*`, `ai:res:*` | `XADD`·`XLEN`(요청 넣기·접수 거절), `XREAD`·`XDEL`·`EXPIRE`(자기 결과 읽고 지우기) |
| `ai` | `ai:req:*`, `ai:res:*`(**쓰기만**), `ai:run:*` | `XGROUP CREATE`·`XREADGROUP`·`XACK`·`XDEL`·`XAUTOCLAIM`·`XCLAIM`·`XLEN`·`XINFO GROUPS`·`MULTI`/`EXEC`/`DISCARD`(꺼내기·회수·`XACK`+`XDEL`·lag), `XADD`·`EXPIRE`(결과), `SET`(같은 `id` 한 번만 실행: `NX EX GET` 선점, `XX EX` 연장, `done` 표시) |
| `exporter` | 없음 | 상태 조회만(`INFO` 등) |
| 공통 | — | `PING`·`HELLO`·`CLIENT SETNAME/SETINFO/ID`(클라이언트 연결) |
| `default` | — | 꺼짐 |

2026-11-03 Redis 7.4.12 이미지로 AI #54 의 호출 순서를 흉내 내 확인했다: 위 명령은 되고, api 의 `XREADGROUP`·`SET nerdnam:*`·`KEYS`, ai 의 `XPENDING`·`GET`·`DEL`·`FLUSHALL`·`CONFIG`·`XRANGE ai:res:*`(결과 읽기) 는 `NOPERM`.

- `SET … NX GET` 은 키를 읽기도 하므로 `ai:run:*` 은 읽기·쓰기 키 권한이다(명령은 `SET` 뿐).
- AI 작업자를 2대 이상으로 늘리면 연장·완료 표시를 "내 작업자 값일 때만"(Lua) 바꾸기로 했다(AI #52). 그때 `EVALSHA`·`SCRIPT LOAD` 를 연다.

## 3. 네트워크

| 경로 | 정책 |
| --- | --- |
| api → redis-queue:6379 | `allow-api-to-data`(nerdnam, Egress), `allow-api-to-redis-queue`(data, Ingress) |
| ai → redis-queue:6379 | `allow-ai-to-redis-queue`(nerdnam Egress·data Ingress). **AI 는 PostgreSQL·세션 Redis 에는 닿지 않는다**(검증 스크립트가 확인) |
| redis-queue-exporter → redis-queue, Prometheus → exporter | `allow-exporter-to-redis-queue`, `redis-queue-exporter` |

## 4. 비밀값

`nerdnam/dev/data` 가 단일 출처다(세션 Redis 와 같은 방식). BE 는 그중 자기 키만 `backend-secrets` 로 받는다.

| Secrets Manager `nerdnam/dev/data` 키 | 쓰는 곳 |
| --- | --- |
| `redis-queue-api-password` | 큐 Redis `api` 사용자, BE `AI_QUEUE_REDIS_PASSWORD`(backend-secrets) |
| `redis-queue-ai-password` | 큐 Redis `ai` 사용자, AI `AI_QUEUE_REDIS_PASSWORD`(ai-secrets, AI 가 받는 유일한 data 키) |
| `redis-queue-exporter-password` | `redis-queue-exporter`, 큐 Redis probe |

환경 변수는 BE·AI 가 같은 이름이다(BE #67, AI #52). `gitops/apps/values.yaml` 의 `api.aiQueue`·`ai.aiQueue`.

| 이름 | api | ai |
| --- | --- | --- |
| `AI_QUEUE_ENABLED` | `false`. 켜면 AI 호출을 큐로 보낸다 | `false`. 켜면 큐 작업자를 띄운다(HTTP 경로는 켜든 끄든 계속 받는다) |
| `AI_QUEUE_REDIS_HOST`·`_PORT` | `redis-queue.data.svc.cluster.local`, `6379` | 같음 |
| `AI_QUEUE_REDIS_USERNAME` | `api` | `ai` |
| `AI_QUEUE_REDIS_PASSWORD` | backend-secrets ← `redis-queue-api-password` | ai-secrets ← `redis-queue-ai-password`(`optional`: 키가 없어도 AI 는 HTTP 경로로 뜬다) |

**켜는 순서**: ai `true`(작업자가 소비자 그룹을 만들고 기다림) → api `true`. 반대로 하면 BE 가 넣은 작업을 꺼낼 작업자가 없다(BE 가 20분 뒤 `TIMEOUT`). 되돌릴 때는 api 먼저 `false`.

## 5. 처음 배포

1. **Secrets Manager 에 키 3개 추가**(먼저 해야 한다): AWS 콘솔 → Secrets Manager → `nerdnam/dev/data` → 보안 암호 값 편집 → 키/값 추가.
   - `redis-queue-api-password`, `redis-queue-ai-password`, `redis-queue-exporter-password`
   - 값은 각각 다른 긴 임의 문자열(예: `openssl rand -hex 32`, 특수문자 없음). 기존 키는 그대로 둔다. Git·채팅·로그에 남기지 않는다.
   - 빠뜨리면: `backend-secrets` ExternalSecret 이 오류로 갱신을 멈추고(기존 값은 유지), `redis-queue` Pod 가 `CreateContainerConfigError` 로 뜨지 않는다.
   - **키를 넣은 뒤 바로 클러스터로 가져온다.** ExternalSecret 은 1시간마다 갱신하므로, 그대로 두면 최대 1시간 동안 새 키가 Secret 에 없다(2026-11-03 첫 배포에서 `redis-queue`·`redis-queue-exporter` 가 `couldn't find key redis-queue-…-password` 로 약 1시간 뜨지 못했다).

     ```sh
     kubectl --context nerdnam-dev -n data annotate externalsecret data-secrets force-sync=$(date +%s) --overwrite
     kubectl --context nerdnam-dev -n nerdnam annotate externalsecret backend-secrets ai-secrets force-sync=$(date +%s) --overwrite
     # 키 이름만 확인(값은 보지 않는다). redis-queue-* 3개가 보여야 한다
     kubectl --context nerdnam-dev -n data get secret data-secrets -o go-template='{{range $k,$v := .data}}{{$k}}{{"\n"}}{{end}}'
     ```

     `SecretSynced` 는 "마지막 갱신이 성공했다"는 뜻이라 새 키가 들어왔는지는 알려 주지 않는다. 키 이름으로 확인한다. 이미 `CreateContainerConfigError` 인 Pod 는 키가 들어오면 kubelet 이 다시 시도해 저절로 뜬다.
2. **Argo CD sync**(PR merge 후, 순서대로)
   - `nerdnam-secrets` → `kubectl -n nerdnam get externalsecret backend-secrets`, `kubectl -n data get externalsecret data-secrets` 가 `SecretSynced`
   - `nerdnam-data` → `redis-queue`, `redis-queue-exporter` Running, 네트워크 정책 추가
   - `nerdnam-apps` → api 에 `AI_QUEUE_*` 환경 변수(꺼짐). api Pod 가 한 번 다시 뜬다
   - `nerdnam-observability` → ServiceMonitor·알림·대시보드
3. **확인**

```sh
kubectl --context nerdnam-dev -n data get pods -l 'app in (redis-queue,redis-queue-exporter)'
kubectl --context nerdnam-dev -n data exec deploy/redis-queue -- sh -c 'redis-cli --user exporter ping; redis-cli --user exporter info persistence | grep -E "aof_enabled|rdb_changes"'
#   PONG / aof_enabled:0
kubectl --context nerdnam-dev -n nerdnam exec deploy/api -- env | grep ^AI_QUEUE_ | grep -v PASSWORD
```

Prometheus 에서 `redis_up{job="redis-queue-exporter"}` 가 1, Grafana "nerdnam AI 장애 재현" → "2-1. AI 작업 큐" 의 큐 Redis 메모리가 몇 % 로 보이면 된다(단계별 대기·밀린 작업 패널은 AI 큐 작업자가 나온 뒤 채워진다).

## 6. 알림

| 알림 | 조건 |
| --- | --- |
| `NerdnamRedisDown` | Redis 별(`job`)로 2분 수집 실패. `redis-exporter` = 세션(로그인 실패), `redis-queue-exporter` = 큐(AI 작업 실패) |
| `NerdnamRedisMemoryHigh` | Redis 별로 메모리 80% 초과 10분 |
| `NerdnamRedisRejectingWrites` | Redis 별로 OOM 쓰기 거부 |
| `NerdnamRedisAofWriteFailed` | 세션 Redis 만(큐는 AOF 없음) |
| `NerdnamAiQueueStuck` | 안 꺼낸 메시지(`nerdnam_ai_queue_lag`)가 30분(embed-bg 60분) 동안 0 이 되지 않고, 지금이 그때보다 많거나 같음 → 작업자가 멈췄거나 모자람(SPEC #101) |
| `NerdnamAiQueuePendingStuck` | 꺼냈지만 안 끝난 메시지(`nerdnam_ai_queue_pending`)가 같은 조건 → 처리 중 멈춤·회수 문제(AI #52). 30분 넘게 쉬지 않고 몰리면 정상이어도 울릴 수 있다 |
| `NerdnamAiQueueDown` | 큐 작업자가 큐 Redis 에 5분째 접속 못 함(`nerdnam_ai_queue_up == 0`). `queue_up` 은 작업자를 꺼도 0 으로 나와서, 작업자가 큐 지표를 낸 적이 있을 때만 본다 |

이전에는 Redis 알림이 `max(redis_up) == 0` 처럼 Redis 하나를 가정해, 둘 중 하나만 죽으면 울리지 않았다.

## 7. 남은 것

| 할 일 | 기다리는 것 |
| --- | --- |
| 큐 지표 이름을 실제 출력으로 다시 확인(`tests/fixtures/metrics/ai.txt`, 지금은 AI #54 코드 기준) | AI #54 배포 |
| `AI_QUEUE_ENABLED=true`(ai → api 순서) | AI #54 + BE #68 배포 |
| 운영 재시험(`ai-guide`·`ai-analysis`, #19 와 같은 부하) | 위 전부 |
| `maxmemory` 조정 | 재시험 lag·메모리 |
