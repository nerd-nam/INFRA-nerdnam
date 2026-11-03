# 이미지 배포 PR 자동화 (앱 CI → INFRA PR)

기준일: 2026-11-03. 앱 저장소(FE·BE·AI) CI가 ECR에 이미지를 올린 뒤 **INFRA `gitops/apps/images.yaml`을 고치는 PR을 자동으로 연다.** merge와 배포(Argo sync)는 사람이 한다.

## 1. 왜

이전에는 앱 CI가 ECR까지만 올리고, 운영자가 실행 요약의 digest를 복사해 INFRA PR을 만들었다(팀 결정 2026-10-29). 이 단계를 잊어 FE 상태 유지 버그 수정(FE `518cbbe`, 10-30 push)이 4일 동안 클러스터에 반영되지 않았다(INFRA #12). 그래서 앱 CI가 PR까지 열도록 결정을 바꿨다([앱-배포-작업계획.md](앱-배포-작업계획.md) 5절).

## 2. 흐름

```text
앱 main merge
  → 앱 CI: 테스트 → 이미지 빌드 → ECR push (태그 = commit SHA, digest 계산)
  → 앱 CI 의 job "INFRA 배포 PR": INFRA 의 .github/workflows/image-pr.yml 호출
       ├ 입력 확인: 호출한 저장소 ↔ 앱(FE→web, BE→api, AI→ai), 이미지 형식, 앱 main 의 최신 commit 인지
       ├ GitHub App 토큰 발급(INFRA 저장소만, contents·pull-requests 쓰기)
       ├ INFRA main 받기 → images.yaml 의 자기 줄만 교체 → 브랜치 deploy/<app> 에 force push
       └ PR "deploy(<app>): <FE|BE|AI> <sha7> — <commit 제목>" 열기 또는 갱신
사람: PR 리뷰·merge → Argo CD 에서 nerdnam-apps sync → 확인
```

| 상황 | 동작 |
| --- | --- |
| 같은 앱의 새 이미지가 또 올라옴 | 같은 PR(브랜치 `deploy/<app>`)을 최신 main 위에서 다시 만들어 갱신. PR은 앱마다 하나 |
| 다른 앱 PR이 동시에 열림 | `images.yaml` 줄 사이에 빈 줄을 둬서 서로 충돌하지 않는다(빈 줄을 지우지 않는다) |
| CI가 끝나기 전에 앱 main에 새 commit | 건너뛴다. 새 commit의 실행이 PR을 만든다 |
| main에 이미 같은 이미지 | 변경 없음. 열려 있던 그 앱 PR은 닫는다 |
| FE CI가 api 이미지를 넣으려 함 | 거부(실패) |

PR 본문: 앱, 새 commit, **바뀐 commit 범위(이전 배포 commit…새 commit 비교 링크)**, 이미지, 만든 CI 실행, merge 후 할 일(BE는 AI 작업 drain 먼저).

## 3. 권한과 보안

- 앱 저장소가 받는 INFRA 권한은 **GitHub App 토큰** 하나다. App은 INFRA 저장소에만 설치하고 권한은 `Contents: Read and write`, `Pull requests: Read and write`(+ 기본 `Metadata: Read`)만 준다. **`Workflows` 권한을 주지 않는다** — INFRA의 `.github/workflows`(Terraform CI·이 workflow)를 고칠 수 없다.
- 토큰은 실행마다 1시간짜리로 발급되고 끝나면 폐기된다. 키(private key)는 조직 secret에 둔다.
- App 토큰은 브랜치를 만들고 파일을 바꿀 수 있으므로 **INFRA main에 브랜치 보호(PR 필수, 리뷰 1명)** 를 건다(아래 4절 5). 그러면 App도 사람도 main에 바로 push할 수 없다.
- PR 만드는 코드는 INFRA에만 있다(앱 저장소는 호출만). 앱 저장소는 `@main` 을 부르므로 INFRA main(리뷰된 코드)이 그대로 쓰인다.
- Terraform(AWS)은 이 흐름과 관계없다. `images.yaml` 변경은 Terraform CI를 돌리지 않는다.

## 4. 처음 한 번 준비

1. **GitHub App 만들기**(조직 관리자): GitHub → `nerd-nam` 조직 → Settings → Developer settings → GitHub Apps → **New GitHub App**
   - 이름: `nerdnam-deploy-bot`(아무 이름), Homepage URL: `https://github.com/nerd-nam/INFRA-nerdnam`
   - Webhook: **Active 체크 해제**
   - Repository permissions: **Contents → Read and write**, **Pull requests → Read and write**. 나머지는 No access(Metadata 는 자동 Read)
   - Where can this GitHub App be installed: **Only on this account**
   - Create → 화면의 **App ID** 를 적어 둔다 → **Generate a private key** (`.pem` 파일이 내려받아진다)
2. **설치**: App 페이지 → Install App → `nerd-nam` → **Only select repositories → `INFRA-nerdnam`**
3. **조직 secret·변수**(앱 저장소 3곳에서 보이게):
   ```sh
   gh secret   set INFRA_PR_APP_PRIVATE_KEY --org nerd-nam --repos FE-nerdnam,BE-nerdnam,AI-nerdnam < <내려받은 키>.pem
   gh variable set INFRA_PR_APP_ID          --org nerd-nam --repos FE-nerdnam,BE-nerdnam,AI-nerdnam --body <App ID>
   ```
   키 파일은 등록 뒤 지운다(저장소·채팅에 남기지 않는다).
4. **앱 저장소 CI에 job 추가**(FE·BE·AI 각 PR): 이미지 push job 이 digest 를 출력(`outputs.image`)하고, 그 뒤에 아래 job 을 둔다.
   ```yaml
   infra-pr:
     name: INFRA 배포 PR
     needs: push                      # 이미지를 올린 job
     if: needs.push.outputs.image != '' && vars.INFRA_PR_APP_ID != ''
     permissions: {contents: read}
     uses: nerd-nam/INFRA-nerdnam/.github/workflows/image-pr.yml@main
     with:
       app: web                       # BE 는 api, AI 는 ai
       image: ${{ needs.push.outputs.image }}   # <registry>/nerdnam-dev/web@sha256:...
       app_id: ${{ vars.INFRA_PR_APP_ID }}
     secrets:
       app_private_key: ${{ secrets.INFRA_PR_APP_PRIVATE_KEY }}
   ```
   변수가 없으면 건너뛴다(준비 전에도 앱 CI가 빨간불이 되지 않는다).
5. **INFRA main 브랜치 보호**(권장): Settings → Branches(또는 Rules) → `main` → Require a pull request before merging(승인 1), 강제 push·삭제 금지.

## 5. 확인·문제 해결

- 앱 CI 실행 → job "INFRA 배포 PR" → Summary 에 `INFRA 배포 PR: <URL>`.
- INFRA PR 목록에서 `deploy(web|api|ai): …` 를 찾는다.

| 증상 | 원인·해결 |
| --- | --- |
| job 이 건너뛰어짐 | 조직 변수 `INFRA_PR_APP_ID` 가 그 저장소에 안 보임(3절의 `--repos`), 또는 이미지 job 이 digest 를 출력하지 않음 |
| `Not Found`·`Resource not accessible by integration` | App 이 INFRA 에 설치되지 않았거나 권한(Contents·Pull requests 쓰기)이 빠짐 |
| `… 는 'api' 이미지를 배포할 수 없습니다` | 앱 CI 의 `app` 값이 저장소와 다름(FE=web, BE=api, AI=ai) |
| `건너뜁니다` 알림 | 그사이 앱 main 에 새 commit. 그 실행의 결과를 본다 |
| PR 이 충돌 | `images.yaml` 의 줄 사이 빈 줄이 지워졌는지 확인. 다음 이미지가 올라오면 최신 main 위에서 다시 만들어진다(바로 고치려면 앱 CI 를 다시 실행) |
