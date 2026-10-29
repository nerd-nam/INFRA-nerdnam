// 9단계 부하 시험: 읽기 전용 경로만 부른다. AI 작업(분석·가이드 생성)은 Bedrock 요금이 들어 부르지 않는다.
//
//   k6 run -e BASE_URL=https://<서비스 도메인> scripts/load/read-only.js
//   로그인한 사용자 경로까지:  -e SESSION=<브라우저의 SESSION 쿠키 값>   (시험용 계정. 쿠키를 저장소·채팅에 남기지 않는다)
//   세기:  -e RATE=5 -e DURATION=5m   (초당 요청 반복 수, 기본 2/s · 2분)
//
// 확인할 것(docs/운영-검증-작업계획.md): 서비스 대시보드의 요청 수·평균/최대 응답 시간·5xx, BE heap·DB 연결 풀,
// app 노드 CPU·메모리, 그리고 이 스크립트의 임계값. 첫 시험은 낮은 세기로 시작해 올린다.
import http from 'k6/http';
import { check, group } from 'k6';

const BASE = (__ENV.BASE_URL || '').replace(/\/$/, '');
if (!BASE) throw new Error('BASE_URL 을 주세요 (예: -e BASE_URL=https://nerdnam.example.com)');
const SESSION = __ENV.SESSION || '';

export const options = {
  scenarios: {
    read: {
      executor: 'constant-arrival-rate',
      rate: Number(__ENV.RATE || 2),
      timeUnit: '1s',
      duration: __ENV.DURATION || '2m',
      preAllocatedVUs: 5,
      maxVUs: 50,
    },
  },
  // 측정 전 시작값. 첫 실측 뒤 조정한다.
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
      // 로그인 없이: 보호 경로가 401 로 빨리 거절되는지(5xx·지연 없이)
      const denied = http.get(`${BASE}/api/projects`, { tags: { kind: 'api' } });
      check(denied, { 'projects 401 without login': (r) => r.status === 401 });
      return;
    }
    for (const path of ['/api/me', '/api/projects', '/api/job-postings', '/api/me/library', '/api/me/careers', '/api/me/skills']) {
      const res = http.get(`${BASE}${path}`, { tags: { kind: 'api', name: path } });
      check(res, { [`${path} 200`]: (r) => r.status === 200 });
    }
  });
}
