# PR #8052 writeset 구현 기록

현재 구현 기준은 CUBRID PR #8052의 HEAD `ccc63cf59979fc01b6210778c9325ad8662a9d90`이다. 구현의 주 흐름은 `_impl`의 두 문서에 기록한다.

1. [마스터 writeset 구현](../01-master-implementation-design.md): 제약 키 수집, history probe·publish, dependency 라벨, 독립 sysop의 commit-order 처리
2. [슬레이브 병렬 적용 구현](../02-slave-implementation-design.md): 로그에서 task 구성, 공용 queue와 worker session, frontier gate, apply info와 재시작

```text
마스터 행 변경 → WRITE·REF 수집 → history probe
  → WSET_LABEL·COMMIT 기록 → history 게시

슬레이브 로그 읽기 → LA_APPLY와 라벨로 task 구성
  → frontier gate → 공용 task queue → worker DB COMMIT
  → 공용 result queue → frontier·committed_lsa 갱신
```

이 디렉터리에는 PR 작업 중 작성한 검증 계획, 코드 리뷰와 대안·수정 과정이 남아 있다. 시점별 판단과 미구현 목표안이 섞여 있으므로 PR의 현재 동작을 확인할 때는 위 두 구현 문서와 실제 코드를 기준으로 한다. 이전 마스터 초안은 `01-master-pre-pr-8052.md`에 보존했다.
