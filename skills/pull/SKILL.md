---
name: pull
description: "CWD 하위 모든 git 레포 + settings의 additionalDirectories 외부 워크스페이스까지 포함하여 git pull + submodule update. /pull 또는 /pull <target> 으로 특정 레포만 대상 지정 가능."
model: sonnet
effort: low
argument-hint: '[<target>]'
---

현재 작업 디렉토리 하위의 모든 git 레포와 Claude Code settings에 등록된 외부 워크스페이스를 찾아, outdated된 레포만 선택적으로 `git pull`을 실행하세요.

> **호출 최소화**: 레포 탐색은 Glob/Read (빌트인) 도구로, triage+pull은 `scripts/triage.sh` **한 번의 외부 스크립트 호출**로 처리한다. 인라인 bash로 쪼개지 말 것 — 호출 수가 곧 권한 확인 횟수다. 매번 수락이 번거로우면 사용자가 직접 auto mode 를 켜거나 해당 스크립트에 대한 permission 규칙(`Bash(bash ...triage.sh*)`)을 미리 추가하면 된다. 스킬이 권한 0회를 보장하지는 않는다.

> **출력 규칙**: 절차 진행 중 사용자에게 텍스트를 출력하지 않는다. "N개의 레포를 발견했습니다", "이 레포는 detached HEAD 상태입니다", "CLI가 설치되어 있습니다" 같은 중간 상태 보고를 하지 말 것. 도구 호출만 연속 실행하고, 아래 "결과 보고" 형식(요약 테이블 + 상세 섹션 + submodule 섹션)만 최종으로 출력한다. 단, 사용자 확인이 필요한 에러나 판단이 필요한 상황은 예외.

## 절차

### 1. Git 레포 탐색 (Glob + Read — 자동 승인)

#### 1a. CWD 하위 레포 탐색

`Glob` 도구를 사용하여 git 레포를 찾는다. `.git` 디렉토리 자체는 Glob으로 탐지가 불안정하므로, `.git/HEAD` **파일**을 검색한다:

```
Glob(pattern: "**/.git/HEAD")
```

결과에서 다음 경로를 포함하는 항목을 **제외**한다: `node_modules`, `vendor`, `.cache`, `build`, `.terraform`

#### 1b. 외부 워크스페이스 탐색

Claude Code settings 파일에서 `additionalDirectories` 배열을 읽어 외부 워크스페이스를 찾는다. 다음 파일들을 **Read** 도구로 읽되, 파일이 없으면 건너뛴다 (1a의 Glob 호출과 병렬로 실행):

1. `~/.claude/settings.json` → `permissions.additionalDirectories`
2. `.claude/settings.json` (현재 작업 디렉토리 기준) → `permissions.additionalDirectories`
3. `.claude/settings.local.json` (현재 작업 디렉토리 기준) → `permissions.additionalDirectories`

모든 소스에서 발견된 경로를 합친다 (중복 제거). 항목의 `~` 는 홈 디렉토리로 확장하고, 상대경로는 현재 작업 디렉토리 기준 절대경로로 정규화한 뒤 사용한다. 각 외부 디렉토리에 대해:
- 해당 경로 자체가 git 레포인지 확인: `Glob(pattern: ".git/HEAD", path: "<경로>")`
- 하위에 다른 레포가 있는지도 확인: `Glob(pattern: "**/.git/HEAD", path: "<경로>")`

#### 1c. 경로 통합 및 인자 필터

모든 결과에서 `/.git/HEAD`를 제거하여 레포 루트 경로 목록을 만든다.

**인자 필터링**: `$ARGUMENTS` 가 주어지면 그것을 대상 레포를 가리키는 자연어 기술로 보고 (예: `/pull api-server`, `/pull backend 폴더 아래 모든 저장소`), 발견한 레포 목록에서 부합하는 레포만 남긴다 — 이름·경로·위치 등 표현 방식과 무관하게 해석한다. 어느 레포를 가리키는지 모호하면 선택지로 확인한다. 인자가 없으면 전체 목록을 사용한다.

**Symlink 중복 제거**: `triage.sh`가 `realpath`로 경로를 정규화하여 같은 물리적 레포를 가리키는 중복 경로(symlink, additionalDirectories 중복 등)를 자동으로 제거한다. 첫 번째로 전달된 경로가 대표 경로로 사용된다. 따라서 모델 측에서 별도 dedup을 할 필요가 없다.

**Submodule 제외**: 한 레포 경로가 다른 레포 경로의 하위이고 부모의 `.gitmodules` 에 submodule 로 등록돼 있으면 목록에서 제외한다 — submodule 을 top-level 로 직접 pull 하면 superproject 의 gitlink 와 어긋나기 때문이다 (submodule 원격 업데이트는 절차 2 의 `submodule foreach` 가 별도 보고한다). 부모 `.gitmodules` 에 없는 중첩 독립 레포는 그대로 둔다.

### 2. Triage + Pull (외부 스크립트 — 자동 승인)

`triage.sh`에 레포 경로들을 인자로 전달한다 (경로에 공백이 있을 수 있으므로 각 경로를 반드시 따옴표로 감싼다). 이 스크립트는 모든 레포를 병렬로 fetch, 상태 확인, 그리고 OUTDATED 레포는 즉시 pull까지 수행한다.

스크립트 경로는 설치 방식에 따라 다르다. 아래 형태로 호출하면 **플러그인 설치**(`${CLAUDE_PLUGIN_ROOT}` 설정됨)와 **개인 스킬 설치**(`~/.claude/skills/pull/`) 모두에서 동작한다:

```
bash "${CLAUDE_PLUGIN_ROOT:-$HOME/.claude/skills/pull}/scripts/triage.sh" "<레포1>" "<레포2>" ...
```

스크립트는 Linux / macOS / WSL 에서 동작한다 (`timeout`/`gtimeout` 부재 시 순수 bash 폴백, `realpath` 부재 시 `cd && pwd -P` 폴백, bash 3.2 호환).

**Pull 전략**: `git pull --rebase`를 기본으로 사용한다. 로컬 커밋이 있더라도 원격과 깨끗하게 합쳐질 수 있으면 linear history가 유지되어 merge 커밋이 생기지 않는다. 만약 rebase 중 충돌이 발생하면 즉시 `rebase --abort`로 원상 복구하고 해당 레포를 `REBASE_CONFLICT`로 표시한다 (사용자가 수동으로 해결해야 함). 이 방식은 "충돌 없을 때만 rebase, 있으면 건드리지 않음"을 깨끗하게 구현한다.

스크립트 출력을 파싱하여 각 레포를 분류:
- **CURRENT**: behind == 0 → pull 불필요
- **OUTDATED**: behind > 0 → 무조건 pull --rebase 시도. dirty 여부는 사전 판정하지 않는다 — git이 스스로 거부하거나, 정상적으로 rebase하거나, 충돌 시 abort로 원상 복구된다
- **NO_UPSTREAM**: upstream 미설정 → 건너뜀
- **TIMEOUT**: fetch가 30초 내 응답 없음
- **ERROR**: fetch 실패

OUTDATED 레포의 pull 결과는 출력에 다음 키로 포함된다:
- `UPDATED:yes` + `NEW_COMMITS_*` / `DIFF_*` — rebase 성공
- `REBASE_CONFLICT:yes` + `PULL_ERROR_*` — rebase 중 충돌로 abort됨 (HEAD는 BEFORE 상태 유지)
- `PULL_ERROR_*` 만 있음 — git이 pull 자체를 거부 (예: tracked dirty tree, 네트워크 오류 등)

## 결과 보고

모든 레포 처리 후 아래 형식으로 요약:

| 레포 | 브랜치 | Pull 상태 | 로컬 변경 |
|------|--------|-----------|-----------|
| (CWD 기준 상대 경로) | (현재 브랜치) | 아래 참고 | 아래 참고 |

**Pull 상태**:
- ✅ Up to date — 이미 최신
- 📥 Updated — rebase 성공 (업스트림 커밋이 깔끔하게 적용됨; 로컬 커밋이 있었다면 그 위로 재배치됨)
- ⚠️ Conflict — rebase 충돌로 abort됨; HEAD는 건드리지 않은 원래 상태. 사용자가 직접 해결 필요
- ❌ Error — fetch 실패, dirty tree 등으로 git이 pull 거부, 기타 에러
- ⏱️ Timeout — fetch 타임아웃

**로컬 변경**:
- 커밋되지 않은 변경: `📝 M 3, A 1, D 2` 형식 (Modified/Added/Deleted 파일 수)
- 푸시되지 않은 커밋: `📤 N commits` 형식
- 둘 다 없으면 `-`

로컬 변경이나 에러가 있는 레포, 또는 📥 Updated 레포는 테이블 아래에 상세 내역을 별도 섹션으로 출력한다. **상세 내역은 모두 테이블로 통일**한다 — 산문 문단으로 쓰지 말 것. 각 변경은 한 행(行)으로 분리하고, 파일·작성자를 별도 열로 둔다.

#### pulled (📥 Updated 레포)

`변경 | 시점 | 작성자` 3열 테이블:

| 변경 | 시점 | 작성자 |
|------|------|--------|
| (변경 요약) | (상대 시각) | (작성자명) |

- **변경 열**: diff 내용(코드 변경)과 커밋 메시지(의도)를 종합 분석하여, 실제로 무엇이 어떻게 변경되었는지를 한국어로 서술한다. 커밋 해시나 메시지를 그대로 나열하지 말 것. 논리적으로 구분되는 변경은 각각 별도 행으로 분리한다. **파일명·경로는 서술에 넣지 않는다** — 변경의 내용·의도만 적고, 구체적 파일이 궁금하면 diff에서 확인한다.
  - 좋은 예 (행): `Electron webview에서 ziowww 페이지 overflow가 hidden으로 고정돼 스크롤 불가하던 문제를 auto로 변경하여 수정`
  - 나쁜 예 (파일명 포함): `overflow를 auto로 변경하여 스크롤 불가 문제 수정 (WindowManager.tsx)`
  - 나쁜 예 (해시·메시지 나열): `` `d0c7d87` fix: Electron에서 ziowww 페이지 스크롤 불가 문제 해결 ``
- **시점 열**: 해당 변경이 **언제 이뤄졌는지**를 한국어 상대 시각으로 표시한다 (`방금 전`, `n분 전`, `n시간 전`, `n일 전`, `n주 전`, `n개월 전` 등). NEW_COMMITS 블록의 각 줄은 `해시 메시지 (작성자 · 상대시각)` 형식이며, 괄호 안 `· ` 뒤의 상대시각(git이 스크립트 실행 시점 기준으로 계산한 영문, 예: `5 minutes ago`)을 한국어로 옮긴다. 한 행이 여러 커밋을 묶었다면 가장 최근 커밋의 시점을 쓴다.
- **작성자 열**: NEW_COMMITS 블록 각 줄의 괄호 안 `· ` 앞 작성자명. 같은 작성자의 변경이 여러 행이면 각 행에 반복 표기한다.

#### uncommitted (로컬 미커밋 변경)

`파일 | 상태` 2열 테이블 (status --porcelain 기반, `M`/`A`/`D`/`??` 등):

| 파일 | 상태 |
|------|------|
| (파일 경로) | (M/A/D/??) |

#### unpushed (미푸시 커밋)

`커밋 | 시점 | 작성자` 3열 테이블 (UNPUSHED 블록 기반, 각 줄은 `해시 메시지 (작성자 · 상대시각)` 형식 — 메시지를 그대로 쓰되 해시는 생략, 시점은 상대시각을 한국어로 변환):

| 커밋 | 시점 | 작성자 |
|------|------|--------|
| (커밋 메시지) | (상대 시각) | (작성자명) |

#### error / timeout

해당 레포는 `에러` 또는 `타임아웃` 한 행으로 사유를 적는다:

| 레포 | 사유 |
|------|------|
| (레포명) | (에러 내용 / fetch 타임아웃) |

### Submodule 업데이트 가능

submodule에 원격 업데이트가 있는 레포가 있으면 별도 섹션으로 보고한다. `레포 | Submodule | 변경 | 시점 | 작성자` 5열 테이블로, SUBMODULE 블록의 새 커밋(각 줄 `해시 메시지 (작성자 · 상대시각)`) 각각을 한 행으로 분리한다 (시점은 상대시각을 한국어로 변환):

| 레포 | Submodule | 변경 | 시점 | 작성자 |
|------|-----------|------|------|--------|
| (레포 경로) | (submodule 경로) | (변경 요약 / 커밋 메시지) | (상대 시각) | (작성자명) |
