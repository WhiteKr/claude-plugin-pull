# pull

작업 디렉토리(`$CWD`) 하위의 모든 git 레포와 settings의 `additionalDirectories`에 등록된 외부 워크스페이스를 찾아, outdated된 레포만 골라 병렬로 `git pull --rebase` 합니다.

## 사용

```
/pull            # 전체 대상
/pull BE.Main    # 인자를 포함하는 레포만
```

## 동작

- 모든 레포를 **병렬 fetch** 후, behind 상태인 것만 `git pull --rebase`.
- rebase 충돌 시 즉시 `rebase --abort`로 원상 복구하고 `Conflict`로 표시 (HEAD 안 건드림).
- submodule 원격 업데이트도 함께 보고.

## 호환성

`scripts/triage.sh`는 Linux / macOS / WSL에서 동작합니다. `timeout`/`gtimeout`이 없으면 순수 bash 폴백, `realpath`가 없으면 `cd && pwd -P` 폴백을 사용하며 bash 3.2와 호환됩니다.
