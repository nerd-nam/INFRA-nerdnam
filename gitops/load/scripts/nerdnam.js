// 9단계 부하 시험: 읽기 전용 경로만 부른다. AI 작업(분석·가이드 생성)은 Bedrock 요금이 들어 부르지 않는다.
//
// 보통은 클러스터 안에서 k6-operator 로 돌린다(gitops/load/testruns, 절차는 docs/부하-시험.md).
// 결과 지표는 Prometheus 로 들어가 Grafana "nerdnam 부하 시험" 대시보드에서 서버 지표와 같은 시간축으로 본다.
// 노트북에서 직접 돌릴 수도 있다(이때 결과는 터미널에만 나온다):
//
//   k6 run -e BASE_URL=https://<서비스 도메인> -e SCENARIO=concurrency gitops/load/scripts/nerdnam.js
//
// SCENARIO
//   smoke        일정 도착률 RATE/초(기본 2), DURATION(기본 2m). 배포 직후 경로 확인용
//   concurrency  동시 사용자(VU) 수를 계단식으로 올린다. 각 VU 는 한 바퀴 돌고 THINK 초(기본 0.5) 쉰다
//   rate         초당 시작하는 반복 수(요청량)를 계단식으로 올린다. 서버가 느려져도 요청량은 줄지 않는다
// STAGES   "목표:시간" 쉼표 목록. concurrency 는 VU 수, rate 는 초당 반복 수. 예: "10:1m,10:3m,0:30s"
// SESSION  로그인한 사용자 경로까지 부를 때 시험용 계정의 SESSION 쿠키 값(저장소·채팅에 남기지 않는다)
// TEST_ID  대시보드에서 실행을 고르는 이름. 없으면 "<시작 시각(UTC)>-<SCENARIO>" (이름순이 시간순)
import http from 'k6/http';
import { check, group, sleep } from 'k6';

const BASE = (__ENV.BASE_URL || '').replace(/\/$/, '');
if (!BASE) throw new Error('BASE_URL 을 주세요 (예: -e BASE_URL=https://nerdnam.example.com)');
const SESSION = __ENV.SESSION || '';
const SCENARIO = __ENV.SCENARIO || 'smoke';
const THINK = Number(__ENV.THINK || 0.5);
const TEST_ID = __ENV.TEST_ID || `${new Date().toISOString().slice(0, 16)}-${SCENARIO}`;
const EXPECT_401 = http.expectedStatuses(401);

// 각 단계는 앞 1개(올리는 구간) + 뒤 1개(유지 구간). 유지 구간의 대시보드 값을 읽는다.
// 서버(api·web 각 1개)가 버거워지는 지점을 넘도록 잡았다. 마지막 단계에서는 느려지거나 실패하는 게 보통이다.
const DEFAULT_STAGES = {
  concurrency: '25:30s,25:2m,50:30s,50:2m,100:30s,100:2m,200:30s,200:2m,300:30s,300:2m,0:30s',
  rate: '10:30s,10:2m,25:30s,25:2m,50:30s,50:2m,100:30s,100:2m,150:30s,150:2m,0:30s',
};

function stages(text) {
  return text.split(',').map((item) => {
    const [target, duration] = item.trim().split(':');
    if (!duration || Number.isNaN(Number(target))) throw new Error(`STAGES 형식: "목표:시간" 쉼표 목록 (받은 값: ${item})`);
    return { target: Number(target), duration };
  });
}

const SCENARIOS = {
  smoke: () => ({
    executor: 'constant-arrival-rate',
    rate: Number(__ENV.RATE || 2),
    timeUnit: '1s',
    duration: __ENV.DURATION || '2m',
    preAllocatedVUs: 5,
    maxVUs: 50,
  }),
  concurrency: () => ({
    executor: 'ramping-vus',
    startVUs: 0,
    stages: stages(__ENV.STAGES || DEFAULT_STAGES.concurrency),
    gracefulRampDown: '30s',
  }),
  rate: () => {
    // 서버가 느려지면 같은 요청량을 내기 위해 VU 가 늘어난다. 이 값에 닿으면 k6 가 dropped_iterations 를 센다.
    const maxVUs = Number(__ENV.MAX_VUS || 500);
    return {
      executor: 'ramping-arrival-rate',
      startRate: 0,
      timeUnit: '1s',
      stages: stages(__ENV.STAGES || DEFAULT_STAGES.rate),
      preAllocatedVUs: Math.min(20, maxVUs),
      maxVUs,
    };
  },
};
if (!SCENARIOS[SCENARIO]) throw new Error(`SCENARIO 는 ${Object.keys(SCENARIOS).join(' / ')} 중 하나`);

export const options = {
  scenarios: { [SCENARIO]: SCENARIOS[SCENARIO]() },
  // 모든 지표에 붙는다. testid 는 실행 하나를 고르는 라벨, mode 는 시험 종류(k6_vus 처럼 scenario 라벨이 없는 지표도 나눌 수 있게).
  // VU 의 뜻이 시험마다 다르다: concurrency 는 접속해 있는 사용자(쉬는 중 포함), rate·smoke 는 응답을 기다리는 작업자.
  tags: { testid: TEST_ID, mode: SCENARIO },
  // 측정 전 시작값. 첫 실측 뒤 조정한다. 계단식 시험은 한도를 찾는 게 목적이라 마지막 단계에서 넘는 게 보통이다.
  thresholds: {
    checks: ['rate>0.99'],
    'http_req_duration{kind:api}': ['p(95)<800'],
    'http_req_duration{kind:web}': ['p(95)<1500'],
  },
};

export default function () {
  // 쿠키 저장소는 VU 마다 하나다(init 단계에서는 만들 수 없다)
  if (SESSION) http.cookieJar().set(BASE, 'SESSION', SESSION);

  group('web', () => {
    const page = http.get(`${BASE}/`, { tags: { kind: 'web' } });
    check(page, { 'web / 200': (r) => r.status === 200 });
  });

  group('api', () => {
    const csrf = http.get(`${BASE}/api/auth/csrf`, { tags: { kind: 'api' } });
    check(csrf, { 'csrf 200': (r) => r.status === 200 });
    if (!SESSION) {
      // 로그인 없이: 보호 경로가 401 로 빨리 거절되는지(5xx·지연 없이). 401 이 정상이라 http_req_failed 에 세지 않는다
      const denied = http.get(`${BASE}/api/projects`, { tags: { kind: 'api' }, responseCallback: EXPECT_401 });
      check(denied, { 'projects 401 without login': (r) => r.status === 401 });
      return;
    }
    for (const path of ['/api/me', '/api/projects', '/api/job-postings', '/api/me/library', '/api/me/careers', '/api/me/skills']) {
      const res = http.get(`${BASE}${path}`, { tags: { kind: 'api', name: path } });
      check(res, { [`${path} 200`]: (r) => r.status === 200 });
    }
  });

  // 동시 사용자 시험에서는 사람처럼 쉬었다 다시 부른다. 요청량 시험은 k6 가 도착률을 맞추므로 쉬지 않는다.
  if (SCENARIO === 'concurrency') sleep(THINK);
}
