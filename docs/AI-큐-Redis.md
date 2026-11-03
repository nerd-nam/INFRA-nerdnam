# AI 작업 큐 Redis (ADR-0009)

기준일: 2026-11-03. AI 작업을 Redis Streams 큐로 보내는 구조(SPEC ADR-0009)의 INFRA 몫이다. 이슈 #32, 결정은 SPEC #101·BE #67·AI #52·#53.

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
| `ai` | `ai:req:*`, `ai:res:*`, `ai:run:*` | `XREADGROUP`·`XACK`·`XAUTOCLAIM`·`XCLAIM`·`XGROUP CREATE`·`XDEL`·`XLEN`·`XPENDING`·`XINFO GROUPS/STREAM`(꺼내기·회수·lag), `XADD`(결과), `SET`·`GET`·`DEL`·`EXPIRE`(같은 `id` 한 번만 실행, AI #53) |
| `exporter` | 없음 | 상태 조회만(`INFO` 등) |
| 공통 | — | `PING`·`HELLO`·`CLIENT SETNAME/SETINFO/ID`(클라이언트 연결) |
| `default` | — | 꺼짐 |

2026-11-03 Redis 7.4.12 이미지로 확인했다: 위 명령은 되고, api 의 `XREADGROUP`·`SET nerdnam:*`·`KEYS`, ai 의 `FLUSHALL`·`CONFIG` 는 `NOPERM`.

`ai:run:*`·`XCLAIM` 은 AI #53 제안(중복 실행 막기)을 미리 연 것이다. AI 가 다르게 정하면 맞춘다.

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
| `redis-queue-ai-password` | 큐 Redis `ai` 사용자. AI 접속 설정 이름이 정해지면(AI #52) ai-secrets 로도 넘긴다 |
| `redis-queue-exporter-password` | `redis-queue-exporter`, 큐 Redis probe |

BE 환경 변수(BE #67, `gitops/apps/values.yaml` `api.aiQueue`):

| 이름 | 값 |
| --- | --- |
| `AI_QUEUE_ENABLED` | `false`(기본). AI 큐 작업자를 배포한 뒤 켠다 |
| `AI_QUEUE_REDIS_HOST`·`_PORT`·`_USERNAME` | `redis-queue.data.svc.cluster.local`, `6379`, `api` |
| `AI_QUEUE_REDIS_PASSWORD` | backend-secrets ← `nerdnam/dev/data` `redis-queue-api-password` |

## 5. 처음 배포

1. **Secrets Manager 에 키 3개 추가**(먼저 해야 한다): AWS 콘솔 → Secrets Manager → `nerdnam/dev/data` → 보안 암호 값 편집 → 키/값 추가.
   - `redis-queue-api-password`, `redis-queue-ai-password`, `redis-queue-exporter-password`
   - 값은 각각 다른 긴 임의 문자열(예: `openssl rand -base64 32`). 기존 키는 그대로 둔다. Git·채팅·로그에 남기지 않는다.
   - 빠뜨리면: `backend-secrets` ExternalSecret 이 오류로 갱신을 멈추고(기존 값은 유지), `redis-queue` Pod 가 `CreateContainerConfigError` 로 뜨지 않는다.
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
| `NerdnamAiQueueStuck` | `nerdnam_ai_queue_lag` 가 30분(embed-bg 60분) 동안 0 이 되지 않고, 지금이 그때보다 많거나 같음(SPEC #101) |

이전에는 Redis 알림이 `max(redis_up) == 0` 처럼 Redis 하나를 가정해, 둘 중 하나만 죽으면 울리지 않았다.

## 7. 남은 것

| 할 일 | 기다리는 것 |
| --- | --- |
| ai Deployment 에 큐 Redis 접속 설정(환경 변수·ai-secrets) | AI #52 이름 결정 |
| `nerdnam_ai_queue_lag`·`nerdnam_ai_stage_seconds` 이름을 실제 출력으로 다시 확인(`tests/fixtures/metrics/ai.txt`) | AI 큐 작업자 이미지 |
| `AI_QUEUE_ENABLED=true` | AI 작업자 배포 + BE #68 배포 |
| 운영 재시험(`ai-guide`·`ai-analysis`, #19 와 같은 부하) | 위 전부 |
| `maxmemory` 조정 | 재시험 lag·메모리 |
