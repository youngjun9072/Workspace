# CBRD-27508 writeset 페르소나 코드 리뷰

## 1. 검토 기준

- 대상 브랜치: `feature/CBRD-27508-parallel-applylogdb-writeset`
- 대상 커밋: `74f9e0a1c650d23442cd51b12e7df5d8403dd2bb`
- 코드 기준: `develop...HEAD`의 변경 파일과 변경 함수의 caller·callee
- 문서 기준: `_impl`의 공유 설계문서와 `_notes`의 분석문서
- 제외 문서: `agent-handoff.md`, `00-overview-raw.md`, `01-commit-plan.md`
- 검토 방식: 주석만으로 판단하지 않고 함수 본문, 하위 호출, 커밋·복구·복제 적용 경로를 함께 확인했다.
- 범위: writeset 키 수집, history, dependency label, 로그·복구 배선, 관련 테스트만 검토했다. 주변 코드의 기존 문제는 이번 변경에 영향을 주는 경우만 포함했다.

페르소나별 최대 30개를 목표로 했지만 개수를 채우기 위한 항목은 만들지 않았다. 독립 검토 결과는 1년차 11건, 3년차 14건, 5년차 11건, 10년차 16건이며, 같은 원인을 지적한 항목은 아래 통합 목록에서 하나로 합쳤다.

## 2. 결론

현재 브랜치는 키 수집과 기본 WRITE·REF history 동작까지는 구현했지만, 병렬 applier와 연결하기 전에 해결해야 할 정합성 문제가 남아 있다. 특히 다음 여섯 항목은 수정 또는 명시적인 범위 결정 전에는 병합하기 어렵다.

1. out-of-order publish와 clear가 겹치면 최신 history를 지우고도 더 오래된 `history_start`만 남길 수 있다.
2. `prev_commit_lsa`와 `history_start`를 서로 다른 시점에 읽은 뒤 `min`을 선택하여 clear의 하한을 다시 낮출 수 있다.
3. `dependency_is_ref` 하나로 REF, commit-order fallback, `history_start`의 연속 완료 요구를 모두 표현하지 못한다.
4. 문자열을 포함한 복합 키는 단일 문자열과 달리 collation 동등성으로 정규화되지 않는다.
5. 독립 top operation과 2PC 경로에는 설계된 probe·label·publish가 없다.
6. `WSET_LABEL` 할당 실패 후에도 COMMIT과 history publish가 계속된다.

### 구현 순서 결정 (2026-09-30)

어플라이어 병렬화의 기반 작업을 시작하기 전에는 R01·R02·R05를 먼저 수정하고 하나의 마스터 history 동시성 변경으로 검증한다. 나머지 항목은 worker·queue·완료 집합·연속 완료 경계의 기반 구현 뒤 해당 기능을 연결하는 단계에서 처리한다.

- R03은 dependency gate를 연결할 때 `dependency_is_ref`를 `dependency_requires_frontier` 의미로 다시 정의하고, REF·`history_start`·commit-order 폴백·복수 dependency 축약을 함께 반영한다.
- R04는 어플라이어의 연속 완료 경계와 pending 재판정이 구현된 뒤 재시작 epoch 장벽으로 연결한다.
- R06은 복합 키와 collation의 production 수집 경로 검증 단계에서 처리한다.
- R09·R13은 `WSET_LABEL` decoder와 end-to-end 로그 전달을 연결하기 전에 오류 계약과 고정 폭 로그 형식을 확정한다.
- sysop·2PC는 기본 로컬 COMMIT 병렬 적용이 동작한 뒤 지원 범위와 보수 처리 방식을 확정한다.

이 순서는 항목을 폐기한다는 뜻이 아니다. 어플라이어 기반 구조와 직접 관계없는 마스터 후속 항목을 먼저 구현하느라 병렬화 착수가 지연되지 않도록 구현 시점을 나눈 것이다.

## 3. 통합 발견 사항

### R01. Critical — 늦게 publish한 과거 COMMIT의 clear가 더 최신 history를 삭제한다

- 코드: `writeset.cpp:940-1018`, `wset_publish_commit_to_history()`, `wset_clear_history_with_lock()`, `wset_publish_with_capacity()`
- 설계: `01-master-implementation-design.md` §4, §7
- 호출 경로: `log_commit_local()` → COMMIT LSA 할당 → `wset_publish_commit_to_history()` → baseline 전진 → history clear 또는 publish
- 재현:
  1. T1이 COMMIT LSA 100을 할당받고 publish 전에 멈춘다.
  2. T2가 LSA 110을 할당받아 키 K를 history에 게시한다.
  3. T1이 뒤늦게 overflow 또는 capacity clear를 수행한다.
  4. map의 K=110은 삭제되지만 `history_start`는 100만 남는다.
  5. T3가 K를 조회하면 T2=110을 발견하지 못하고 100만 기다린다.
- 영향: T3가 슬레이브에서 T2보다 먼저 적용되어 동일 키·UNIQUE·FK 순서를 깨뜨릴 수 있다.
- 권고: clear의 floor를 최소 `max(clear 요청 COMMIT, 동기화된 prev_commit_lsa, 삭제 대상의 최대 LSA)`로 만들고, baseline·map·floor의 전환을 하나의 원자적 프로토콜로 정의한다.
- 발견: 3년차, 5년차, 10년차

### R02. Critical — probe가 clear 이후의 `history_start`를 과거 baseline으로 다시 낮춘다

- 코드: `writeset.cpp:826-899`, `wset_find_dependency_from_history()`
- 설계: `01-master-implementation-design.md` §4~§5, [[07-probe-snapshot-consistency|writeset dependency probe 스냅샷 일관성 설계]]
- 재현:
  1. probe가 `prev_commit_lsa=100`을 읽고 `seq_lock`을 놓는다.
  2. 다른 커밋이 map을 clear하고 `history_start=200`을 기록한다.
  3. probe는 `history_lock` 아래에서 200을 읽는다.
  4. 마지막 `min(wset_parent, prev_commit_snapshot)`이 dependency를 다시 100으로 낮춘다.
- 영향: clear로 삭제한 모든 관계를 보호해야 하는 floor를 건너뛴다.
- 개선: probe도 clear와 같은 `seq_lock → history_lock` 순서로 진입해 두 상태를 일관된 스냅샷으로 읽고, 최종 dependency에 `history_start` 하한을 적용한다.
- 발견: 1년차, 3년차, 5년차, 10년차

### R03. Critical — dependency 값과 대기 방식의 집계가 불완전하다

- 코드: `writeset.cpp:763-907`, `log_record.hpp:257-264`
- 설계: `01-master-implementation-design.md` §5·§7, `02-slave-implementation-design.md` §4, `_notes/07-poc-productization-followups.md`
- 현재 동작:
  - 최종 최대 후보가 `ref_seq`일 때만 `wset_dependency_is_ref=true`다.
  - overflow의 `prev_commit_lsa`와 `history_start`는 false다.
  - 키 A의 REF 후보가 100이고 키 B의 WRITE 후보가 110이면 결과는 `{110, false}`다.
- 문제: 110 한 트랜잭션의 완료가 100 이하의 모든 REF sibling 완료를 보장하지 않는다. commit-order fallback과 clear floor도 특정 한 건이 아니라 해당 지점까지의 연속 완료가 필요하다.
- 영향: slave gate가 아직 남은 hole을 건너뛰고 부모 WRITE 또는 보수 처리 트랜잭션을 실행할 수 있다.
- 권고: 필드 의미를 후보 출처가 아닌 `dependency_requires_frontier`로 정의한다. 모든 후보의 frontier 요구를 OR 집계하고, overflow와 `history_start`는 반드시 frontier 대기로 전달한다. 필요하면 exact dependency와 frontier dependency를 별도 필드로 보존한다.
- 발견: 전 페르소나

### R04. High — 서버 재시작 전후의 history epoch를 연결하는 장벽이 없다

- 코드: `writeset.cpp:285-332`, `log_tran_table.c:505-510`, `boot_sr.c:3889-3897`
- 설계: `01-master-implementation-design.md` §4, `02-slave-implementation-design.md` §7, `03-verification-plan.md` §4
- 근거: 프로세스 재시작 시 map, `history_start`, `prev_commit_lsa`가 모두 빈 상태로 시작하며, 복구 로그에서 다시 구성하거나 마지막 EOT LSA로 seed하는 경로가 없다.
- 영향: standby에 재시작 전 backlog가 남아 있는데 재시작 후 동일 키 트랜잭션이 NULL dependency를 받으면 과거 task를 추월할 수 있다.
- 권고: recovery 완료 LSA를 frontier-required floor로 seed하거나, 로그 epoch 변경 레코드를 slave의 drain barrier로 사용한다. 어떤 방식을 쓰는지 마스터·슬레이브 설계에 함께 명시한다.
- 심각도 조건: 병렬 slave와 재시작 backlog 처리를 이번 release 범위에 포함하면 직접적인 순서 위반이므로 Critical로 올려야 한다. 현재 High는 master-side 중간 구현만 평가한다는 전제다.
- 발견: 1년차, 10년차

### R05. High — WRITE 슬롯이 hash collision의 out-of-order publish로 후퇴할 수 있다

- 코드: `writeset_history_map.cpp:49-73`, `wset_history_map::publish()`
- 설계: `01-master-implementation-design.md` §4, §6
- 근거: REF는 `max(ref_seq, commit_lsa)`로 갱신하지만 WRITE는 무조건 대입한다. 실제 동일 키는 DB lock이 publish 순서를 직렬화하더라도, 서로 다른 키가 같은 hash에 매핑되면 DB lock 관계가 없다. 특히 문자열은 collation pseudo key가 32비트라 같은 인덱스에서 collision 가능성이 64비트 원본보다 높다.
- 재현: 충돌 슬롯에 LSA 200이 먼저 게시되고, 늦게 끝난 LSA 100이 덮어쓰면 슬롯이 100으로 후퇴한다. 이후 실제 200 키와 같은 키를 쓰는 트랜잭션은 200을 발견하지 못한다.
- 권고: `write_seq`도 `max(write_seq, commit_lsa)`로 단조 갱신하고 동시성 테스트가 최댓값을 요구하게 한다.
- 발견: 3년차, 10년차

### R06. High — 문자열을 포함한 복합 키가 collation 동등성을 보존하지 않는다

- 코드: `writeset.cpp:247-273`, `wset_string_hash()`; `wset_make_parent_midxkey()`; `wset_add_ref_key()`
- 하위 호출: `pr_midxkey_add_elements()` → 각 원소의 `index_writeval()`; 이후 `or_pack_mem_value()`
- 설계: `01-master-implementation-design.md` §2.4~§2.5
- 근거: 단일 문자열은 collation의 `mht2str` 결과를 해시하지만 `DB_TYPE_MIDXKEY`는 packed tuple 전체를 그대로 해시한다. MIDXKEY의 문자열 원소는 B-tree 비교 시 collation을 사용하지만 저장 바이트 자체가 collation 동등 문자열을 같은 바이트로 정규화하지는 않는다.
- 예: case-insensitive collation의 복합 PK `(varchar, int)`에서 `('A', 1)`과 `('a', 1)`은 제약조건상 같지만 다른 hash가 될 수 있다.
- 영향: 복합 UNIQUE 또는 부모 복합 PK WRITE와 자식 FK REF의 의존성이 누락될 수 있다.
- 권고: MIDXKEY를 원소별로 처리하여 문자열은 부모 도메인의 collation hash를 사용하고 나머지는 canonical 표현을 hash-combine한다. 문자열을 포함한 복합 WRITE·REF 동치 테스트를 추가한다.
- 발견: 5년차, 10년차

### R07. High — 독립 top operation의 writeset fragment 처리가 구현되지 않았다

- 코드: `log_manager.c:3896-3977`, `log_sysop_commit_internal()`; `log_append_sysop_end()`
- 설계: `01-master-implementation-design.md` §6
- 근거: sysop은 `log_append_repl_info(..., false)` 후 `LOG_SYSOP_END`를 기록하지만, sysop 시작 시 writeset 경계를 보존하지 않고 해당 fragment의 probe·label·publish·제거도 수행하지 않는다. `db_serial` 변경은 generic UPDATE 경로에서 PK WRITE로 수집될 수 있지만, 이를 sysop fragment에 귀속하고 게시하는 serial 전용 경로는 없다.
- 영향: slave가 별도 task로 처리할 `LOG_SYSOP_END`에 dependency가 없고, 이미 영구 반영된 fragment의 키가 바깥 COMMIT까지 게시되지 않는다. 바깥 트랜잭션이 abort하는 경우에는 task와 writeset의 소유 관계도 어긋난다.
- 권고: top operation stack에 writeset 시작 위치를 저장하고 `WSET_LABEL → LOG_SYSOP_END → publish`를 fragment 단위로 수행한다. serial과 statement sysop의 보수 경로를 함께 구현한다.
- 발견: 전 페르소나

### R08. High — 2PC 완료와 descriptor 이동에 writeset 상태가 연결되지 않았다

- 코드: `log_manager.c:5309-5342`, `6080-6110`; `log_tran_table.c:6511-6579`, `log_tdes::copy_to()`
- 설계: `_notes/06-c2-code-design-raw.md` §7.1
- 근거:
  - local COMMIT만 probe·publish한다.
  - 2PC 완료는 공통 append 함수로 NULL 또는 stale label을 기록하지만 history에 게시하지 않는다.
  - loose-end descriptor 이전의 `copy_to()`는 `wset_hashes`, overflow, dependency 필드를 복사하지 않는다.
- 영향: HA 분산 트랜잭션을 지원 범위에 포함하면 동일 키 후행 트랜잭션과 순서가 끊긴다.
- 권고: 지원 시 2PC 최종 COMMIT에도 동일한 protocol을 배선하고 descriptor 상태를 move한다. 이번 버전에서 제외한다면 정상 독립 label을 기록하지 말고 명시적인 보수 장벽 또는 지원 제한을 둔다.
- 발견: 전 페르소나

### R09. High — WSET_LABEL 할당 실패가 COMMIT 실패로 전달되지 않는다

- 코드: `log_manager.c:4719-4766`, `log_append_wset_label_with_lock()`
- 설계: `01-master-implementation-design.md` §6
- 근거: `prior_lsa_alloc_and_copy_data()`가 NULL이면 `/* FIXME */ return;`만 수행한다. caller는 이어서 COMMIT을 기록하며, `log_commit_local()`은 history까지 게시한다.
- 영향: COMMIT은 있으나 dependency label은 없는 로그가 만들어진다. future slave는 malformed task로 중단하거나 잘못 독립 처리할 수 있다.
- 권고: label append 실패를 상위로 전달하고 COMMIT·publish를 계속하지 않는 정책을 구현한다. 다만 현재 commit append API 자체가 `void`인 기존 구조와 `TRAN_UNACTIVE_WILL_COMMIT` 상태를 함께 고려하여 실패 복구 계약부터 확정해야 한다.
- 발견: 전 페르소나

### R10. High(rolling upgrade 지원 시) — 신규 로그 타입의 호환 계약이 없다

- 코드: `log_record.hpp`의 `LOG_DUMMY_WSET_LABEL=53`; `log_applier.c:6336-6350`
- 근거: develop의 `LOG_LARGER_LOGREC_TYPE` 값은 53이다. 새 master가 타입 53을 기록하면 구버전 applylogdb는 이를 범위 밖 레코드로 판단하여 `ER_LOG_PAGE_CORRUPTED`로 종료한다. 새 브랜치의 기존 직렬 applier는 새 타입을 범위 안 레코드로 인정하지만 payload는 아직 소비하지 않고 건너뛴다.
- 영향: master-first rolling upgrade에서 첫 복제 COMMIT부터 apply가 중단될 수 있다.
- 권고: slave-first 업그레이드를 강제·문서화하거나, peer capability에 따른 label 방출 gate 또는 호환 포맷을 설계한다.
- 발견: 5년차, 10년차

### R11. Medium — history capacity 검사가 동시 publish를 예약하지 않는다

- 코드: `writeset.cpp:965-1018`
- 근거: 여러 thread가 shared `history_lock` 아래 동일한 `map.size()`를 보고 모두 통과한 뒤 서로 다른 신규 키를 삽입할 수 있다.
- 영향: `history_size`는 엄격한 메모리 상한이 아니며 활성 publisher 수와 transaction 크기만큼 초과할 수 있다.
- 권고: 신규 키 수 reservation, 별도 원자 count 또는 exclusive recheck를 도입한다. raw vector 길이가 아니라 실제 신규 distinct key 수를 기준으로 해야 한다.
- 발견: 5년차, 10년차

### R12. Medium — rollback·중복 키가 로컬 한도와 전역 clear를 불필요하게 소모한다

- 코드: `writeset.cpp:348-395`; `log_tran_table.c`의 descriptor 최종 clear
- 설계: `01-master-implementation-design.md` §3
- 근거: `{hash, kind}` dedup이 없고 savepoint 또는 statement rollback 시점의 writeset 경계를 복원하는 배선도 없다. UPDATE는 `same_key`를 계산한 뒤에도 old와 new를 모두 수집하여 설계 §2.2의 “값이 바뀌면 new key”와 다르다.
- 영향: 최종 COMMIT에 남지 않은 변경과 동일 키 반복 변경 때문에 overflow·commit-order fallback·전체 history clear가 발생할 수 있다. 정합성보다는 병렬성과 메모리 문제다.
- 권고: old는 항상, new는 값이 달라질 때만 수집하고 transaction-local dedup 또는 savepoint별 경계 복원을 검토한다. filtered index는 `do_delete_only`·`do_insert_only` 등 old/new row image의 predicate 포함 여부에 맞춰 실제 index에 들어가는 키만 수집해야 한다.
- 발견: 전 페르소나

### R13. Medium — WSET_LABEL의 release 로그에 초기화되지 않은 padding이 기록될 수 있다

- 코드: `log_record.hpp:257-264`; `log_append.cpp:prior_lsa_gen_record()`; `log_manager.c:4749-4765`
- 근거: `LOG_REC_WSET_LABEL`은 `LOG_LSA` 뒤에 `bool`이 있어 tail padding이 생길 수 있다. `prior_lsa_gen_record()`는 `NDEBUG`가 아닐 때만 data header를 zero-fill하고, release에서는 malloc한 `sizeof(LOG_REC_WSET_LABEL)` 전체를 그대로 로그에 쓴다.
- 영향: 로그가 비결정적이고 heap의 잔여 바이트를 디스크에 기록할 수 있다. 기능 판정에는 bool만 사용하더라도 로그 포맷·보안 관점에서 피해야 한다.
- 권고: 구조체에 고정 폭 필드와 명시적 reserved 영역을 사용하거나, 모든 빌드에서 header를 zero-initialize한다.
- 발견: 10년차

### R14. Medium — log dump가 첫 WSET_LABEL에서 중단된다

- 코드: `log_manager.c:7060-7175`, `log_dump_record()`
- 근거: `log_to_string()`과 recovery traversal에는 신규 타입이 있지만 dump switch에는 case가 없다. default가 `log_lsa`를 NULL로 만든다.
- 영향: 신규 로그를 포함한 `diagdb`/log dump가 첫 label 뒤의 COMMIT과 후속 레코드를 보여주지 못한다.
- 권고: payload를 출력하거나 최소한 `sizeof(LOG_REC_WSET_LABEL)`을 읽어 다음 레코드까지 순회한다.
- 발견: 1년차, 5년차, 10년차

### R15. Medium — 성능·stress 테스트의 전제와 실제 실행 방식이 다르다

- 코드: `system_parameter.c:5585-5605`; `unit_tests/writeset/test_writeset_stress.cpp`; `unit_tests/writeset/CMakeLists.txt`
- 근거:
  - 실제 기본 history 크기는 1,000,000이고 10,000,000은 최댓값인데 테스트 주석은 10,000,000을 기본값으로 설명한다.
  - 8M preload 시나리오는 실제로 중간 clear가 발생하여 의도한 “큰 map hit” workload가 아니다.
  - 파일은 “명시적으로 `[stress]`를 실행”한다고 쓰지만 Catch2 tag가 `[stress]`라 binary를 인자 없이 실행하면 숨겨지지 않는다. benchmark도 같은 executable에 포함된다.
- 영향: 측정값이 문서화된 조건과 다르고, 일반 test 실행이 지나치게 오래 걸리거나 큰 메모리를 사용할 수 있다.
- 권고: 큰-map 테스트는 명시적으로 10M cap을 주고 map size를 assert한다. 장시간 테스트는 hidden tag(`[.stress]`) 또는 별도 target/executable로 분리한다.
- 발견: 1년차, 3년차, 10년차

### R16. Medium — unit test가 실제 DML·COMMIT·로그 경계를 검증하지 않는다

- 코드: `unit_tests/writeset/test_writeset_common.hpp`, `test_writeset*.cpp`
- 설계: `03-verification-plan.md` §1~§4
- 근거: 테스트는 수동 `LOG_TDES`와 `wset_add_*`, probe, publish를 직접 호출한다. locator의 old/new 수집, sysop·2PC, label serialization과 OOM, clear/probe interleaving, 재시작 epoch는 통과하지 않는다.
- 잘못된 oracle:
  - overflow 테스트는 현재 `wset_dependency_is_ref == false`를 정답으로 고정하여 R03의 잘못된 대기 의미를 보호한다.
  - same-hash 동시 publish 테스트는 최종 슬롯을 “어느 thread의 LSA든 가능”으로 인정한다. R05의 단조 갱신 규칙을 적용하면 가장 큰 COMMIT LSA만 정답이어야 한다.
- 영향: protocol 수준 결함이 있어도 순수 map 테스트는 통과할 수 있다.
- 권고: barrier 기반 결정적 동시성 테스트와 production caller를 통과하는 commit-log 통합 테스트를 별도 층으로 추가한다.
- 발견: 전 페르소나

### R17. Medium — 관측되지 않는 전역 atomic 통계가 키별 hot path에 있다

- 코드: `writeset.cpp:58-69`, `921-935`
- 근거: 모든 WRITE·REF publish마다 process-global atomic RMW를 수행하지만 조회 API나 perfmon 연결은 TODO 상태다.
- 영향: 큰 transaction과 다중 commit에서 cache-line 경합을 만들면서 운영상 사용할 수 없는 값만 누적한다.
- 권고: 모니터링 연결 전에는 제거하거나 thread-local/batched counter로 바꾼다.
- 발견: 3년차, 10년차

### R18. Low — trace level 3이 실제 키와 테이블 정보를 error log에 기록한다

- 코드: `writeset.cpp:wset_trace_collected_key()`, `wset_trace_key_source()`; `locator_sr.c:locator_wset_trace_key_source()`
- 영향: 진단에는 유용하지만 이메일·계정키 같은 UNIQUE 값과 테이블·제약 이름이 server error log에 남고, 대량 DML에서 로그량이 매우 커질 수 있다.
- 권고: 운영 문서에 민감정보와 성능 비용을 명시하고, 값 출력은 별도 위험 옵션·마스킹·샘플링 중 하나를 적용한다.
- 발견: 10년차

### R19. Low — `locator_sr.c` 변경에 writeset과 무관한 formatting diff가 섞여 있다

- 근거: `develop...HEAD`에서 `locator_sr.c`는 46개 hunk, `+270/-85`이며 writeset 진입점 밖의 lambda·개행·공백 변경이 다수 포함된다.
- 영향: 핵심 DML hook 리뷰가 어려워지고 추후 merge conflict 범위가 커진다.
- 권고: 기능 변경 hunk만 남도록 develop 형식으로 정리하거나 formatting 전용 commit을 분리한다.
- 발견: 10년차

### R20. Documentation — 구현 완료와 목표 설계가 구분되지 않는다

- 위치: `01-master-implementation-design.md` §6, `02-slave-implementation-design.md`
- 근거: master 문서는 label append 오류 전파, sysop fragment, serial 수집을 현재 동작처럼 기술하지만 브랜치에는 없다. slave 문서는 목표 설계이며 현재 branch의 `log_applier.c`는 label payload를 아직 소비하지 않는다.
- 권고: 각 절에 `구현됨`, `후속 구현`, `범위 제외` 상태를 표시한다. 특히 R01~R10 해결 전에는 문서의 완료 표현을 사용하지 않는다.
- 발견: 통합 검토

### R21. Documentation/Design gap — 키 패킹 실패의 오류 전파 계약이 현재 API와 연결되지 않는다

- 코드: `writeset.cpp`의 `wset_add_write_key()`, `wset_add_ref_key()`와 `or_pack_mem_value()` 호출
- 설계: `01-master-implementation-design.md` §7
- 근거: 설계는 키 크기 계산·패킹 실패 시 DML을 중단한다고 기술하지만, `or_pack_mem_value()`는 오류 코드를 반환하는 API가 아니며 기존 replication 경로도 같은 호출 방식을 사용한다. 현재 코드만으로는 어떤 하위 실패를 감지하여 writeset 오류로 바꿀지 확인할 수 없다.
- 판단: 지원되는 storage key의 정상 `DB_VALUE`에서 실제 결함이 발생한다고 단정할 근거는 부족하므로 런타임 버그로 분류하지 않는다. 다만 구현할 수 없는 오류 계약을 완료된 동작처럼 문서화해서도 안 된다.
- 권고: 감지 가능한 실패 조건, 확인할 상태, 반환할 오류를 구체화하거나 해당 약속을 설계에서 제거한다. WRITE와 REF가 동일한 pack-and-hash 계약을 사용하도록 정리한다.
- 발견: 1년차, 3년차

## 4. 페르소나별 리뷰 결과

### 4.1 1년차 개발자 관점 — 11건

코드를 처음 따라가는 관점에서 호출 흐름과 문서가 실제 구현을 정확히 안내하는지를 중점적으로 봤다.

1. R03 — flag 이름이 “출처”처럼 보이지만 실제로 필요한 것은 slave 대기 방식이다.
2. R04 — 초기화 문서만으로는 재시작 전후 순서가 어떻게 이어지는지 알 수 없다.
3. R02 — raw note의 “stale snapshot도 보수적” 설명이 실제 `min` 코드와 반대다.
4. R07 — 문서에 있는 sysop fragment 자료구조와 호출이 코드에 없다.
5. R08 — 공통 append 함수가 2PC에서도 label을 쓰지만 probe는 local 경로에만 있다.
6. R09 — `FIXME` 뒤에 COMMIT이 계속되는 사실이 함수 시그니처에서 드러나지 않는다.
7. R12 — 설계는 changed new key만 수집한다고 하지만 구현은 항상 두 키를 넣는다.
8. R14 — 로그 이름은 출력할 수 있지만 실제 dump는 신규 레코드를 넘지 못한다.
9. R15 — 테스트 주석의 기본값과 코드 기본값이 다르다.
10. R16 — 테스트 이름은 전체 기능처럼 보이지만 production caller를 지나지 않는다.
11. R21 — 설계의 패킹 오류 전파 약속을 현재 API에서 어떻게 확인하는지 알 수 없다.

### 4.2 3년차 개발자 관점 — 14건

함수 계약, 상태 소유권, 테스트 가능성과 일반적인 유지보수 위험을 중점적으로 봤다.

1. R03 — overflow와 floor의 frontier flag 누락
2. R03 — mixed REF·WRITE 후보의 대기 방식 손실
3. R01 — out-of-order clear가 최신 게시물을 제거
4. R02 — 두 락 사이의 비일관 snapshot
5. R08 — 2PC 최종 COMMIT probe·publish 누락
6. R07 — sysop writeset fragment 누락
7. R09 — label append 오류 반환 계약 부재
8. R05 — WRITE 슬롯의 비단조 갱신
9. R08 — `LOG_TDES::copy_to()`의 신규 상태 누락
10. R12 — UPDATE 중복 수집과 raw vector 한도 소모
11. R16 — integration·fault injection test 부재
12. R17 — 미노출 atomic counter의 hot-path 비용
13. R15 — benchmark cap 전제 불일치
14. R21 — 패킹 오류 전파 설계와 실제 API 계약 불일치

### 4.3 5년차 개발자 관점 — 11건

동시성 protocol, 로그 호환성, 장애·복구 경계를 중점적으로 봤다.

1. R01·R02 — clear와 probe의 원자성 결함
2. R03 — 단일 flag가 복수 선행조건을 손실
3. R06 — 복합 문자열 키의 collation false negative
4. R08 — 2PC 경로의 순서 누락
5. R07 — 독립 top operation의 영구 task 순서 누락
6. R09 — 부분 로그 기록 가능성
7. R10 — 구버전 applylogdb와의 로그 타입 비호환
8. R11 — capacity 동시 예약 부재
9. R12 — rollback·중복 키에 의한 전역 clear 증폭
10. R14 — 장애 분석용 log dump 중단
11. R16 — 실패 schedule을 재현하는 결정적 테스트 부재

### 4.4 10년차 개발자 관점 — 16건

배포 가능한 protocol인지, 장애·업그레이드·운영에서 안전한지를 중점적으로 봤다.

1. R01 — COMMIT LSA 순서와 publish 순서가 다를 때의 전역 불변식
2. R02 — baseline·floor·map의 원자 snapshot 부재
3. R03 — 로그 label이 slave의 실행 조건을 충분히 표현하지 못함
4. R04 — master restart epoch 연결 부재
5. R05 — hash collision을 false positive로만 유지하지 못하는 비단조 WRITE 슬롯
6. R06 — DBMS 동등성과 hash 동등성의 불일치
7. R07 — sysop이라는 별도 영구 커밋 단위 미지원
8. R08 — 2PC와 descriptor ownership 경계 미지원
9. R09 — atomic log group의 부분 기록 가능성
10. R10 — rolling upgrade protocol 부재
11. R11 — 운영 memory cap의 의미 불명확
12. R13 — on-disk raw struct와 release padding
13. R15 — 성능 검증 환경의 재현성 부족
14. R17 — 관측성 구현이 오히려 hot path를 오염
15. R18 — 진단 로그의 민감정보·용량 정책 부재
16. R19·R20 — 기능 diff와 설계 상태를 리뷰 가능한 단위로 분리할 필요

## 5. 검토했지만 확정 이슈로 올리지 않은 항목

- C++ `std::bad_alloc` catch: 프로젝트 일부 코드에 선례가 있어 이번 리뷰에서는 독립 결함으로 올리지 않았다.
- current applylogdb의 label 미해석: 같은 브랜치의 직렬 applier는 신규 타입을 범위 안 레코드로 인식하고 default skip하므로 현재 직렬 적용 자체가 깨지지는 않는다. 병렬 gate 구현 전에는 R20처럼 구현 상태를 명시해야 한다.
- 2PC: 이번 기능의 지원 범위에서 명시적으로 제외한다면 R08은 구현 결함이 아니라 release gate와 문서화 항목이 된다. 현재는 정상 label이 기록되므로 조용한 제외 상태가 아니라는 점은 해결해야 한다.

## 6. 권장 수정 순서

1. R01·R02·R03을 하나의 dependency protocol 재설계로 먼저 해결한다.
2. R05·R06으로 키별 history의 단조성과 DBMS 동등성을 보장한다.
3. R07·R08의 지원 범위를 확정하고, 지원하지 않는 경로는 보수 장벽으로 막는다.
4. R09·R10·R13·R14로 로그 포맷과 운영 도구의 완결성을 맞춘다.
5. R04 재시작 epoch를 slave drain·recovery 설계와 함께 확정한다.
6. 위 실패 schedule을 R16의 결정적 테스트로 먼저 고정한 뒤 성능·관측성 항목을 정리한다.

## 7. 검증 상태

- 코드 및 설계문서 정적 대조: 완료
- caller·callee 추적: 완료
- server build: 기존 작업 결과에서 성공 확인
- `test_writeset` 실행: 미완료. 로컬 TBB archive가 비어 있고 외부 의존성 다운로드가 제한되어 build 단계에서 진행되지 않았다.
- 이번 리뷰에서 코드 수정: 없음

---

## 8. 교차 검증 — Claude (2026-09-30)

이 리뷰의 발견 사항 전건을 커밋 74f9e0a1c 코드에 대해 독립적으로 재검증했다. Claude가 별도로 수행한 4-페르소나 리뷰(`claude-review-integrated.md`)와의 대조도 포함한다. 판정 기준: CONFIRMED(코드로 재확정) / 부분(핵심은 맞고 일부 보정) / 미검증(재검증 생략, 개연성 표기).

### 8.1 판정표

| 항목 | 판정 | 재검증 근거 |
|---|---|---|
| R01 clear가 최신 history를 지우고 낡은 floor만 남김 | **CONFIRMED (Critical 동의)** | `wset_clear_history_with_lock`은 floor를 **클리어 트랜잭션 자신의 commit_lsa**로만 올린다(writeset.cpp:956-960). 삭제되는 map 내용의 최대 LSA(≤ prev_commit)를 반영하지 않으므로, LSA 100 트랜잭션의 지연 clear가 110 게시물을 지우고 floor=100만 남기는 재현 시나리오가 성립한다. 수정 방향도 동의 — advance-before-publish 불변식 덕에 clear 시점의 `prev_commit_lsa`가 삭제되는 모든 슬롯 값의 상한이므로 floor를 `max(자기 commit, prev_commit)`로 올리면 닫힌다 |
| R02 min()이 floor를 낡은 baseline으로 끌어내림 | **CONFIRMED (Critical 동의)** | probe의 WRITE_BOUND 분기는 `wset_parent`의 출처를 구분하지 않고 min을 적용한다(writeset.cpp:891-899). 슬롯(write_seq) 출처 후보는 락 직렬화 논증으로 min이 안전함을 별도 확인했으나(선행의 baseline 전진이 후행의 seq 스냅샷보다 항상 앞), **`history_start`(floor) 출처 후보는 prober와 어떤 락 직렬화도 없어** 낡은 prev_commit 스냅샷이 floor 아래로 결과를 끌어내릴 수 있다. floor는 하한이 아니라 "최소 대기 요구"이므로 min 대상에서 제외해야 한다는 권고에 동의 |
| R03 dependency_is_ref 하나로 세 가지 대기 의미를 표현 불가 | **CONFIRMED (Critical 동의)** | 코드: 최종 후보가 ref_seq일 때만 true(writeset.cpp:763-790, 872-880). 슬레이브 게이트 규칙(설계 불변식: is_ref=false면 completed set 개별 완료로 통과 가능)과 결합하면 — ① overflow 폴백 dep(prev_commit, false)가 개별 완료로 통과되어 **commit-order 폴백 자체가 무력화**되고 ② floor 출처 dep도 동일하며 ③ 혼합 후보(REF 100 < WRITE 110)에서 REF의 frontier 요구가 소실된다. WRITE 슬롯 출처만이 개별 통과가 안전하다(선행 체인 전이 논증). frontier-요구 플래그로의 재정의 권고에 동의 |
| R04 재시작 epoch 장벽 부재 | **CONFIRMED (조건부 High 동의)** | initialize가 map/floor/baseline을 전부 빈 상태로 시작(writeset.cpp:285-302 확인), 복구 seed 없음. 위험 발현은 병렬 슬레이브+재시작 backlog 조합에 종속 — 조건부 심각도 표기가 정확 |
| R05 WRITE 슬롯 비단조 대입 | **CONFIRMED** | writeset_history_map.cpp:60-63 재확인. 같은 결론을 Claude 리뷰 C4에서도 확정. 단 이 문서가 "설계 위반"이 아니라 코드·설계 공통의 구멍으로 다룬 점이 정확 — 01-master §6:414 자체가 대입을 명시한다 |
| R06 복합 키 collation 미정규화 | **부분 (개연성 높음, 바이트 미실증)** | MIDXKEY가 pack_value 경로로 raw 패킹되는 것은 코드로 확인. "B-tree 비교는 collation, 저장 바이트는 원문"이라는 전제는 타당하나 midxkey 내부 문자열의 packed 바이트를 ci collation 값 쌍으로 실증하지는 않았다(이 리뷰도 Claude 리뷰 O3도 동일 한계). 실증 테스트 추가가 선행 조치 |
| R07 sysop fragment 미구현 | **CONFIRMED** | sysop 경로 wset 배선 grep 0건, log_append_sysop_end 무변경 재확인. Claude C3와 일치. "바깥 abort 시 task-writeset 소유 어긋남" 지적은 이 문서가 더 정확히 짚음 |
| R08 2PC + copy_to 누락 | **CONFIRMED** | log_complete_for_2pc(5865~)의 COMMIT 분기(6088-6090)에 probe/publish 없음 재확인(Claude C2와 일치). **신규 부속 확인**: `log_tdes::copy_to`(log_tran_table.c:6511~)에 wset 필드 0건 — loose-end descriptor 이전 시 상태 유실 사실 |
| R09 라벨 실패 무시 | **CONFIRMED** | log_manager.c:4755-4759 `/* FIXME */` 재확인. 4개 페르소나 전원+Claude C1과 일치. "commit append API가 void인 기존 구조까지 고려해 실패 계약부터 확정"이라는 권고가 실무적으로 정확 |
| R10 rectype 53 = develop의 LOG_LARGER_LOGREC_TYPE | **CONFIRMED (핵심 신규 발견)** | base(c63a3b993) log_record.hpp: LOG_SUPPLEMENTAL_INFO=52 다음이 센티널 LOG_LARGER_LOGREC_TYPE(=53). 구버전 log_applier.c:6336 `type >= LOG_LARGER_LOGREC_TYPE` → **구버전 applylogdb는 새 마스터의 첫 WSET_LABEL에서 ER_LOG_PAGE_CORRUPTED로 즉시 종료**. Claude 리뷰 O4(도구 순회 우려)보다 훨씬 구체적이고 심각한 확정 — 마스터 선업그레이드 즉시 복제 중단 |
| R11 capacity 예약 부재 | CONFIRMED | rdlock 하 검사·삽입 재확인(Claude C10과 동일). Medium 유지 동의 |
| R12 dedup·savepoint·same_key | **CONFIRMED (same_key 부분은 신규 확정)** | UNIQUE UPDATE 훅이 same_key 계산 결과와 무관하게 old·new를 **무조건** 수집(locator_sr.c 8740대, `if (!same_key)` 가드 없음) — 설계 §2.2 "값이 바뀌면 new key"와 불일치. savepoint 미되감기는 Claude C6와 일치. filtered index(do_delete_only/do_insert_only 시점) 지적은 미검증(개연성 있음) |
| R13 release 패딩 | CONFIRMED | prior_lsa_gen_record의 memset이 `#if !defined(NDEBUG)` 한정(log_append.cpp:1330-1333) 재확인. 단 기존 레코드(HA_SERVER_STATE 등)와 동일 관행이라는 맥락은 이 문서에 없음 — 신규 회귀가 아니라 기존 관행 승계임을 부기 |
| R14 dump 중단 | CONFIRMED | 더미 그룹 case 누락 + default의 LSA_SET_NULL 재확인(Claude C5와 일치) |
| R15 테스트 전제 불일치 | 미검증 (개연성 있음) | 주석 기본값·태그·preload 검증은 생략. 실행 검증(§7)이 TBB 의존성으로 미완이라는 자기 표기와 정합 |
| R16 테스트 오라클이 결함을 보호 | **CONFIRMED (신규 확정)** | test_writeset.cpp:410 `REQUIRE(!ovf->wset_dependency_is_ref)` — R03의 잘못된 의미를 정답으로 고정. test_writeset_concurrency.cpp:224-233 — 같은 키 무락 동시 publish의 최종 슬롯을 "둘 중 하나면 됨"으로 인정, R05의 max 규칙 도입 시 최댓값 단정으로 강화 필요. 둘 다 원문 확인 |
| R17 통계 hot-path | CONFIRMED | Claude D6와 일치 |
| R18 trace의 실키 값 로깅(민감정보) | **CONFIRMED (신규 관점)** | wset_trace_collected_key가 key 값을 문자열화(value_text[257])해 서버 에러 로그에 기록. UNIQUE 값=이메일·계정키류 가능 — PII 관점은 Claude 리뷰가 놓친 지적 |
| R19 formatting diff 혼입 | CONFIRMED | Claude D14와 일치 |
| R20 문서의 구현/목표 미구분 | CONFIRMED | §6 sysop·오류 전파가 미구현인데 현재형 기술 — 상태 라벨링 권고 동의 |
| R21 or_pack 오류 계약 | **CONFIRMED (Claude C7을 보정)** | or_pack_mem_value는 rc 실패 시에도 non-NULL을 반환하고 *packed_len만 미설정(object_representation.c:5131-5147) — "NULL 검사"만으로는 감지 불가라는 이 문서의 판단이 Claude C7의 권고("NULL 검사")보다 정확. 실용 감지기는 `packed_len == 0`(합법 값은 도메인 캐리어만으로 ≥4바이트) |

### 8.2 종합 의견

- **이 리뷰는 타당하다.** 21건 중 17건 CONFIRMED, 2건 부분, 2건 미검증(개연성 있음), 반박 0건. 특히 R01·R02·R03은 Claude 4-페르소나 라운드(120건)가 잡지 못한 **실질 Critical 프로토콜 결함**이고, R10의 "develop 센티널=53" 확정은 롤링 업그레이드를 즉시 차단하는 수준의 발견이다. 개수 채우기 없이 21건으로 수렴시킨 것, 확정하지 못한 것을 §5·§7에 스스로 표기한 것도 신뢰를 높인다.
- **Claude 리뷰 대비 상호 보완**: 이 리뷰가 새로 잡은 것 = R01, R02(floor 케이스), R03, R10 세부, R12의 same_key, R16 오라클, R18 PII, R08의 copy_to. Claude 리뷰에만 있는 것 = 에러코드 dbi_compat.h 미반영, FK 부모 S_LOCK 단기성(O1, REF 순서의 락 전제 실측 필요 — 이 리뷰의 R03·R05와 별개 경로), publish 경로 bad_alloc(§5에서 의도적 제외 표명됨), release에서 dep≤commit assert 무방비, seq_lock 병목.
- **정정 사항**: Claude 통합 리뷰의 "min() 과소제약 반박(R2)"은 슬롯 출처 후보에만 유효했고 floor 출처를 놓쳤다 — 이 문서 R02가 옳으며 통합 리뷰를 정정한다.
- **권장 수정 순서(§6)에 동의**하되 한 가지 추가: R01·R02·R03 프로토콜 재설계에 **overflow 폴백의 대기 의미(frontier 요구)** 를 명시적으로 포함해야 한다. 현재 구조에서는 폴백이 슬레이브 게이트에서 개별 완료로 통과될 수 있어 "보수적 폴백"이라는 안전망 전체가 성립하지 않는다.
