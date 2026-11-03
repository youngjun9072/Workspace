---
tags: [writeset, applylogdb, sysop_end, serial, idea]
date: 2026-10-02
status: 발굴 초안 / 미검증
code-base:
  branch: feature/CBRD-27508-parallel-applylogdb-writeset
  head: 441aafed9306856adc64d39fbd1b1e86b99bd83c
  develop-base: c63a3b993
scope: 기존 3안(안1 직렬 폴백 / 안2 누적+단조 / 안3 조각 probe-publish)과 겹치지 않는 새 접근
---

# sysop 처리 새 아이디어 모음 (ideas-A)

## 이 문서의 위치

[10-sysop-end-investigation.md](../10-sysop-end-investigation.md) §13에 정리된 세 안과 본질적으로 다른 처리 구조를 찾는 것이 목적입니다. 세 안은 모두 마스터 쪽에 일을 추가합니다. 안 1은 마스터에서 `wset_overflow` 플래그를 세우고, 안 2는 마스터에서 serial 키를 수집해 라벨로 내보내며, 안 3은 마스터에서 sysop 경계마다 probe/publish를 한 번 더 수행합니다. 아래 다섯 아이디어는 책임 분배를 바꿉니다. 네 개는 serial 정합성의 무게중심을 마스터에서 슬레이브 또는 승격 시점으로 옮기고, 하나는 coordinator 전담을 유지하되 전체 drain 대신 스칼라 베리어 하나로 failover 창만 닫습니다.

## 먼저 확인한 코드 사실

마스터에서 serial 발급은 `serial_update_serial_object()`가 수행합니다(`src/query/serial.c:1148-1236`). 이 함수는 독립 sysop을 열고(`log_sysop_start`, `:1173`), `repl_start_flush_mark()`(`:1178`)로 플러시 마크를 연 뒤 `db_serial` 행 UPDATE를 `repl_log_insert(..., RVREPL_DATA_UPDATE, ...)`(`:1210`)로 복제 레코드에 싣고, `log_sysop_commit()`(`:1222`)으로 독립 sysop을 닫습니다. 바깥 트랜잭션이 롤백해도 이 독립 sysop은 되돌지 않으므로 발급 번호가 재사용되지 않습니다. 다만 이미 X_LOCK을 쥔 경우(같은 미커밋 트랜잭션이 serial 객체를 생성·변경한 경우)에는 topop과 플러시 마크를 쓰지 않습니다(`:1171`, `:1176`). 이 X_LOCK 분기는 독립 sysop이 아니라 바깥 트랜잭션에 묶이는 경로이므로 아래 논의에서 구분이 필요합니다.

슬레이브는 `db_serial` 행 변경을 특별 취급하는 자리를 이미 두 곳 가지고 있습니다. `la_is_mvcc_class()`가 `oid_is_serial()`로 serial 클래스를 MVCC 비대상으로 분기하고(`src/transaction/log_applier.c:5499`), 복제 필터는 `CT_SERIAL_NAME`을 항상 통과시킵니다(`:8602`). 그러나 실제 적용은 일반 UPDATE와 같은 경로입니다. `la_apply_update_log()`(`:5384`)가 대상 행 이미지를 읽어 `la_repl_add_object()`(`:5465`)로 bulk 목록에 넣고, 최종적으로 서버 측 치환 UPDATE로 `db_serial` 행 전체를 덮어씁니다. 즉 현재 슬레이브는 `db_serial.current_val`을 들어온 값으로 **무조건 대입**하며, 적용 순서가 뒤집히면 과거 값이 최신 값을 덮을 수 있습니다. 이 대입을 조건부 단조(max)로 바꾸는 훅 자리가 `oid_is_serial()` 분기 근처에 이미 있다는 점이 아래 아이디어들의 전제입니다.

RBR 전제는 다음과 같습니다. 사용자 테이블에 AUTO_INCREMENT로 들어가는 실제 값은 마스터에서 계산되어 행 이미지에 담겨 복제됩니다. 슬레이브는 그 행을 리터럴로 INSERT할 뿐 `NEXTVAL`을 호출하지 않습니다. 따라서 슬레이브의 `db_serial` 카탈로그는 복제 적용 자체에는 쓰이지 않고, 오직 승격 뒤 이 노드가 새 발급을 시작할 때만 필요합니다. 이 전제는 코드 흐름상 타당하지만 모든 serial 사용 패턴에서 확정 검증하지는 않았으므로 아래에서 이 전제에 기대는 부분은 추정으로 표기합니다.

벤더 참고로, MariaDB의 `SETVAL()`은 복제 안전으로 설계되어 있고 "현재 값보다 작은 값으로는 내리지 않으며, 복제본이 SETVAL을 순서 뒤바뀐 채 받아도 가장 큰 값만 효과를 낸다"고 문서화되어 있습니다[1]. 이는 serial 동기화를 순서 무관 단조 병합으로 다루는 아래 접근을 뒷받침합니다. PostgreSQL은 시퀀스를 트랜잭션 비대상으로 보고 논리 복제 대상에서 제외하며(계획상 v19에서 도입 예정), 물리 복제에서는 시퀀스 WAL을 LSN 순서로 재생합니다[2]. 또한 커밋 LSN은 순서가 있지만 트랜잭션 내부 LSN 구간은 서로 겹칠 수 있다는 점[2]은 "serial 정합성을 커밋 경계가 아니라 다른 좌표로 다룬다"는 발상의 근거가 됩니다.

---

## 아이디어 A — 슬레이브 단조 적용 + serial을 데이터 행과 같은 worker 트랜잭션에 동봉 (마스터 무변경 지향)

### 한 줄 요약

마스터는 전혀 바꾸지 않고, serial 복제 item을 그 트랜잭션의 최종 COMMIT task에 그대로 태워 데이터 행과 한 worker DB 트랜잭션에서 원자적으로 커밋하며, 슬레이브가 `db_serial` 적용만 단조(max)로 특수화해 트랜잭션 간 순서를 무의미하게 만듭니다.

### 처리 방식

마스터는 지금 코드 그대로 둡니다. serial item은 발급을 일으킨 바로 그 사용자 트랜잭션의 복제 레코드 안에 남아 있고, 그 트랜잭션의 `LA_APPLY` 슬롯에 함께 쌓입니다. 슬레이브 reader는 `LOG_SYSOP_END`에서 item을 조기 소비하지 않고 보관했다가(안 2의 누적 동작과 같은 reader 정책) 최종 `LOG_COMMIT`에서 그 `trid`의 전체 item을 하나의 COMMIT task로 묶어 한 worker에 보냅니다. serial 발급은 그 값을 쓰는 INSERT와 같은 사용자 트랜잭션에서 일어나므로, serial `db_serial` UPDATE와 그 값을 담은 데이터 행 INSERT가 같은 worker의 같은 DB 트랜잭션에서 함께 커밋됩니다.

슬레이브 worker는 `db_serial` 클래스 item을 만나면 일반 치환 UPDATE 대신 현재 `db_serial.current_val`을 읽어 들어온 값이 더 클 때만 반영하는 읽기-비교-쓰기로 적용합니다. 적용 훅은 `oid_is_serial()` 분기(`log_applier.c:5499` 인근)에 둡니다. 이 때문에 serial item은 bulk 경로(`la_repl_add_object`)를 타지 못하고 개별 적용이 되지만, serial 발생 빈도가 낮다는 정적 조사(§12)를 전제하면 부담이 작습니다.

바깥 트랜잭션 ABORT 처리에서는 보관 item을 전부 폐기하지 않고, serial 클래스 item만 골라 단조로 적용한 뒤 나머지를 버립니다. 이것이 마스터의 독립 sysop이 바깥 롤백에도 살아남는 성질을 슬레이브에서 재현하는 유일한 추가 규칙입니다. 식별은 `oid_is_serial()` 하나로 끝납니다.

serial 외의 `NEED_FLUSH` 생산자(INCR/DECR, checksumdb)는 이 아이디어의 단조 전제가 성립하지 않습니다. 다만 INCR/DECR이 바꾸는 사용자 행의 PK·UNIQUE 키가 이미 locator 수집 경로를 통해 writeset에 들어간다면 dependency 라벨로 순서가 잡히므로 동봉만으로 정합성이 유지됩니다(추정, `query_executor.c`의 increment 경로가 `locator_update_index`를 거치는지 확인 필요). 거치지 않는다면 그 트랜잭션은 안 1의 `wset_overflow` 폴백으로 보냅니다. checksumdb는 statement 성격이라 기존 statement 폴백을 그대로 씁니다.

### 정합성 분석

정상 커밋에서는 serial과 데이터 행이 한 DB 트랜잭션에서 원자적으로 반영되므로 어긋나지 않습니다. abort 생존은 추가한 ABORT 시 serial 선별 단조 적용으로 지켜집니다. 동시 serial 순서는 두 트랜잭션이 서로 다른 worker에서 임의 순서로 커밋돼도 단조 병합이 최종값을 수렴시키므로 지켜집니다. 재시작은 serial이 데이터 행과 같은 COMMIT task에 묶여 완료 표식을 공유하므로, 표식이 있으면 전체 skip, 없으면 전체 재적용으로 트랜잭션 단위 멱등이 그대로 성립합니다. 재적용 시 serial 단조 적용은 같은 값이 다시 와도 max라 변화가 없어 중복 적용이 무해합니다. failover 번호 재사용은 serial 발급과 그 값을 쓴 행이 같은 DB 트랜잭션에서 커밋되므로, 행이 커밋됐는데 serial은 아직 미커밋인 창이 존재하지 않아 막힙니다.

깨지는 경우는 CYCLE serial입니다. CYCLE은 값이 되돌아가므로 단조가 성립하지 않습니다. CYCLE serial을 쓰는 트랜잭션은 안 1 폴백으로 보내야 합니다. 또 하나는 X_LOCK 경로(`serial.c:1171`)로, 이때 serial 변경이 독립 sysop이 아니라 바깥 트랜잭션에 묶이는데, 이 경우는 오히려 동봉 모델과 자연스럽게 맞아 별도 처리가 필요 없을 가능성이 높습니다(추정, 해당 경로의 복제 레코드 생성 여부 확인 필요).

### 비용과 구현 복잡도

건드리는 파일은 슬레이브 `log_applier.c` 한 곳이 주이고 마스터는 손대지 않습니다. 변경 지점은 세 곳입니다. 하나는 `la_apply_update_log()` 계열에서 `db_serial` 단조 적용 분기, 둘은 ABORT 처리에서 serial 선별 적용, 셋은 reader의 `LOG_SYSOP_END` 비소비 누적 정책입니다. 새 개념은 "슬레이브 단조 적용" 하나뿐이고 라벨·history·조각 같은 새 상태가 없습니다. 유지보수 난이도는 세 안 중 가장 낮은 편입니다. 다만 INCR/DECR의 writeset 포획 여부라는 미확인 전제에 기대므로 그 확인이 선행돼야 합니다.

### 3안 대비 장단점

장점은 마스터 무변경이라 마스터 리스크와 검증 면적이 없다는 점, serial이 데이터 행과 원자 커밋되어 안 2가 단조로 덮던 probe-publish 시점 간극 문제 자체가 발생하지 않는다는 점입니다. 안 2는 serial 키 수집·라벨·생존 플래그·단조를 모두 요구하지만, 아이디어 A는 수집과 라벨을 제거하고 단조와 선별-abort만 남깁니다. 단점은 serial이 bulk 적용을 못 한다는 점과 INCR/checksumdb를 여전히 폴백으로 보낸다는 점으로, 이는 안 2와 같은 제약입니다. 안 3 대비로는 조각·중첩 sysop·조각 단위 재시작 검증을 전부 피합니다.

### 판정

채택 후보입니다. 치명적 결함은 없고, INCR/DECR의 writeset 포획 여부와 RBR 전제만 확인하면 됩니다.

---

## 아이디어 B — serial 정합성을 승격 시점 재조정으로 미룸 (out-of-band)

### 한 줄 요약

정상 병렬 적용 경로에서는 `db_serial`의 정확성을 보장하지 않고 best-effort로만 흘리며, 이 노드가 쓰기를 받기 직전인 승격 순간에만 로그를 재조정해 모든 serial 값을 올바른 상한으로 끌어올립니다.

### 처리 방식

마스터는 바꾸지 않습니다. 슬레이브 reader는 로그를 지나가며 serial 이름별 최대 발급값을 메모리 맵에 단조로 기록합니다. 이 기록은 DB 쓰기가 아니라 순수 메모리 갱신이라 hot path 비용이 거의 없습니다. 정상 운영 중 `db_serial` 행 적용은 하지 않거나(또는 지금처럼 치환해도 무방하며, 어차피 승격 때 재조정됨) 느슨하게 둡니다. 슬레이브는 승격 전까지 읽기 전용이고 새 발급을 하지 않으므로 `db_serial`이 뒤처져도 복제 적용에는 영향이 없습니다(RBR 전제, 추정).

승격이 결정되면 쓰기를 받기 전에 재조정 패스를 한 번 실행합니다. `committed_lsa`까지의 로그 구간에서 serial 이름별 최대값을 확정하고, 각 `db_serial.current_val`을 그 최대값과의 max로 올립니다. serial 값이 로그 안에서 단조 증가하므로 이 재조정은 순서와 무관하게 정확합니다. 재조정은 단일 스레드 한 번의 패스이므로 병렬 경로의 어떤 순서 보장도 요구하지 않습니다.

### 정합성 분석

정상 커밋 구간에서는 serial 정확성을 의도적으로 보장하지 않으므로, 슬레이브가 조회를 서빙하지 않는다는 전제가 반드시 성립해야 합니다. 이것이 이 아이디어의 핵심 제약입니다. abort 생존은 자연스럽게 해결됩니다. 재조정은 로그에 실제로 기록된 serial 발급을 기준으로 하고 그 발급은 바깥 롤백과 무관하게 로그에 남으므로, 승격 재조정이 롤백된 트랜잭션의 serial까지 포함합니다. 동시 serial 순서는 재조정이 max로 흡수하므로 무의미합니다. 재시작은 메모리 맵을 잃어도 `committed_lsa`부터 재독하며 다시 쌓으므로 안전합니다. failover 번호 재사용은 재조정이 승격 직전에 상한을 보장하므로 원천 차단됩니다.

깨질 수 있는 지점은 승격이 비정상적으로 급박해 재조정 패스를 완주하지 못하는 경우입니다. 이때 serial이 상한 미만인 채 쓰기를 받으면 번호가 재사용됩니다. 따라서 재조정 완료를 승격 완료의 선행 조건으로 묶어야 하며, 이 순서가 깨지면 치명적입니다.

### 비용과 구현 복잡도

hot path 비용이 가장 작습니다. serial DB 적용을 아예 생략할 수 있어 읽기-비교-쓰기 부담도 없습니다. 건드리는 곳은 reader의 메모리 맵 갱신 한 곳과 승격 경로(`la_change_state()` 계열)의 재조정 패스 한 곳입니다. 새 개념은 "승격 시점 재조정"과 "serial 메모리 상한 맵" 둘입니다. 난이도의 핵심은 승격 경로에 재조정을 끼워 넣고 그 완료를 승격 게이트로 만드는 부분이며, 이 경로는 PoC가 검증하지 않은 구간이라 별도 검증이 필요합니다.

### 3안 대비 장단점

장점은 병렬 경로에서 serial 관련 순서·라벨·베리어가 전부 사라져 병렬성이 안 3만큼 높으면서 구현은 훨씬 가볍다는 점입니다. 단점은 "슬레이브는 serial을 서빙하지 않는다"는 전제가 반드시 참이어야 하고, 승격 경로에 정합성 책임이 집중되어 승격 테스트가 중요해진다는 점입니다. 세 안은 모두 정상 경로에서 정합성을 닫는데, 아이디어 B는 정합성 시점 자체를 승격으로 미루는 발상의 전환입니다.

### 판정

채택 후보이나 전제 의존이 큽니다. "슬레이브가 승격 전까지 serial을 서빙하지 않는다"가 코드·운영상 참인지 확정이 필요하고, 승격 급박 시 재조정 누락이 치명적이므로 승격 게이트 설계가 관건입니다.

---

## 아이디어 C — coordinator serial 전담 + 스칼라 serial-commit watermark 베리어

### 한 줄 요약

serial은 coordinator가 자기 세션에서 로그 순서대로 전담 적용하되(순서·abort 생존 자동), worker가 자기 트랜잭션을 커밋하기 전에 "coordinator가 serial을 이 커밋 LSA 이하까지 영속했는가"라는 스칼라 비교 하나만 통과하게 해 failover 창을 닫습니다. 전체 worker drain은 쓰지 않습니다.

### 처리 방식

마스터는 바꾸지 않습니다. 슬레이브 coordinator는 `LOG_SYSOP_END` 경계에서 serial item을 자기 세션에 로그 순서대로 적용하고 주기적으로 커밋합니다. coordinator가 단일 순차 주체이므로 serial 대 serial 순서는 자동 보장되고, 바깥 ABORT 전에 이미 적용되므로 abort 생존도 자동입니다. 여기까지는 현재 실험 기준(§0)과 같습니다.

추가하는 것은 스칼라 watermark 하나입니다. coordinator는 자기 serial 세션을 커밋할 때마다 "serial을 LSA X 이하까지 영속 완료"라는 `coordinator_serial_committed_lsa`를 단조로 전진시킵니다. worker가 어떤 트랜잭션(커밋 LSA C)을 DB COMMIT하려 할 때, 그 트랜잭션이 발급한 serial은 로그상 바깥 COMMIT보다 앞이므로 모두 LSA < C입니다. 따라서 worker gate에 "`coordinator_serial_committed_lsa >= C`일 때만 커밋 허용"이라는 조건을 하나 더 겁니다. 이 조건이 막히면 coordinator에게 serial 세션을 지금 커밋하라고 깨워 watermark를 전진시킵니다. serial 발생이 드물면 대부분의 worker는 이 비교를 그냥 통과합니다.

### 정합성 분석

정상 커밋은 coordinator가 순서대로 적용하므로 유지됩니다. abort 생존은 coordinator가 바깥 abort 전에 적용하므로 유지됩니다. 동시 serial 순서는 coordinator 단일 순차성으로 유지됩니다. 재시작은 coordinator serial 세션과 worker 세션이 별도 커밋이므로, serial 세션의 완료 경계와 worker 완료 표식을 각각 영속하고 재시작 시 둘을 함께 복원해야 합니다. 이 이원 경계 관리가 이 아이디어의 복잡도입니다. failover 번호 재사용은 watermark 조건이 "serial이 먼저 영속된 뒤에만 의존 행이 커밋"을 보장하므로 막힙니다.

깨질 수 있는 지점은 watermark의 세밀도입니다. watermark를 전역 스칼라 하나로 두면, serial을 전혀 안 쓴 worker도 serial을 쓴 다른 트랜잭션의 coordinator 커밋을 기다릴 수 있어 과직렬화가 생깁니다. serial이 드물면 영향이 작지만, 빈번하면 병렬성이 깎입니다. serial 이름별 watermark로 세분하려면 worker가 자기 트랜잭션이 어떤 serial을 썼는지 알아야 하는데, 이는 마스터 태깅을 요구해 안 2에 가까워집니다.

### 비용과 구현 복잡도

건드리는 곳은 슬레이브 coordinator의 watermark 전진과 worker gate의 조건 한 줄, 그리고 coordinator 깨우기입니다. 새 개념은 "serial-commit watermark" 하나입니다. full drain을 피하므로 역할 전환 drain 같은 무거운 동기화가 없습니다. 난이도의 핵심은 coordinator serial 세션과 worker 세션의 이원 완료 경계를 재시작까지 일관되게 유지하는 부분입니다.

### 3안 대비 장단점

장점은 마스터 무변경이고 serial 적용 자체는 현재 실험 코드를 거의 그대로 쓰며, 순서·abort 생존이 coordinator 순차성으로 공짜라는 점입니다. 안 2의 단조·수집·라벨·생존 플래그를 전부 쓰지 않습니다. 단점은 전역 watermark의 과직렬화 가능성과 이원 완료 경계의 재시작 복잡도입니다. 세 안 대비 특징은 full drain과 세밀 단조 사이의 중간으로, 스칼라 베리어 하나로 failover 창만 좁게 닫는다는 점입니다.

### 판정

채택 후보입니다. serial 빈도가 낮다는 §12 정적 조사가 실측으로 확인되면 전역 watermark의 과직렬화가 무시할 수준이 되어 매력적입니다. 이원 완료 경계의 재시작 처리가 설계의 관건입니다.

---

## 아이디어 D — sysop을 키 의존으로만 다루는 serial 독립 never-abort mini-tx (한계 포함)

### 한 줄 요약

serial sysop을 바깥 트랜잭션의 조각이 아니라 완전히 독립한 never-abort mini-transaction으로 승격시키고, 충돌은 serial 이름 키의 단조 병합으로만 해소해 어떤 순서 의존도 두지 않는 가장 단순한 모델입니다. 다만 아래 분석대로 failover 창을 단독으로는 닫지 못합니다.

### 처리 방식

serial sysop을 `SYSOP_END` LSA를 커밋 좌표로 갖는 독립 task로 만들고, 바깥 트랜잭션의 item 목록에서 serial item을 아예 떼어냅니다. 이 mini-tx는 바깥이 ABORT돼도 폐기하지 않습니다. 바깥 트랜잭션이 그 serial 값을 "참조"하는 것은 이미 행 이미지에 값이 박혀 있어 `db_serial` 행 내용에 대한 데이터 의존이 아니므로, mini-tx와 바깥 사이에 순서 게이트를 두지 않습니다. serial 대 serial 충돌은 슬레이브 단조 적용(아이디어 A의 훅)으로만 흡수합니다. 이것이 안 3과 다른 점으로, 안 3은 조각에 probe/publish와 dependency 게이트를 부여하지만 아이디어 D는 그 게이트를 전부 제거하고 단조에만 기댑니다.

### 정합성 분석

정상 커밋과 동시 serial 순서는 단조 병합으로 지켜집니다. abort 생존은 mini-tx를 폐기하지 않으므로 지켜집니다. 재시작은 mini-tx가 독립 완료 표식을 가지면 멱등합니다. 문제는 failover 번호 재사용입니다. serial mini-tx와 그 값을 쓴 데이터 행이 서로 다른 DB 트랜잭션에서 커밋되므로, 데이터 행은 커밋됐는데 serial mini-tx는 아직 커밋 안 된 창이 생깁니다. 이 창에서 failover가 나면 `db_serial`이 이미 발급된 값보다 작아 번호가 재사용됩니다. 단조 적용만으로는 이 창을 닫지 못합니다.

따라서 아이디어 D는 단독으로는 failover에서 깨집니다. 창을 닫으려면 아이디어 C의 watermark 베리어를 얹거나, 아이디어 A처럼 serial을 데이터 행과 동봉해야 합니다. 그런데 동봉하면 더 이상 독립 mini-tx가 아니므로 아이디어 D의 전제가 무너지고 아이디어 A가 됩니다.

### 비용과 구현 복잡도

mini-tx 분리, 독립 완료 표식, 바깥과의 소유권 분리가 필요해 안 3과 비슷한 상태 관리가 생깁니다. 반면 probe/publish와 dependency 라벨은 없앱니다.

### 3안 대비 장단점

장점은 안 3의 조각 모델에서 가장 무거운 부분인 probe/publish와 게이트를 제거해 "키 의존 = 단조"라는 가장 단순한 의미로 환원한다는 점입니다. 단점은 그 단순화가 바로 failover 창을 여는 원인이 된다는 점입니다. 독립 mini-tx로 쪼개는 순간 serial과 데이터 행의 원자성이 깨지기 때문입니다.

### 판정

단독 기각입니다. 치명적 결함은 serial mini-tx와 데이터 행이 분리 커밋되어 failover 번호 재사용 창이 열리는 것이며, 이를 닫으려면 아이디어 C나 A를 다시 끌어와야 해 독립 아이디어로서의 이점이 사라집니다. 다만 "serial 충돌은 순서가 아니라 키 단위 단조 병합으로 해소한다"는 핵심 통찰은 아이디어 A·B·C 모두가 공유하는 공통 기반이므로, 이 통찰 자체를 명시적으로 남기는 가치는 있습니다.

---

## 아이디어 E — 정상 경로에서 db_serial 적용을 완전히 제거하고 reader 메모리 단조 max만 유지 (PostgreSQL ceiling 차용)

### 한 줄 요약

PostgreSQL이 시퀀스를 트랜잭션 비대상으로 보고 복제 대상에서 빼며 주기적 상한만 기록하는 방식을 차용해, 슬레이브는 정상 운영 중 `db_serial`에 아무 DB 쓰기도 하지 않고 reader가 메모리에 serial 이름별 상한만 유지하다가 승격 시 한 번에 반영합니다.

### 처리 방식

아이디어 B가 "느슨하게 흘리고 승격에 재조정"이라면, 아이디어 E는 정상 경로에서 `db_serial` 적용을 아예 끊습니다. 슬레이브 복제 필터는 이미 `CT_SERIAL_NAME`을 특별 취급하므로(`log_applier.c:8602`), 그 자리에서 serial item을 DB 적용 대상에서 제외하고 reader의 serial 이름별 메모리 상한 맵만 단조로 갱신합니다. 데이터 행 INSERT는 serial 값을 리터럴로 이미 담고 있어(RBR 전제, 추정) `db_serial` 카탈로그가 뒤처져도 복제가 정확합니다. 승격 시 메모리 상한 맵을 `db_serial`에 단조로 flush하는 단일 쓰기 패스를 수행합니다.

### 정합성 분석

정상 커밋에서 데이터 행은 정확히 반영되고 `db_serial`만 뒤처집니다. 슬레이브가 승격 전까지 serial을 서빙하지 않는다는 전제 위에서 문제없습니다. abort 생존은 상한 맵이 로그의 발급 기록을 기준으로 하므로 지켜집니다. 동시 serial 순서는 상한 맵 단조로 무의미합니다. 재시작은 메모리 맵을 잃어도 `committed_lsa`부터 재독해 다시 쌓으므로 안전하지만, `db_serial` DB 쓰기를 승격까지 미루므로 재시작 후에도 반드시 로그에서 상한을 재구성할 수 있어야 합니다. failover 번호 재사용은 승격 flush가 상한을 보장하므로 막힙니다. 단, 아이디어 B와 마찬가지로 승격 flush를 승격 완료의 선행 조건으로 묶지 않으면 치명적입니다.

### 비용과 구현 복잡도

hot path에서 serial DB 쓰기가 완전히 사라져 비용이 가장 작습니다. 건드리는 곳은 필터 지점의 serial 제외 + 메모리 상한 갱신, 승격 경로의 flush 패스입니다. 새 개념은 "serial 메모리 상한 맵"과 "승격 flush"입니다.

### 3안 대비 장단점

장점은 serial을 복제 적용 트래픽에서 제거해 병렬 경로가 serial을 전혀 신경 쓰지 않아도 된다는 점으로, 병렬성 손실이 없습니다. 벤더 정합성도 분명합니다(PostgreSQL이 시퀀스를 복제 대상에서 빼는 것과 같은 선택). 단점은 아이디어 B와 공유하는 두 전제로, 슬레이브가 승격 전 serial을 서빙하지 않아야 하고 승격 flush가 반드시 승격 전에 완주해야 합니다. 세 안 대비 특징은 serial을 "복제 item으로 적용"하는 것 자체를 포기한다는 점으로, 과제 지시의 "다른 경로로 동기화" 방향에 가장 충실합니다.

### 판정

채택 후보입니다. 아이디어 B의 더 급진적 형태로, B가 정상 경로에서 serial을 느슨히 적용하는 반면 E는 적용을 끊어 hot path를 완전히 비웁니다. B와 E는 같은 두 전제(승격 전 미서빙, 승격 flush 선행)를 공유하므로, 둘 중 하나만 채택하면 됩니다. E가 더 단순하고 비용이 낮습니다.

---

## 요약 비교

| 구분 | A 동봉+단조 | B 승격 재조정 | C watermark 베리어 | D 독립 mini-tx | E db_serial 적용 제거 |
|---|---|---|---|---|---|
| 정합성 책임 위치 | 슬레이브 | 승격 시점 | 슬레이브 coordinator | 슬레이브(불완전) | 승격 시점 |
| 마스터 변경 | 없음 | 없음 | 없음 | 조각 분리 필요 | 없음 |
| failover 창 | 동봉 원자성으로 닫음 | 승격 재조정으로 닫음 | watermark로 닫음 | 단독으로 못 닫음 | 승격 flush로 닫음 |
| 핵심 전제 | INCR writeset 포획, RBR | 승격 전 미서빙, RBR | serial 저빈도 | (결함) | 승격 전 미서빙, RBR |
| hot path 비용 | 낮음(serial 개별 적용) | 매우 낮음 | 낮음 | 중 | 가장 낮음 |
| 병렬성 | serial 병렬 | 최대 | serial 저빈도면 높음 | 최대 | 최대 |
| 판정 | 채택 후보 | 채택 후보(전제 의존) | 채택 후보 | 단독 기각 | 채택 후보 |

세 안과의 관계는 다음과 같습니다. 기존 세 안은 정합성 무게중심을 마스터에 둡니다. 아이디어 A·C는 그 무게를 슬레이브로 옮기고, B·E는 승격 시점으로 옮깁니다. D는 안 3의 조각 모델을 극단적으로 단순화하려다 failover 창을 여는 반례로, "serial 충돌은 순서가 아니라 키 단위 단조 병합"이라는 공통 통찰만 남깁니다. 다섯 아이디어를 관통하는 공통 기반은 두 가지입니다. 하나는 슬레이브가 `db_serial`을 단조로 다룬다는 것(MariaDB SETVAL과 같은 선택[1])이고, 다른 하나는 serial 값이 실제로는 행 이미지에 박혀 복제되므로 `db_serial` 카탈로그의 정확성이 복제 적용이 아니라 오직 승격 후 발급에만 필요하다는 RBR 전제(추정, 확정 검증 필요)입니다. 이 두 전제가 확정되면 A, B, C, E 중 비용·전제 수용도에 따라 고르는 선택 문제가 됩니다.

## 선행 확인 과제

- INCR/DECR이 바꾸는 사용자 행이 locator 키 수집 경로(`locator_update_index`)를 거쳐 writeset에 포획되는지 (아이디어 A의 INCR 처리 전제).
- RBR 전제 확정: 슬레이브가 데이터 행을 적용할 때 serial 파생 컬럼 값을 `db_serial` 조회 없이 행 이미지 리터럴로 넣는지 (아이디어 A·B·E 공통 전제).
- 슬레이브가 승격 전까지 serial 발급(조회 포함)을 서빙하지 않는지 (아이디어 B·E 전제).
- `serial.c:1171`의 X_LOCK 경로가 복제 레코드를 어떻게 다루는지 (동봉 모델의 예외 여부).
- serial 포함 트랜잭션의 실제 빈도 (아이디어 C 전역 watermark 과직렬화 영향).

## 참고 자료

[1] MariaDB SETVAL 문서. SETVAL은 복제 안전이며 현재 값보다 작게 내리지 않고, 복제본이 순서 뒤바뀐 SETVAL을 받아도 가장 큰 값만 효과를 낸다. https://mariadb.com/docs/server/reference/sql-structure/sequences/sequence-functions/setval

[2] PostgreSQL 논리 복제와 시퀀스. 시퀀스는 트랜잭션 비대상으로 현재 논리 복제 대상에서 제외(계획상 v19 도입), 커밋 LSN은 순서가 있으나 트랜잭션 내부 LSN 구간은 겹칠 수 있음. https://www.postgresql.org/docs/current/logical-replication-config.html , https://powersync.com/blog/postgres-logical-replication-challenges-solutions
