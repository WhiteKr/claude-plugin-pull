#!/usr/bin/env bash
# skill:pull - triage + pull script (cross-platform: Linux / macOS / WSL)
# Usage: bash triage.sh repo1 repo2 ...
#
# 의도적으로 `set -e` 를 쓰지 않는다. 이 스크립트의 목적은 "개별 git 명령의 실패를
# 잡아서 레포별로 분류"하는 것이므로, 첫 실패에 즉시 종료되면 안 된다. 대신 각 명령의
# 종료코드를 인라인으로 캡처한다 (`cmd || rc=$?`). -u(unset 변수 탐지)만 유지.
set -u

[ "$#" -eq 0 ] && { echo "no repos"; exit 0; }

FETCH_TIMEOUT=30
WORKDIR=$(mktemp -d "${TMPDIR:-/tmp}/pull-triage.XXXXXX") || { echo "error: mktemp -d 실패"; exit 1; }
[ -n "$WORKDIR" ] && [ -d "$WORKDIR" ] || { echo "error: 임시 디렉토리 생성 실패"; exit 1; }

# --- 환경 탐지: timeout 명령 (GNU coreutils) -------------------------------
# Linux 는 보통 `timeout`, macOS(coreutils 설치 시)는 `gtimeout`. 둘 다 없으면
# 순수 bash 폴백을 쓴다. bash 3.2(macOS 기본)에서도 동작하도록 연관배열 미사용.
if command -v timeout >/dev/null 2>&1; then
  TIMEOUT_CMD=timeout
elif command -v gtimeout >/dev/null 2>&1; then
  TIMEOUT_CMD=gtimeout
else
  TIMEOUT_CMD=""
fi

# timeout 명령이 있으면 그대로, 없으면 background + watcher 로 직접 구현.
# 타임아웃으로 죽인 경우 124 를 반환하여 GNU timeout 과 동일하게 분류되게 한다.
run_with_timeout() {
  _secs="$1"; shift
  if [ -n "$TIMEOUT_CMD" ]; then
    "$TIMEOUT_CMD" "$_secs" "$@"
    return $?
  fi
  "$@" &
  _cmd_pid=$!
  ( sleep "$_secs"; kill -TERM "$_cmd_pid" 2>/dev/null ) &
  _watcher_pid=$!
  _rc=0
  wait "$_cmd_pid" 2>/dev/null || _rc=$?
  # watcher 가 아직 살아있으면(sleep 중) 명령이 먼저 끝난 것 → watcher 를 정리한다.
  # 이미 죽었으면 sleep 을 마치고 kill 을 실행한 것 → 타임아웃(124)이다. 종료코드
  # 추측(143) 대신 watcher 생존으로 판정해 다른 이유의 SIGTERM 을 오분류하지 않는다.
  if kill -0 "$_watcher_pid" 2>/dev/null; then
    kill -TERM "$_watcher_pid" 2>/dev/null
    wait "$_watcher_pid" 2>/dev/null || true
  else
    _rc=124
  fi
  return $_rc
}

# realpath 폴백: macOS 구버전엔 realpath 가 없을 수 있다. 인자는 모두 디렉토리이므로
# `cd && pwd -P` 로 동일한 정규화(symlink 해소)를 얻는다.
resolve_path() {
  if command -v realpath >/dev/null 2>&1; then
    realpath "$1" 2>/dev/null || echo "$1"
  else
    ( cd "$1" 2>/dev/null && pwd -P ) || echo "$1"
  fi
}

# --- Dedup by realpath (연관배열 없이, bash 3.2 호환) -----------------------
# symlink/중복 인자가 같은 물리 레포를 가리키면 첫 번째만 유지. 개행 구분 문자열에
# 정확한 한 줄 매칭(grep -qxF)으로 멤버십을 검사한다.
SEEN_LIST=""
REPOS=()
for _arg in "$@"; do
  _real=$(resolve_path "$_arg")
  if ! printf '%s\n' "$SEEN_LIST" | grep -qxF -- "$_real"; then
    SEEN_LIST="$SEEN_LIST
$_real"
    REPOS+=("$_arg")
  fi
done

i=0
for REPO in "${REPOS[@]}"; do
(
  # 출력 파일명은 레포 경로가 아니라 루프 인덱스로 짓는다 — 경로를 tr '/ ' '__' 로
  # 치환하면 서로 다른 경로('a/b'와 'a b')가 같은 이름으로 충돌해 한 레포 결과가
  # 다른 레포에 덮어써진다. 인덱스는 항상 숫자라 충돌도 dotfile 문제도 없다.
  SAFE_NAME=$i
  OUT="$WORKDIR/repo_$SAFE_NAME.txt"

  # Fetch (with timeout). 종료코드는 인라인 캡처 — set -e 부재로 실패해도 계속 진행.
  FETCH_EXIT=0
  run_with_timeout "$FETCH_TIMEOUT" git -C "$REPO" fetch --all --prune --quiet 2>/dev/null || FETCH_EXIT=$?

  # Branch
  BRANCH=$(git -C "$REPO" branch --show-current 2>/dev/null || echo "")
  [ -z "$BRANCH" ] && BRANCH="(detached)"

  # Status는 리포트용으로만 캡처. DIRTY 사전 분류는 하지 않는다 — 그냥 pull --rebase를
  # 시도하고 충돌/차단은 git이 스스로 거부하거나 REBASE_CONFLICT abort 경로로 잡히게 한다.
  STATUS=$(git -C "$REPO" status --porcelain 2>/dev/null || echo "")

  # Behind/ahead
  BEHIND=$(git -C "$REPO" rev-list --count HEAD..@{upstream} 2>/dev/null || echo "-")
  AHEAD=$(git -C "$REPO" rev-list --count @{upstream}..HEAD 2>/dev/null || echo "-")

  # Unpushed commits (상세)
  UNPUSHED=""
  if [ "$AHEAD" != "0" ] && [ "$AHEAD" != "-" ]; then
    UNPUSHED=$(git -C "$REPO" log --format="%h %s (%an · %cr)" @{upstream}..HEAD 2>/dev/null || echo "")
  fi

  # Classify — DIRTY는 더 이상 사전 분류하지 않는다. 리포트 상태는 pull 결과에 의해 결정됨.
  if [ "$FETCH_EXIT" -eq 124 ]; then
    STATE="TIMEOUT"
  elif [ "$FETCH_EXIT" -ne 0 ]; then
    STATE="ERROR"
  elif [ "$BEHIND" = "-" ] || [ -z "$BEHIND" ]; then
    STATE="NO_UPSTREAM"
  elif [ "$BEHIND" != "0" ]; then
    STATE="OUTDATED"
  else
    STATE="CURRENT"
  fi

  # Write base result
  {
    echo "===REPO==="
    echo "PATH:$REPO"
    echo "BRANCH:$BRANCH"
    echo "STATE:$STATE"
    echo "BEHIND:$BEHIND"
    echo "AHEAD:$AHEAD"
    if [ -n "$STATUS" ]; then
      echo "STATUS_START"
      echo "$STATUS"
      echo "STATUS_END"
    fi
    if [ -n "$UNPUSHED" ]; then
      echo "UNPUSHED_START"
      echo "$UNPUSHED"
      echo "UNPUSHED_END"
    fi
  } > "$OUT"

  # Pull if OUTDATED — rebase 우선, 충돌 시 abort하여 깨끗한 상태 유지
  if [ "$STATE" = "OUTDATED" ]; then
    BEFORE=$(git -C "$REPO" rev-parse HEAD 2>/dev/null || echo "")
    UPSTREAM_SHA=$(git -C "$REPO" rev-parse '@{upstream}' 2>/dev/null || echo "")
    PULL_EXIT=0
    PULL_OUTPUT=$(git -C "$REPO" pull --rebase 2>&1) || PULL_EXIT=$?

    # 중간 rebase 상태가 남아있으면 (= 충돌) abort하여 원상 복구
    REBASE_ABORTED=""
    # --git-path 는 상대경로(.git/rebase-merge)를 반환하므로, 절대 git-dir 기준으로
    # 체크해야 스크립트 cwd 가 아닌 레포 안의 rebase 진행 상태를 본다.
    GIT_DIR_ABS=$(git -C "$REPO" rev-parse --absolute-git-dir 2>/dev/null || echo "")
    if [ "$PULL_EXIT" -ne 0 ] && [ -n "$GIT_DIR_ABS" ] && { [ -d "$GIT_DIR_ABS/rebase-merge" ] || [ -d "$GIT_DIR_ABS/rebase-apply" ]; }; then
      git -C "$REPO" rebase --abort 2>/dev/null || true
      REBASE_ABORTED="yes"
    fi

    AFTER=$(git -C "$REPO" rev-parse HEAD 2>/dev/null || echo "")

    {
      echo "PULL_EXIT:$PULL_EXIT"
      if [ "$PULL_EXIT" -eq 0 ] && [ -n "$BEFORE" ] && [ "$BEFORE" != "$AFTER" ]; then
        echo "UPDATED:yes"
        # 업스트림 기준으로 순수 원격 변경만 리포트 (로컬 rebase된 커밋 제외)
        echo "NEW_COMMITS_START"
        git -C "$REPO" log --format="%h %s (%an · %cr)" "$BEFORE".."$UPSTREAM_SHA" 2>/dev/null || true
        echo "NEW_COMMITS_END"
        echo "DIFF_STAT_START"
        git -C "$REPO" diff --stat "$BEFORE"..."$UPSTREAM_SHA" 2>/dev/null || true
        echo "DIFF_STAT_END"
        echo "DIFF_START"
        # 3-dot(merge-base 기준)으로 incoming 변경만 표시 — 2-dot 은 로컬 전용 커밋을
        # 삭제(deletion)로 뒤집어 보여준다. 300줄까지 출력하고 더 있으면 잘림 표시 후
        # 즉시 종료(git 은 SIGPIPE)해 큰 diff 를 통째로 읽지 않는다.
        git -C "$REPO" diff --no-color "$BEFORE"..."$UPSTREAM_SHA" 2>/dev/null \
          | awk 'NR<=300; NR==301 { print "[... diff 가 길어 300줄에서 잘림 ...]"; exit }'
        echo "DIFF_END"
      elif [ -n "$REBASE_ABORTED" ]; then
        echo "REBASE_CONFLICT:yes"
        echo "PULL_ERROR_START"
        echo "$PULL_OUTPUT"
        echo "PULL_ERROR_END"
      elif [ "$PULL_EXIT" -ne 0 ]; then
        echo "PULL_ERROR_START"
        echo "$PULL_OUTPUT"
        echo "PULL_ERROR_END"
      fi
    } >> "$OUT"
  fi

  # Submodule check (if applicable). foreach 본문은 sh 로 실행되므로 bash 함수를 못 쓴다.
  # 2단 방어: (1) timeout 명령이 있으면 per-submodule prefix(TPREFIX)로 각 fetch 를 제한,
  # (2) 전체 foreach 를 run_with_timeout 으로 한 번 더 감싸 timeout 명령이 없는 시스템
  # (coreutils 미설치 macOS 등)에서도 무한 대기를 막는다. 둘 다 빠지면 submodule 원격이
  # 응답 없을 때 git fetch 가 무한정 매달려 전체 wait 를 블록할 수 있었다.
  if [ -f "$REPO/.gitmodules" ]; then
    TPREFIX="${TIMEOUT_CMD:+$TIMEOUT_CMD $FETCH_TIMEOUT }"
    # 출력은 `$()` 캡처가 아니라 파일로 리다이렉트한다. `$()` 는 파이프 write end 를 쥔
    # 모든 프로세스가 끝나야 반환하는데, 타임아웃으로 foreach 를 죽여도 orphan 이 된
    # git fetch/네트워크 헬퍼가 파이프를 계속 쥐고 있으면 `$()` 가 그만큼 블록된다.
    # 파일 리다이렉트면 run_with_timeout 의 wait 가 직접 자식(foreach)만 기다려 즉시 반환하고,
    # orphan 이 파일에 늦게 쓰든 말든 우리는 이미 읽은 뒤라 무관하다.
    # 파일명은 `.txt` 가 아니어야 최종 `cat "$WORKDIR"/*.txt` glob 에 안 걸린다.
    SUB_TMP="$WORKDIR/sub_$SAFE_NAME"
    run_with_timeout "$((FETCH_TIMEOUT * 4))" git -C "$REPO" submodule foreach --quiet "$TPREFIX"'git fetch --all --quiet 2>/dev/null
      UPDATES=$(git log --format="%h %s (%an · %cr)" HEAD..@{upstream} 2>/dev/null)
      if [ -n "$UPDATES" ]; then
        echo "SUBMODULE:$displaypath"
        echo "$UPDATES"
      fi' > "$SUB_TMP" 2>/dev/null || true
    if [ -s "$SUB_TMP" ]; then
      echo "SUBMODULE_START" >> "$OUT"
      cat "$SUB_TMP" >> "$OUT"
      echo "SUBMODULE_END" >> "$OUT"
    fi
  fi
) &
  i=$((i+1))
done
wait

# 결과 출력
cat "$WORKDIR"/*.txt 2>/dev/null || true
rm -rf "$WORKDIR"
