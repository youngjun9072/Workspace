# CBRD-27508 코어 커밋 계획

> 최신 develop 기반 `feature/CBRD-27508-parallel-applylogdb-writeset`에 writeset 코어를 **큰 덩어리 논리 커밋**으로 올린다. `db_restart_sub`(CS팀 세션부트)와 `la_gate_*` 모듈화는 **보류**(00-overview 참조), 코어부터.

## 원칙
- 각 커밋 = 설계문서 한 단위, 가능하면 빌드 단위. 계측(do-not-merge)은 코어에 안 섞음.
- 기능 초안 커밋과 리뷰 정제 커밋을 분리한다. 두 커밋의 diff에서 확인한 함수·주석·오류 처리 기준을 다음 모듈(worker 등)의 구현 기준으로 사용한다.
- 결정 반영: 자료구조 처음부터 **TBB/std 선택대로**, 설정 **ha_* 시스템파라미터**, 워커 부트는 **옵션 2 인터페이스 + 단순 부트**.
- PoC(`feature/writeset_error_skip`)는 레퍼런스. 옮길 땐 develop 적응(atomic LSA 등) 후 얹기.

---

## 마스터

### C1. writeset 자료구조 + 전역 history map
- **파일**: 신규 `src/transaction/writeset.c/.h` (충돌 없음, 신규 파일).
- **내용**: `LOG_WSET_HASH`(FNV-1a 64bit), `LOG_WSET_SLOTS`(write_seq/read_seq), 트랜잭션 로컬 `ws_hashes`.
- **history map = TBB `tbb::concurrent_hash_map`** (서버·SA에 TBB 이미 링크 → 추가 작업 없음). const_accessor 조회 / accessor 갱신, entry 하나씩 잡고 즉시 해제.
- **크기 = `ha_writeset_history_size`(가칭) 시스템파라미터** (`PRM_FOR_SERVER | PRM_FOR_HA`, `cubrid_ha.conf`). system_parameter.c/.h에 추가.
- **근거**: 6-1, 8-1. **검증**: 유닛(맵 put/get/clear, 해시 단가).

### C2. 커밋 시 키 수집 + dependency probe + 게시
- **파일**: `log_manager.c`(commit 경로), `writeset.c`.
- **내용**: `wset_commit_probe`(write_seq/read_seq 선택, `is_ref`), `wset_commit_flush`(게시), commit 직전 `LOG_DUMMY_WSET_LABEL`(dependency_seq, is_ref) 기록.
- **게이팅**: 기존 `log_does_allow_replication()` + `#if SERVER_MODE||SA_MODE` 구조 유지(비-HA 오버헤드 0, 추가 게이팅 불필요).
- **불변식**: §10 마스터 #7·#8·#9(REF는 이전 WRITE만, WRITE는 둘 다, write_seq=본인/ref_seq=max).
- **근거**: 6-1, 8-1. **검증**: 유닛(경합·FK 스트레스), 마스터 per-tx probe 라벨.

---

## 슬레이브

### C3. coordinator → task 구성 (+ atomic LSA 적응)
- **파일**: `log_applier.c`.
- **내용**: `LA_APPLY_TASK`(apply 포인터 + commit_lsa + dependency_seq + is_ref), WSET_LABEL 디코드, 같은 trid 라벨·COMMIT 결합, repl_list 포인터 핸드오프.
- **★develop 적응**: `la_apply_log_file`이 유일 충돌 함수(develop atomic LSA ±32 / PoC ±444). append_lsa 읽는 곳은 `load()`로 전환, PoC 변경을 develop atomic-LSA 위에 재적용. (상세 `02-develop-adaptation.md`)
- **근거**: 6-2, 8-2. **검증**: 라벨→task 매핑, 독립 tx 즉시 dispatch 비율.

### C4. 게이트 (frontier + completed set + pending/drain)
- **파일**: `log_applier.c` (`la_gate_*`).
- **내용**: `la_gate_is_satisfied` ①②③, `la_Gate_frontier`(gap-free), **completed set = `std::unordered_map`(자동 성장, coordinator 단일스레드라 동시성 불필요 — 고정 2^18 overflow 중단 제거)**, pending 큐 + `drain_ready`.
- **불변식**: 슬레이브 #3·#4·#5·#9(dep≤frontier / is_ref는 frontier만 / WRITE는 완료집합 멤버십 / frontier gap-free).
- **근거**: 6-2, 8-2, "게이트 세판정" 설명서. **검증**: is_ref 부모-자식 순서(위반=무성이라 필수), Long-tx 뒤 독립 tx ③ 통과.

### C5. worker + 결과 수거 + retire (옵션 2 인터페이스)
- **파일**: `log_applier_task.hpp`, `log_applier_worker.hpp/.cpp`, 후속 연결 시 `log_applier.c`.
- **내용**: 워커층을 **얇은 인터페이스**(spawn N / submit task / collect result) 뒤로 둔다. **구현은 pthread**(백업·CBRD-26484 관행), 세션 부트는 **단순 방식**(db_restart_sub 보류 → 나중 교체)으로 시작한다. queue는 worker별로 나누지 않고 **공용 bounded task ring buffer 하나와 공용 자동 성장 result FIFO 하나**를 둔다. task queue 포화는 coordinator의 result 수거·retire를 유도하고, result queue의 메모리 상한은 전체 미완료 task 한도로 제어한다.
- 결과 수거 → `mark_completed` → `advance_frontier` → `drain_ready` → 커밋순서 `retire`(슬롯 반환은 coordinator, 아이템 해제는 워커).
- **불변식**: 슬레이브 #7·#8·#10(워커는 result만, 성공 COMMIT만 completed, committed_lsa는 frontier까지).
- **근거**: 6-2, 8-2. **검증**: 병렬 apply span, 워커별 fail 0.

---

## 안정성·마무리

### C6. committed_lsa(frontier) + 복구 3구간 + error-skip
- **내용**: committed_lsa는 frontier로만 전진, 재시작 recovery_boundary 3구간(skip / 복구재시도 / 정상), 제한적 error-skip(INSERT dup / UPDATE·DELETE 대상없음).
- **근거**: 7, 8-2.2.5. **검증**: 재시작 멱등(백로그 재적용), hole 복구.

### C7. CS 하드닝 이월 (PoC 검증분)
- fileio pread/pwrite(클라이언트), shared-fd race, page-0 가드 — PoC의 검증된 실수정. develop 기준 재확인 후 이월.

### C8. 유닛테스트
- Catch2: writeset 해시단가/경합/FK 스트레스. 계측 필드는 정식에서 분리.

---

## 보류·후속 (코어 후)
- **db_restart_sub 포팅** — 별도 집중 태스크(00-overview 보류 절).
- **`la_gate_*` 모듈화**(별도 디렉토리) — file-static 상태 이전 필요, 보통~큼(05 분석). 코어 안정 후 판단.
- **MySQL 컨테이너 비교** — 별도 트랙.

## 미확정 (구현 전 확인)
- `cs/CMakeLists.txt` TBB 링크 추가 실빌드(C5 큐 전제).
- 신규 `ha_*`(PRM_FOR_SERVER) 파라미터가 cub_server까지 로드되는 경로.
- `la_gate_*` file-static 상태 완전 목록(모듈화 시).
