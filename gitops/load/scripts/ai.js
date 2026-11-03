// AI 장애 재현(INFRA #19, SPEC ADR-0008 부록 "운영(E2E) 재현 계획"): 운영 경로 그대로 k6 → BE → AI → Bedrock.
// 실제 Bedrock 을 부른다(요금). 실행 시간대를 팀에 공지하고, 그동안 문서 업로드·다른 AI 사용을 멈춘다.
// 읽기 경로 시험(nerdnam.js)과 따로, 한 번에 하나만 돌린다. 결과는 Grafana "nerdnam AI 장애 재현" 대시보드.
//
//   scripts/load-test.sh run ai-analysis --session --env POSTING_IDS=3,4,5,6,7,8,9,10,11,12   (클러스터, docs/부하-시험-실행.md)
//   k6 run -e BASE_URL=… -e SCENARIO=guide -e SESSION=… -e POSTING_IDS=… gitops/load/scripts/ai.js   (노트북)
//
// SCENARIO
//   analysis  공고 분석 시작(요건 20개 공고). 분석 1건 = 요건 질의 임베딩 20번 → Titan 분당 한도에서 막힌다(장애형)
//   guide     작성 방향 탭 5개 생성. 탭 1개 = Nova 1번 → Nova 분당 한도에서 BE 큐가 밀린다(저하형)
// 흐름: 정상 RATE_NORMAL 건/분 × DURATION_NORMAL → PAUSE 쉼 → 몰림 RATE_SURGE 건/분 × DURATION_SURGE
// SESSION      시험 계정의 SESSION 쿠키(필수). Secret k6-session 으로 넣는다. 저장소·채팅에 남기지 않는다
// POSTING_IDS  분석이 한 번 끝난 공고 id 쉼표 목록(필수, BE scripts/loadtest-seed.sh 가 만든다). 돌아가며 쓴다. 시험 공고만 넣는다(같은 계정의 실제 공고 제외)
// 결과 지표(Prometheus): k6_ai_job_duration_seconds(native histogram, 태그 job·status),
//                       k6_ai_job_result_total(태그 job·result·failure_code). 판정은 대시보드에서 한다(thresholds 없음)
import http from 'k6/http';
import exec from 'k6/execution';
import { check, sleep } from 'k6';
import { Counter, Trend } from 'k6/metrics';

const BASE = (__ENV.BASE_URL || '').replace(/\/$/, '');
if (!BASE) throw new Error('BASE_URL 을 주세요');
const SCENARIO = __ENV.SCENARIO || '';
const SESSION = __ENV.SESSION || '';
const POSTINGS = (__ENV.POSTING_IDS || '').split(',').map((s) => s.trim()).filter(Boolean);
if (!SESSION) throw new Error('SESSION(시험 계정 로그인 쿠키)이 필요합니다. Secret k6-session 또는 load-test.sh --session');
if (POSTINGS.length === 0 || POSTINGS.some((id) => !/^[0-9]+$/.test(id))) {
  throw new Error(`POSTING_IDS 를 쉼표로 주세요 (받은 값: "${__ENV.POSTING_IDS || ''}")`);
}

const DEFAULTS = { analysis: { normal: 2, surge: 5 }, guide: { normal: 3, surge: 6 } };
if (!DEFAULTS[SCENARIO]) throw new Error(`SCENARIO 는 ${Object.keys(DEFAULTS).join('·')} 중 하나 (받은 값: ${SCENARIO})`);
const RATE_NORMAL = Number(__ENV.RATE_NORMAL || DEFAULTS[SCENARIO].normal);
const RATE_SURGE = Number(__ENV.RATE_SURGE || DEFAULTS[SCENARIO].surge);
const DURATION_NORMAL = __ENV.DURATION_NORMAL || '5m';
const PAUSE = __ENV.PAUSE || '2m';
const DURATION_SURGE = __ENV.DURATION_SURGE || '5m';
const POLL = Number(__ENV.POLL_SECONDS || 2.5);          // 화면과 같은 주기
const JOB_TIMEOUT = Number(__ENV.JOB_TIMEOUT_SECONDS || 600);
const TABS = ['motive', 'intro', 'portfolio', 'career', 'image'];
const JOB = { analysis: 'fit_analysis', guide: 'writing_guide' }[SCENARIO];

function seconds(text) {
  const m = /^([0-9]+)([smh])$/.exec(text);
  if (!m) throw new Error(`시간 형식: 30s·5m·1h (받은 값: ${text})`);
  return Number(m[1]) * { s: 1, m: 60, h: 3600 }[m[2]];
}

// 반복 하나가 작업이 끝날 때까지(최대 JOB_TIMEOUT) 기다리므로, 몰림 비율 × 최대 대기 시간만큼 VU 가 필요할 수 있다.
const maxVUs = Math.ceil(RATE_SURGE * (JOB_TIMEOUT / 60)) + 5;
// gracefulStop: 단계가 끝나도 이미 시작한 작업은 끝(또는 JOB_TIMEOUT)까지 따라간다(기본 30초면 몰림 끝 무렵 작업 결과가 잘린다).
const phase = (rate, duration, startTime) => ({
  executor: 'constant-arrival-rate', rate, timeUnit: '1m', duration, startTime,
  preAllocatedVUs: Math.max(2, Math.ceil(rate * 2)), maxVUs, gracefulStop: `${JOB_TIMEOUT + 30}s`,
});

export const options = {
  scenarios: {
    normal: phase(RATE_NORMAL, DURATION_NORMAL, '0s'),
    surge: phase(RATE_SURGE, DURATION_SURGE, `${seconds(DURATION_NORMAL) + seconds(PAUSE)}s`),
  },
  // 요청 주소에 id 가 들어가 시계열이 늘지 않게 name 을 고정한다(아래 tags.name)
  summaryTrendStats: ['avg', 'p(50)', 'p(95)', 'max'],
};

const jobDuration = new Trend('ai_job_duration', true);
const jobResult = new Counter('ai_job_result');

function csrfHeaders() {
  const res = http.get(`${BASE}/api/auth/csrf`, { tags: { kind: 'api', name: 'GET /api/auth/csrf' } });
  check(res, { 'csrf 200': (r) => r.status === 200 });
  const body = res.json();
  return { 'Content-Type': 'application/json', Accept: 'application/json', [body.headerName]: body.token };
}

// 시작한 작업들을 함께(화면처럼 POLL 초마다) 끝(completed·failed)까지 따라간다. 시작부터 끝을 본 때까지를 ai_job_duration 에.
// 하나씩 차례로 따라가면 먼저 끝난 작업의 시간이 앞 작업을 기다린 만큼 부풀려진다.
function follow(jobs) {
  let pending = jobs.filter(Boolean);
  while (pending.length > 0) {
    sleep(POLL);
    const now = Date.now();
    pending = pending.filter((job) => {
      if (now > job.startedAt + JOB_TIMEOUT * 1000) {
        jobResult.add(1, { job: JOB, result: 'timeout_k6', failure_code: 'none' });
        return false;
      }
      const res = http.get(`${BASE}/api/ai-jobs/${job.jobId}`, {
        headers: { Accept: 'application/json' }, tags: { kind: 'api', name: 'GET /api/ai-jobs/{id}' },
      });
      if (res.status !== 200) return true;
      const view = res.json();
      if (view.status !== 'completed' && view.status !== 'failed') return true;
      jobDuration.add((Date.now() - job.startedAt) / 1000, { job: JOB, status: view.status });
      jobResult.add(1, { job: JOB, result: view.status, failure_code: view.failureCode || 'none' });
      return false;
    });
  }
}

// 작업 시작. 202 → jobId, 409(AI_JOB_RUNNING: 같은 대상 진행 중) → skipped 로 세고 넘어간다(기다리지 않는다).
function start(url, body, name) {
  const startedAt = Date.now();
  const res = http.post(url, body, { headers: csrfHeaders(), tags: { kind: 'api', name },
    responseCallback: http.expectedStatuses(202, 409) });
  if (res.status === 202) return { jobId: res.json().jobId, startedAt };
  if (res.status === 409) {
    jobResult.add(1, { job: JOB, result: 'skipped', failure_code: 'none' });
  } else {
    jobResult.add(1, { job: JOB, result: 'failed', failure_code: `http_${res.status}` });
  }
  return null;
}

export default function () {
  http.cookieJar().set(BASE, 'SESSION', SESSION);
  const posting = POSTINGS[exec.scenario.iterationInTest % POSTINGS.length];
  const started = [];
  if (SCENARIO === 'analysis') {
    started.push(start(`${BASE}/api/job-postings/${posting}/analyses`, null, 'POST /api/job-postings/{id}/analyses'));
  } else {
    // 이미 완료된 탭을 다시 만들 때 feedback 이 필수라 항상 넣는다(계약 C-04)
    const body = JSON.stringify({ feedback: `부하 시험 ${exec.scenario.name} ${exec.scenario.iterationInTest}` });
    for (const tab of TABS) {
      started.push(start(`${BASE}/api/job-postings/${posting}/guides/${tab}`, body, 'POST /api/job-postings/{id}/guides/{tab}'));
    }
  }
  follow(started);
}
