# 시나리오 리뷰 (🟣 5년차 DB 엔지니어)

> 대상: `parallel_applylogdb_coordinator_design.md` 재구성된 Act D.1~D.5 (마스터-사이드 단일안, 옵션 a). 페르소나 정의 → `review_personas.md`.
> **판정 메타 원리**: 슬레이브 서버가 강제하는 cross-row 제약 = {PK 유일성, 각 보조 unique, FK 부모, 상속 공유 unique(+ CUBRID OID/SET 참조 — 2차 발견)}. writeset이 이 제약 변(邊)마다 conflict key를 담아야 정확. 누락 변은 out-of-order 적용 시 서버 검사 위반.
> 판정: ✅통과 / ⚠️위험(성능·운영) / ❌갭(correctness) / 🔎확인필요.

---

## 1차 배치 (S1~S32) — 본 검토

| # | 카테고리 | 시나리오 | 판정 | 근거 |
|---|---|---|---|---|
| S1 | 보조 unique | PK 다른데 unique 같음(INSERT/교차 UPDATE) | ❌갭 | writeset=(class,PK)∪FK부모라 unique 누락 → 역순 적용 시 unique 위반 |
| S2 | unique swap | 두 행 unique 값 교환(2 tx) | ❌갭 | S1과 동근원, PK 기준이라 독립 오판 |
| S3 | PK 이동 | `UPDATE SET id=5 WHERE id=3` 후 옛 PK 재사용 | 🔎 | 변경 전·후 키 모두 writeset에 들어가는지 확인 |
| S4 | 자기참조 FK | 트리 INSERT 체인 | ✅ | 자식 writeset에 부모 키 주입 → 체인 직렬 |
| S5 | 다중테이블 tx | orders+items+inventory 한 tx | ⚠️ | fan-out↑ → 병렬도 급락(정확성 OK) |
| S6 | cascade | ON DELETE CASCADE | 🔎 | cascade 영향 행이 repl_records에 남는지 |
| S7 | 배치 UPDATE | 단일 tx 10만 행 | ⚠️ | history 메모리·비교 비용 + 롱tx 대기 |
| S8 | SBR | 비결정/다중class 문장 | ❌갭 | 마스터가 writeset 계산 불가 → 마스터 barrier 발행 규칙 부재 |
| S9 | DDL | ALTER ADD FK | ✅ | barrier(비용 주의) |
| S10 | 트리거 | 마스터 트리거 2차 변경 | ✅ | 슬레이브 트리거 off + 결과 행 복제 |
| S11 | 재시도×게이트 | 워커 재시도 중 commit 게이트 정체 | ⚠️ | head-of-line 증폭 |
| S12 | insert-delete | 같은 PK 2 tx | ✅ | writeset 겹침 → 직렬 |
| S13 | 파티션 이동 | cross-partition UPDATE | ✅ | 파티션키∈모든 인덱스키 → 안전 |
| S14 | 상속 공유 unique | subA(u=5)/subB(u=5) | ❌갭 | cross-class 공유 BTID 위반 미포착 |
| S15 | serial | NEXTVAL 카탈로그 갱신 | 🔎 | db_serial 갱신의 복제·순서 |
| S16 | 복합 PK | 복합키 충돌키 | ✅ | (class, 복합키 전체)면 정확 |
| S17 | 무PK | 복제 대상 PK 필수 | ✅전제 | 무PK는 애초 복제 안 됨 |
| S18 | savepoint | 부분 롤백 | 🔎 | 롤백분이 repl_records에서 제거되는지 |
| S19 | intra-tx 반복 | 같은 행 N회 UPDATE | ✅ | 최종 after-image(멱등) |
| S20 | upsert | INSERT…ON DUP/REPLACE | ✅ | 행 수준 insert/update로 풀림 |
| S21 | TRUNCATE | 전체 삭제 | ⚠️ | barrier 전면 직렬(비용) |
| S22 | XA/2PC | prepare-commit 분리 | 🔎 | commit_lsa 단조성 영향 |
| S23 | 롤링 스키마 | master/slave 일시 불일치 | ✅긍정 | **옵션 a(마스터 계산)가 Q21 위험 해소** |
| S24 | 온라인 인덱스 | ADD INDEX | ✅ | DDL barrier, 행데이터 불변 |
| S25 | 생성/가상 컬럼 | virtual+비결정 | 🔎 | 비저장 비결정 시 발산 위험 |
| S26 | 복합 FK | 다중컬럼 FK | ✅ | part2가 부모 복합키 전체 담으면 OK |
| S27 | 순환 FK | A→B,B→A deferred | ⚠️🔎 | 양방향 부모키 → 과직렬/순환 의존 |
| S28 | failover | 승격 시 미적용 tail | ✅ | D.3 gap-free committed_lsa |
| S29 | LOB | 행+LOB | 🔎범위 | LOB 내용 비복제(범위 밖) |
| S30 | 멀티소스 | 여러 마스터→1 슬레이브 | 🔎범위 | commit_lsa 소스별 단조성 붕괴 |
| S31 | fan-in 과직렬 | hot 부모 1개 자식 1000 tx | ⚠️ | 자식끼리 부모키 공유 과직렬(Bug#111146) |
| S32 | 빈 tx | 변경 없음 | ✅ | baseline, 무시 |

**1차 핵심 갭**: ① 보조 unique 누락(S1·S2), ② 상속 공유 unique(S14), ③ SBR barrier 주체가 마스터로 이동(S8), ④ PK/unique 이동 전·후 키(S3).
**1차 메타 발견**: writeset 커버리지 = 서버가 검사하는 제약 집합. 현재 `(class,PK)∪FK부모`는 보조 unique·상속 공유 unique를 빠뜨림 → 일반화 규칙 `writeset = (class,PK) ∪ (class,각 unique 키) ∪ (FK 부모) ∪ (상속 공유 unique)` 권장.

---

## 2차 배치 (S33~S85) — 🟣 엔지니어 에이전트 (opus)

> 부수적으로 "commit 순서 보존(D.3)"이 잡는 것과 "writeset 의존(D.4)"이 잡는 것을 구분해 판정.

### Round 6 — 다중컬럼/부분/NULL unique 처리
**S33. 다중컬럼 보조 unique `(a,b)` 충돌** ⚠️위험 — D.4의 "unique 키 포함"이 **복합 unique 직렬화 규약(컬럼 순서·타입·길이) 미정**. same-class 백스톱으로 correctness는 살지만 cross-class(상속)에선 위험.
**S34. 부분/NULL-다수 허용 unique** 🔎 — 비-NULL unique 값만 conflict key로 등록하는 규칙 명문화 필요.
**S35. NULL unique 다중 허용 — false conflict** ⚠️ — "모든 unique 키"를 글자대로 하면 NULL끼리 겹침 오판 → 과직렬(안전 방향). NULL 키 제외해야 서버 의미론 일치.
**S36. cross-subclass 공유 unique(상속 형제)** ❌갭 — `(class,unique값)`이면 subA≠subB라 안 겹침. **D.3 commit-order는 apply 단계 동시 unique 진입을 못 막음**(FK는 자식이 부모 기다리는 비대칭이지만, 상속 형제는 비대칭 없어 누가 기다릴지 미정). → unique 키를 **공유 BTID(또는 superclass OID) 단위로 정규화** 필요.

### Round 7 — 동일 tx 내부 / 같은 PK 재사용
**S37. 같은 tx 내 INSERT 후 DELETE 같은 PK** ✅ — 1tx=1worker, 내부 순차.
**S38. 같은 tx 내 DELETE 후 INSERT 같은 PK(교체)** ✅ — 동일 워커 순서.
**S39. tx 경계 DELETE(T1)→INSERT(T2) 같은 PK** ✅ — 부분1 겹침 → 직렬.
**S40. 같은 PK 3 tx 연쇄(U→D→I)** ✅ — history 체인 단조 갱신.

### Round 8 — 대량/배치, hot row
**S41. 대량 DELETE 후 재INSERT 같은 PK 집합** ⚠️ — 단일 tx 10만 키가 history 폭증·축출 → 무관 tx까지 baseline 과직렬 캐스케이드(correctness 안전).
**S42. hot counter 단일 행 폭주** ✅ — 진짜 write-write 의존, 직렬이 정답.
**S43. 분포 편향(80/20)** ✅ — hot class 직렬+나머지 병렬(F.2 인정 한계).
**S44. class fan-out 폭증(1 tx가 500 class)** 🔎 — barrier 아닌데 의존 허브로 작동, 후속 다수가 이 tx로 수렴(fan-in 과직렬).

### Round 9 — FK 심화
**S45. 3단 FK 체인 A←B←C 교차 tx** ✅ — 부분2 부모키 주입이 다단계에 전이.
**S46. 자기참조 ON DELETE CASCADE 트리** ❌갭 — cascade 삭제 행이 repl_records에 안 남으면 conflict key 누락(설계 자인 미결).
**S47. ON UPDATE CASCADE 부모 PK→자식 FK 전파** ❌갭 — cascade 갱신 행 누락 + PK 이동 결합.
**S48. 부모 DELETE + 자식 RESTRICT(마스터서 거부)** ✅ — 거부된 연산은 복제 안 됨.

### Round 10 — 네트워크 재정렬/부모 DROP
**S49. 자식이 부모보다 먼저 도착** ✅ — LogReader가 commit_lsa 순서로 읽음, 게이트는 last_committed 기반이라 도착 순서 무관.
**S50. 부모 class DROP 후 자식 적용** ✅ — DDL barrier.
**S51. DDL+DML 혼합 tx** 🔎 — 혼합 tx의 barrier 트리거 입자 미정의.

### Round 11 — CUBRID 고유 (serial/OID/SET/상속/파티션)
**S52. serial 카탈로그 갱신 순서** ⚠️ — 사용자 컬럼 값은 안전하나 db_serial이 사용자 tx와 별도 commit_lsa로 분리될 때 엮임 미확인.
**S53. OID 직접 참조 컬럼(`OBJECT`/클래스 타입)** ❌갭 — **OID 참조는 FK 아님 → writeset 부분2에 안 잡힘** → dangling OID 위험. 설계·특수테이블 모두 미다룸. **CUBRID 고유 사각.**
**S54. SET/SEQUENCE 안의 OID 컬렉션** ❌갭 — 컬렉션 원소 OID 참조 무결성이 writeset 의존으로 번역 안 됨.
**S55. 파티션 키 변경 UPDATE(파티션 이동)** ✅ — 단일 tx 원자 + 파티션키 규칙.
**S56. repl 로그가 root class OID로 기록되면** 🔎 — class OID 입자(root vs partition)가 병렬도 결정, 코드 확인.
**S57. super-sub 공유 unique** ❌갭 — S36과 동형. F.3의 "commit 순서가 커버"는 오류.

### Round 12 — collation/charset/함수기반
**S58. ci(대소문자무시) collation unique** ⚠️ — 옵션 a로 마스터 단일 권위라 원리적 안전하나 **unique conflict key의 collation 정규화 명문 필요**.
**S59. charset(동일 전제)** ✅ — HA 동일 charset.
**S60. reverse/함수 기반 unique** 🔎 — conflict key가 원본 값인지 계산값인지 미정(false negative 위험).

### Round 13 — barrier 재개/워커 수/pending
**S61. barrier 직후 재개 순서** ✅ — barrier가 committed_lsa 경계 생성.
**S62. 워커 수(4) < 충돌 체인(10)** ✅ — 체인은 본질적 직렬.
**S63. pending 폭증(롱tx 부모 뒤 자식 적체)** ⚠️ — backpressure 미설계(설계 자인), OOM/지연.
**S64. barrier in-flight drain** 🔎 — barrier 진입 시 진행 워커 drain 프로토콜 미정의.

### Round 14 — 워커 크래시/재시도
**S65. 워커 commit 직전(②대기중) 크래시** ✅ — durable 전이라 committed_lsa 미전진, gap-free 재시작 안전.
**S66. durable commit 직후 grant 전 크래시** ✅ — gap-free 불변식 하 멱등 재적용 수렴.
**S67. committed_lsa 영속 ↔ durable commit 원자성** 🔎 — committed_lsa 영속이 durable보다 **앞서지 않음(≤)** 보장 순서 명문 필요(앞서면 미적용 skip 위험).
**S68. apply 에러 재시도 × commit 게이트 데드락** ⚠️ — 앞 순번 워커 영구 재시도 시 게이트 전체 정지(복제 멈춤). retry×게이트 backstop 부재.

### Round 15 — 멱등성/비결정/진도
**S69. 비결정 함수(RAND/SYS_TIMESTAMP) 컬럼** ✅ — 행 after-image라 비결정 무관.
**S70. 트리거 부수 행(슬레이브 off)** ✅ — 결과 행 복제 + 트리거 off.
**S71. SBR statement_log** ✅ — barrier.
**S72. required_lsa(LWM)가 롱tx에 고정** ⚠️ — correctness 안전하나 재시작 재적용량 폭증(lag).

### Round 16 — upsert/merge/LOB
**S73. MERGE/멀티행 upsert** ✅ — 마스터에서 구체 연산 확정 복제.
**S74. upsert가 unique 충돌로 update 전환** ⚠️ — unique 정규화 의존(cross-class면 S36 갭).
**S75. LOB+행 혼합 tx** ✅ — LOB 비복제, 행 부분만 (class,PK).
**S76. LOB locator 슬레이브 외부저장 미동기** 🔎범위 — 병렬화가 dangling locator 윈도우 넓히는지 운영 확인.

### Round 17 — XA/멀티소스/OID 재사용
**S77. XA prepared 구간 writeset history 등록 타이밍** 🔎 — commit_lsa 단조성 정합 확인.
**S78. U(T1)→D(T2) 후 무관 T3 병렬** ✅ — 의존 체인과 독립 tx 분리.
**S79. 멀티소스 fan-in** 🔎범위 — source별 committed_lsa 분리 필요(현 설계 단일 마스터 전제).
**S80. non-MVCC/reusable-OID 재사용 타이밍** ✅ — PK 식별이라 OID 재사용 무관.

### Round 18 — deferred 제약/추가 사각
**S81. deferred unique(SET CONSTRAINTS DEFERRED)** 🔎 — deferred가 슬레이브 apply 세션에서 보존되는지(중간 위반 허용).
**S82. unique swap 2 tx** ⚠️ — unique 키 정규화 의존(S33), cross-subclass면 S36 갭.
**S83. 카탈로그 class 갱신(DDL 부산물)** ✅ — DDL barrier.
**S84. 온라인 인덱스 빌드 중 동시 DML** 🔎 — barrier 후 새 unique의 conflict key 반영 타이밍.
**S85. generated column 기반 unique** 🔎 — 계산값 conflict key 정의 미정(S60 동형).

### 2차 판정 분포 (S33~S85, 총 53)
| 판정 | 개수 |
|---|---|
| ✅통과 | 24 |
| ⚠️위험 | 10 |
| ❌갭 | 6 (S36, S46, S47, S53, S54, S57) |
| 🔎확인필요 | 13 |

---

## 종합 메타 발견 (1·2차 통합)

1. **conflict 제약 집합이 CUBRID OO 도메인을 누락 (S53·S54, 신규 ❌).** 설계 모델은 {PK, 보조 unique, FK 부모, 상속 공유 unique}만 가정하나, CUBRID는 **`OBJECT`/클래스 타입 컬럼의 직접 OID 참조, `SET/MULTISET/SEQUENCE` 안의 OID 컬렉션**을 가진다. 이 참조는 `locator_check_foreign_key`를 안 타 writeset에 안 잡힘 → dangling OID. 빈도는 낮으나(레거시 OO) 설계·특수테이블 어디에도 없는 사각. → "OID 참조 컬럼 class는 barrier/same-class 보수화" backstop 명문 필요.
2. **상속 공유 unique를 commit-order로 못 덮음 (S36·S57, 신규 ❌).** F.3·특수테이블의 "commit 순서 보존이 커버"는 **부정확** — D.3은 durable commit 순서만, apply 단계 동시 unique 진입을 못 막음. FK식 부모키 주입(비대칭)으로 환원 불가(형제 간 비대칭 없음). → **공유 unique를 BTID/superclass OID 단위로 정규화**해 writeset에 포함해야.
3. **cascade FK 영향 행의 writeset 포함 미확정 (S46·S47, ❌).** ON DELETE/UPDATE CASCADE 연쇄 행이 repl_records에 남는지 = 설계 자인 미결. 안 남으면 conflict key 누락. → **server cascade 경로가 repl_log_insert를 자식마다 호출하는지 코드 확인 선결.**
4. **conflict key 정규화 규약 전반 미정 (S33·S58·S60·S85).** D.4 "unique 키 포함"만 적고 복합 unique 직렬화·collation case-fold·NULL 제외·함수/reverse/generated 인덱스 계산값을 단일 키로 만드는 규약 없음. → 불변식 **"writeset 키 = 서버 인덱스 키 표현과 동일 생성기"** 명문화(옵션 a라 마스터가 권위 보유 — 유리). NULL은 제외(false conflict 방지).
5. **commit 게이트 HOL 장애 전파 (S68) + backpressure 부재 (S63).** 앞 순번 워커 영구 재시도 시 게이트 전체 정지. retry×게이트·pending backpressure 미설계. → 재시도 상한/우회 + pending 큐 한도 정책 필요.
6. **committed_lsa 영속 ↔ durable commit 순서 불변식 (S67).** committed_lsa 영속이 durable commit보다 **앞서지 않음(≤)** 명문화 필요(앞서면 미적용 skip).
7. **긍정 확인**: 옵션 a(마스터 단일 권위)가 롤링 스키마·collation·비결정 위험을 구조적으로 줄임(S23·S58·S69). 표준 관계형 패턴(같은 PK 재사용·다단 FK·배치·hot row·upsert·트리거·SBR·failover)은 견고하게 ✅ 수렴.

## 수렴 판단
- **표준 관계형 패턴은 ✅로 수렴** — 핵심 메커니즘(write-write conflict key + FK 부모 주입 + barrier + 멱등 재적용 + D.3 게이트) 견고.
- **남은 ❌/🔎는 두 축에 집중**: (1) **conflict key 정규화 정밀도**(unique 변종 — 복합/NULL/collation/함수/generated/상속 공유 BTID), (2) **CUBRID OO 고유 참조**(OID/SET).
- **아직 수렴 안 됨.** 네 가지(서버 인덱스 키=writeset 키 불변식 / 상속 공유 unique BTID 정규화 / OID 참조 backstop / cascade 영향 행 코드 확인)가 명문화·확인되기 전까지 정밀화 시나리오에서 갭 지속 예상. 3차 배치 권장 광맥 = **conflict key 정규화 규약 + OO 도메인(OID/SET/method/active 트리거 연쇄)**.
