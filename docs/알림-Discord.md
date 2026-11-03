# 알림 → Discord

기준일: 2026-11-03. Alertmanager 알림을 Discord 채널(웹훅)로 보낸다. 웹훅 URL 은 Secrets Manager 에만 두고 Git·설정에 남기지 않는다.

## 1. 구조

```text
Prometheus 알림 규칙(firing) → Alertmanager (monitoring, platform 노드)
  → route: critical·warning → receiver discord (discord_configs, webhook_url_file)
  → NAT → Discord 웹훅 → 채널
웹훅 URL: Secrets Manager nerdnam/dev/monitoring 의 키 alertmanager-discord-webhook-url
  → ExternalSecret alertmanager-discord (그 키 하나만) → Secret alertmanager-discord(webhook-url)
  → Alertmanager Pod 의 /etc/alertmanager/discord/webhook-url (볼륨 optional)
```

| 파일 | 내용 |
| --- | --- |
| `gitops/root/configs/kube-prometheus-stack.yaml` | `alertmanager.config`(route·receiver), `templateFiles.discord.tmpl`(한국어 메시지), Alertmanager 볼륨 |
| `gitops/secrets/templates/external-secrets.yaml` | ExternalSecret `alertmanager-discord` |
| `scripts/validate_gitops.py` | URL 이 설정에 직접 없고 파일로만 읽는지, 볼륨·Secret·키 이름이 이어지는지, Watchdog 을 보내지 않는지 |

## 2. 무엇을 보내나

| 알림 | 보냄 | 반복 |
| --- | --- | --- |
| `severity=critical` | ✅ + 해결(resolved) | 계속 울리면 4시간마다 |
| `severity=warning` | ✅ + 해결 | 12시간마다 |
| `severity=info`, `Watchdog`(늘 울리는 생존 신호), `InfoInhibitor` | ❌ | — |

- 같은 알림 이름·namespace 끼리 묶어 보낸다(처음 30초 모아서, 이후 5분 간격으로 변화만).
- critical 이 울리면 같은 이름의 warning·info 는 가린다(차트 기본 inhibit 규칙).
- 메시지: 제목 `[발생 N건] <알림> · <심각도>` / `[해결] …`, 본문에 알림별 namespace·Pod·요약·시작(해결) 시각(UTC), Grafana 주소.
- nerdnam 고유 알림: `NerdnamApiDown`·`NerdnamAiDown`(critical), `NerdnamApiLatencyHigh`·`NerdnamBedrock*`·`NerdnamAiJob*`·`NerdnamPostgres*`·`NerdnamRedis*` 등(`gitops/observability/templates/rules.yaml`). 나머지는 kube-prometheus-stack 기본 규칙(노드·Pod·PVC 등).

## 3. 처음 한 번 준비

1. **Discord 웹훅 만들기**: 알림 받을 채널 → 채널 편집(톱니) → 연동(Integrations) → 웹후크 → 새 웹후크 → 이름(예: `nerdnam-alert`) → **웹후크 URL 복사**
2. **Secrets Manager 에 넣기**: AWS 콘솔 → Secrets Manager → `nerdnam/dev/monitoring` → 보안 암호 값 검색 → 편집 → **키/값 추가**: 키 `alertmanager-discord-webhook-url`, 값 = 복사한 URL → 저장. (기존 `grafana-admin-*` 키는 그대로 둔다. URL 을 Git·채팅·로그에 남기지 않는다.)
3. **배포**(PR merge 후, Argo CD 에서 순서대로 sync)
   - `nerdnam-secrets` → ExternalSecret `alertmanager-discord` 가 Secret 을 만든다(`kubectl -n monitoring get externalsecret alertmanager-discord` 가 `SecretSynced`)
   - `kube-prometheus-stack` → Alertmanager 설정·볼륨 반영(Pod 재시작 1번)
   - 순서가 바뀌거나 2번을 아직 안 해도 Alertmanager 는 뜬다(볼륨 optional). 그때는 알림만 안 나가고 Alertmanager 로그에 파일을 읽지 못했다는 오류가 남는다.
4. **시험 알림**: 아래 5절.

## 4. 평소

- **알림 잠시 끄기(점검·부하 시험 중)**: Alertmanager UI(`kubectl --context nerdnam-dev -n monitoring port-forward svc/monitoring-alertmanager 9093` → http://localhost:9093) → New Silence → matcher(예: `alertname=NerdnamApiLatencyHigh`)·기간 → Create. 또는 Grafana → Alerting → Silences(Alertmanager 데이터 소스).
- **웹훅 URL 바꾸기**: Secrets Manager 값만 바꾼다. ESO 가 1시간 안에 Secret 을 갱신한다(바로: `kubectl -n monitoring annotate externalsecret alertmanager-discord force-sync=$(date +%s) --overwrite`). Alertmanager 는 보낼 때 파일을 읽는다.
- **보낼 범위 바꾸기**: `kube-prometheus-stack.yaml` 의 `alertmanager.config.route` 를 PR 로 고친다. 메시지 모양은 `templateFiles.discord.tmpl`. 이 파일은 GitOps 에서 Helm `tpl` 을 한 번 거치므로 Go 템플릿의 `{{`·`}}` 는 `{{"{{"}}`·`{{"}}"}}` 로 적는다(지금 파일처럼).
- 설정 검사: 같은 버전 `amtool` 로 `check-config`(아래). 검증 스크립트는 연결 관계만 본다.
  ```sh
  docker run --rm -v <alertmanager.yaml·discord.tmpl 있는 폴더>:/etc/alertmanager/config:ro \
    --entrypoint amtool quay.io/prometheus/alertmanager:v0.34.1 check-config /etc/alertmanager/config/alertmanager.yaml
  ```

## 5. 시험 알림 보내기

```sh
kubectl --context nerdnam-dev -n monitoring port-forward svc/monitoring-alertmanager 9093 &
end=$(date -u -v+5M +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '+5 min' +%Y-%m-%dT%H:%M:%SZ)
curl -s -XPOST localhost:9093/api/v2/alerts -H 'Content-Type: application/json' -d "[{
  \"labels\": {\"alertname\": \"NerdnamDiscordTest\", \"severity\": \"warning\", \"namespace\": \"monitoring\"},
  \"annotations\": {\"summary\": \"Discord 알림 연결 시험입니다\"},
  \"endsAt\": \"$end\"}]"
```

약 30초 뒤 채널에 `[발생 1건] NerdnamDiscordTest · warning`, 5분 뒤 `[해결] …` 이 온다. 안 오면:

```sh
kubectl --context nerdnam-dev -n monitoring get externalsecret alertmanager-discord          # SecretSynced 인지
kubectl --context nerdnam-dev -n monitoring logs alertmanager-monitoring-0 -c alertmanager --since=10m | grep -iE 'discord|notify|error'
```

| 로그·상태 | 원인 |
| --- | --- |
| ExternalSecret `SecretSyncedError` | Secrets Manager 에 키 `alertmanager-discord-webhook-url` 이 없음(이름 오타) |
| `no such file` / `webhook_url_file` | Secret 이 아직 없음 → 위 줄 |
| `401`·`404` | 웹훅이 지워졌거나 URL 이 잘못됨 → Discord 에서 새로 만들어 값 교체 |
| `429` | Discord 속도 제한. 잠시 뒤 재시도된다 |

## 6. 한계

- Alertmanager 는 클러스터 안(platform 노드)에 있다. **platform 노드가 죽거나 클러스터를 내려 두면(`scripts/cluster.sh down`) 알림도 오지 않는다.** 클러스터 밖에서 지켜보는 장치(Watchdog 을 외부 dead-man 서비스로 보내기, CloudWatch EC2 상태 알림)는 후속 작업이다.
- 클러스터를 다시 올린 직후 Pod 준비 중 알림(`KubePodNotReady` 등)이 잠깐 올 수 있다(`for` 시간 뒤 해결).
