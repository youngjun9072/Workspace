# 컨셉 설계에서 실제 구현까지 바뀐 내용

컨셉 설계를 구현하면서 바꾼 선택과, 처음 설계에 빠져 있어 추가한 처리를 정리한다. 구현 중 발견한 오류도 함께 다루되, 설계 자체를 바꾼 경우와 구분한다. 각 절에서는 어떤 문제가 있었고 왜 현재 방식으로 구현했는지를 설명한다. 현재 함수와 처리 흐름의 상세 명세는 01 마스터 구현 설계와 02 슬레이브 구현 설계에서 다룬다.

## 1. 주요 변경 내용

마스터가 제약 키로 dependency를 만들고, 슬레이브가 그 순서를 지키면서 독립 트랜잭션을 병렬로 적용한다는 기본 구조는 유지했다. 구현에서는 다음과 같은 선택을 바꾸거나 빠진 처리를 보완했다.

| 구분 | 주요 내용 |
|---|---|
| 설계 변경 | 인덱스 비교에 맞춘 키 해시, 로그의 `dependency_is_ref` 제거와 frontier로 통일한 완료 판정, 공유 task/result queue, 오류 skip을 대신하는 applied-tx 마커 |
| 누락된 처리 보완 | 마스터 재시작, SYSOP·2PC·부분 rollback, worker별 적용 자원, 로그 보존과 종료 순서 |
| 구현 오류 수정 | 늦은 history clear와 probe의 경쟁, 중첩 SYSOP의 조기 기록, dbname 잠금 위치, 통계 저장 실패 후 마커 삭제 |

*표 1-1. 컨셉 설계의 변경, 누락된 처리의 보완, 구현 중 발견한 오류 수정의 구분*

이후 설명에서 사용하는 핵심 용어는 다음과 같다.

- **dependency**: 현재 적용 단위보다 먼저 완료돼야 하는 마스터 로그 위치다. `LOG_DUMMY_WSET_LABEL`의 `dependency_seq`로 전달한다.
- **history**: 마스터가 충돌 키별 WRITE·REF COMMIT 위치를 보관하는 메모리 map이다.
- **frontier**: 슬레이브가 앞에서부터 빈틈없이 적용한 마지막 COMMIT 또는 독립 적용되는 SYSOP_END의 LSA다. 뒤의 작업이 먼저 끝나도 앞에 미완료 작업이 있으면 전진하지 않는다.

## 2. 마스터 구현에서 바뀐 내용

마스터에서는 먼저 실제 인덱스 비교와 키 해시를 대조했다. 이후 여러 트랜잭션의 history 접근을 검토하고, 일반 COMMIT 외에 재시작·SYSOP·2PC·부분 rollback에서도 순서 정보가 유지되도록 보완했다.

### 2.1 충돌 식별자에서 클래스 OID를 제거했다

컨셉 설계는 `H(class_oid, index VFID, normalized key)`로 클래스와 인덱스를 함께 구분했다. 그러나 상속 계층의 여러 클래스가 물리적으로 같은 UNIQUE 인덱스를 공유할 수 있었다. 이때 클래스 OID를 넣으면 같은 인덱스의 같은 값도 다른 해시가 되어 충돌을 놓친다.

현재는 `H(index VFID, index와 같은 의미로 정규화한 key)`를 사용한다. 부모 PK의 WRITE와 자식 FK의 REF도 같은 부모 인덱스 VFID를 사용한다. 같은 물리 인덱스의 충돌은 클래스가 달라도 만나고, 서로 다른 인덱스는 VFID로 구분된다.

수정 전에는 상속 클래스 간 공유 B-tree의 dependency가 누락됐다. 수정 후 단위 테스트 47건·4,728 assertion과 HA 시험이 통과했다.

### 2.2 키 해시를 B-tree 비교 의미에 맞췄다

처음에는 문자열에 collation을 반영하고, 나머지 값은 packed image를 해시했다. 실제 인덱스와 대조하니 같은 값으로 비교되는 키도 타입이나 저장 표현에 따라 다른 해시가 될 수 있었다. 필요한 dependency가 사라지는 문제이므로, 키를 해시하기 전에 B-tree의 비교 규칙에 맞춰 정규화하도록 바꿨다.

| 대상 | 변경한 처리와 이유 |
|---|---|
| 문자열 | 인덱스가 무시하는 뒤쪽 문자를 제외한다. UCA expansion collation은 기존 pseudo key로 같은 키를 다르게 해시할 수 있어 비교 가중치열을 해시하고, 나머지는 기존 pseudo key를 사용한다. |
| NUMERIC | precision·scale이 달라도 같은 숫자는 같은 십진 문자열로 만들어 해시한다. |
| MONETARY | 인덱스가 비교하지 않는 통화 종류를 통일해 같은 금액이 같은 해시가 되게 한다. |
| VARBIT | 인덱스가 비트 길이 대신 바이트 수를 비교하므로 길이를 바이트 단위로 맞춘다. |
| FLOAT·DOUBLE | 같은 값으로 비교되는 `-0.0`과 `+0.0`을 하나로 맞춘다. |
| TIMESTAMPTZ·DATETIMETZ | 인덱스 비교에 사용하지 않는 zone을 제외한다. |
| 복합 키 | 원소를 `MAX_ALIGNMENT` 경계에서 패킹한다. 복합 FK는 각 원소를 대응하는 부모 PK domain으로 변환해 부모 키와 같은 MIDXKEY를 만든다. MATCH SIMPLE에서 원소 하나라도 NULL이면 REF를 만들지 않는다. |
| NaN | 하나의 동치 해시로 표현할 수 없어 트랜잭션 전체를 commit-order로 보낸다. |

*표 2-1. 인덱스 비교와 해시가 같은 키를 가리키도록 보완한 타입별 처리*

VARBIT·문자열 NUL·공백·복합 키·FK REF·NaN 등을 다룬 HA 쌍 시험 17건에서는 마스터와 슬레이브의 최종 데이터가 일치했고 적용 오류가 없었다. NaN은 commit-order 폴백으로 확인했다. 이 결과는 이후 추가한 NUMERIC 정규화와 UCA 가중치 해시까지 검증한 결과는 아니다.

정규화할 수 없는 값을 일부만 제외한 채 정상 writeset으로 사용해서는 안 된다. 키 생성 실패는 DML 오류로 반환하고, NaN처럼 별도로 정한 경우는 트랜잭션 전체를 commit-order로 처리한다.

### 2.3 로컬 writeset과 전역 history를 모듈로 분리했다

컨셉 설계에서는 트랜잭션의 키 목록과 전역 history를 하나의 writeset 구성요소로 설명했다. 구현에서는 두 자료의 수명과 잠금 책임이 달라 모듈을 나눴다. 로컬 목록은 트랜잭션이 끝나면 비우지만, history는 서버가 동작하는 동안 여러 트랜잭션이 함께 사용한다.

트랜잭션 키 수집, 키 해시, dependency 계산, history map, 설정, trace, 통계를 각각 분리했다. history의 준비·최종 해제는 transaction table 경로에 연결하고, `wset_History_initialized`로 잠금과 map의 중복 초기화·해제를 막는다.

호출자는 TBB accessor를 직접 다루지 않고 `writeset_history` API를 사용한다. 이 분리는 코드의 수명주기와 공개 API 경계를 기준으로 했으며, 구현 문서와 단위 테스트도 같은 책임에 맞춰 나눴다.

### 2.4 history clear와 probe에 같은 세대의 스냅샷을 보장했다

컨셉 설계에는 map이 가득 차면 비우고 `history_start`를 올리는 규칙이 있었다. 구현을 검토하면서 COMMIT 순서와 history 게시 완료 순서가 다를 수 있다는 문제가 드러났다. 늦게 게시한 과거 트랜잭션이 map을 비우면, 먼저 게시된 최신 COMMIT의 슬롯도 함께 지워진다. 그 과거 COMMIT만 새 하한으로 삼으면 지워진 최신 커밋을 이후 dependency에서 놓친다.

그래서 clear의 하한은 clear를 수행한 트랜잭션의 LSA가 아니라, 그 시점까지 기록된 가장 큰 COMMIT LSA인 `prev_commit_lsa`로 정했다. probe도 map·`history_start`·`prev_commit_lsa`를 clear 전 상태 또는 clear 후 상태 중 하나로만 읽도록 잠금 범위를 맞췄다. 이전 map과 새 하한을 섞어 읽으면 dependency가 낮아질 수 있기 때문이다.

키별 probe·publish는 `history_lock`을 공유로 잡고 TBB accessor로 접근한다. 전체 clear에서만 `seq_lock`과 배타 `history_lock`을 함께 잡는다. 게시 용량은 `wset_Publish_reserved`로 먼저 예약해, 동시에 게시한 트랜잭션들이 각자 용량 검사만 통과하고 합계로는 한도를 넘는 경우도 막는다.

단위 테스트에서 늦은 clear가 최신 하한을 보존하고 probe가 clear 전·후 상태를 섞지 않음을 확인했다. 운영 부하로 같은 타이밍을 재현한 결과는 없다. 키별 접근의 병렬성은 유지하고, 전체 clear에서만 배타 잠금을 사용한다.

### 2.5 폴백은 불완전한 writeset을 사용하지 않는다

초기 설계는 overflow나 키 변환 실패를 직전 COMMIT 기준으로 보수 처리했다. 이를 구현할 때는 정상 writeset을 포기하는 경우와 키 생성 자체가 실패한 경우를 구분했다.

키 수 한도, statement 복제, NaN, serial PK 인덱스를 아직 얻지 못한 경우는 로컬 키 전체를 버리고 commit-order로 처리한다. 반면 메모리 부족·domain 변환·복합 키 추출 실패는 DML 오류로 반환한다. 일부 키만 빠진 목록으로 커밋하면 A·B·C의 같은 키 충돌에서 B가 사라져, A와 C 사이에만 dependency가 남을 수 있다.

폴백 dependency는 `prev_commit_lsa`뿐 아니라 `history_start`보다도 낮아지지 않게 했다. COMMIT 뒤에는 키별 map을 비우고 하한을 유지해 이후 트랜잭션도 이 커밋을 기다리게 한다. 폴백은 병렬성을 줄일 수 있지만 순서를 누락해서는 안 된다.

하한 누락을 확인하는 단위 테스트는 수정 전 실패했고 수정 후 28건·4,459 assertion이 통과했다. HA에서도 재시작 직후 DDL의 dependency가 복구 하한을 가리키는 것을 확인했다. 폴백 원인은 통계로 구분한다.

### 2.6 dependency 라벨에서 `dependency_is_ref`를 제거했다

컨셉 설계는 WRITE 슬롯에서 온 dependency이면 해당 트랜잭션 한 건의 완료를, REF 슬롯에서 왔으면 그 LSA까지의 연속 완료를 확인하도록 했다. 그러나 여러 키의 선행 관계를 가장 늦은 LSA 하나로 줄인 뒤에는, 그 트랜잭션 한 건이 끝났다는 사실만으로 나머지 선행 작업의 완료까지 알 수 없었다.

실제 시험에서는 선행 관계 1,369개 중 18개가 보장되지 않았고, 8개가 역전돼 4행의 데이터가 달랐다. 이에 전송하는 `dependency_is_ref`를 제거하고 모든 dependency를 `dependency_seq <= frontier`로 판정하도록 바꿨다. 같은 seed의 수정 후 시험에서는 역전·미해제 pending·fail이 모두 0이었다.

마스터 내부의 `candidate_is_ref`는 남아 있다. `ref_seq`에서 온 최종 후보는 여러 참조 트랜잭션의 상한이므로 그대로 사용한다. 다른 후보는 `prev_commit_lsa`와 비교하되 `history_start` 아래로 내리지 않는다. 제거한 것은 슬레이브의 대기 방식을 나누던 전송 플래그다.

일부 task는 개별 완료만 볼 때보다 더 기다린다. 다만 기다리는 task는 pending list에 두므로 뒤의 독립 task까지 함께 멈추지는 않는다.

### 2.7 라벨 결정과 COMMIT 기록을 같은 로그 잠금 구간에 넣었다

COMMIT 직전에 history를 조회하더라도, 조회와 COMMIT 기록 사이에 다른 COMMIT이 들어오면 dependency가 실제 로그 순서를 반영하지 못할 수 있다. 따라서 단순히 `REPL → WSET_LABEL → COMMIT`의 기록 순서를 지키는 것 외에, dependency 결정 시점도 같은 잠금 구간에 넣었다.

현재는 dependency 계산, 복제 레코드·WSET_LABEL·COMMIT 기록, `prev_commit_lsa`와 폴백 하한 갱신을 `prior_lsa_mutex` 안에서 수행한다. 키 게시는 밖에서 하되 행 잠금과 MVCCID self-lock을 풀기 전에 끝낸다. 같은 키의 다음 트랜잭션은 이 잠금 때문에 게시 완료 뒤에 COMMIT 경로로 들어온다.

키 수만큼 수행하는 게시까지 전역 로그 잠금 안에 두면 다른 로그 기록도 오래 멈춘다. 현재 분리는 로그 순서 결정은 한 잠금 구간에 두고, 키 게시는 병렬로 진행하기 위한 것이다. 이 호출 순서는 코드로 확인했으며, 별도의 HA 재현 결과는 없다.

### 2.8 서버 재시작은 복구된 로그 끝을 history 하한으로 삼는다

history는 프로세스 메모리이므로 서버가 재시작하면 비어 있다. 이 상태에서 새 트랜잭션을 dependency 없이 기록하면 재시작 전 트랜잭션과의 순서가 끊긴다. 초기 컨셉 설계에는 이 연결 방법이 없었다.

history 전체를 저장·복원하는 대신, recovery가 끝났을 때 복구된 로그 끝을 `history_start`로 설정한다. 이후 dependency가 이 하한 아래로 내려가지 않게 해 재시작 전 작업이 끝난 뒤 새 작업을 적용하도록 했다. 일부 독립 트랜잭션도 기다리지만 재시작 전후의 순서는 보존된다.

복구된 로그 끝은 마지막 COMMIT 또는 독립 SYSOP_END보다 뒤일 수 있다. 이 값을 그대로 기다리면 슬레이브의 frontier가 도달하지 못해 새 task가 막힌다. 그래서 슬레이브는 현재 task보다 앞서 읽은 마지막 적용 경계로 dependency를 낮춘다. 해당 경계는 COMMIT 또는 라벨이 붙은 SYSOP_END다.

이 대기 조건은 단위 테스트에서 수정 전 실패했고, 수정 후 25건·4,304 assertion이 통과했다. HA에서는 apply info COMMIT 때문에 조건이 가려졌다. 분석 기록은 C1, 수정 커밋은 `285786829`다.

### 2.9 SYSOP_END를 별도 commit-order 적용 경계로 만들었다

초기 컨셉 설계는 일반 COMMIT의 dependency 계산과 게시를 중심으로 했지만, develop은 SYSOP_END에서도 복제 항목을 중간 적용한다. serial·INCR/DECR·checksumdb의 독립 operation은 바깥 트랜잭션이 ABORT해도 결과가 남아야 하므로, 병렬 applier도 이를 바깥 COMMIT과 별도로 처리해야 했다.

복제 레코드가 확정되는 SYSOP_END 앞에 WSET_LABEL을 기록하고, dependency를 `max(prev_commit_lsa, history_start)`로 정했다. 기록 뒤에는 `history_start`를 그 SYSOP_END까지 올린다. 완전한 충돌 키 집합을 보장할 수 없는 경로도 포함하므로, 독립 SYSOP는 키별 병렬 처리 대신 commit-order 장벽으로 순서를 지킨다. 슬레이브의 fragment 처리는 3.6절에서 설명한다.

이 처리를 추가한 뒤에는 중첩 SYSOP가 바깥 연산의 복제 레코드를 너무 일찍 기록하는 오류도 수정했다. 로그 위치가 정해지기 전에 기록하면 슬레이브가 해당 항목을 건너뛰고, 이후 바깥 연산이 ABORT되면 이미 전달한 변경을 취소할 수 없다. 복제 레코드 기록을 표시한 구간 안에서는 중첩 SYSOP가 그 레코드를 기록하지 않고, 구간을 닫은 연산의 SYSOP_END에서 기록하도록 고쳤다.

SYSOP 시작 때 로컬 writeset 위치도 표시한다. 독립 적용한 SYSOP의 키와 ABORT·부분 rollback으로 사라진 변경의 키는 바깥 COMMIT에서 다시 게시하지 않도록 제거한다. 다만 이미 발생한 commit-order 폴백은 안전을 위해 바깥 트랜잭션에도 유지한다.

NEED_FLUSH 생산자는 serial·INCR/DECR·checksumdb 세 경로다. 초기 fragment 시험은 최종 데이터가 일치했지만 라벨 19건이 선행 경계보다 낮아 현재 장벽 방식으로 보완했다. 중첩 SYSOP의 조기 기록은 INCR 100건 중 3건 유실로 재현해 `501e5f315`에서 수정했다. 같은 원인의 ABORT 위험은 코드 경로로 확인했다.

### 2.10 커밋 중인 키와 분할 부모 FK를 실제 충돌 대상으로 맞췄다

부모 PK WRITE와 자식 FK REF가 같은 해시를 만들더라도, FK·UNIQUE 검사 시점에 다른 트랜잭션이 그 키를 커밋 중일 수 있다. 이를 단순히 없는 키로 보면 마스터의 검사 결과와 history 게시 순서가 어긋난다. 커밋 중인 inserter·deleter의 COMMIT을 기다리도록 검사 경로를 보완했다.

분할 부모를 참조하는 FK도 별도로 확인했다. 부모 WRITE는 실제 키가 들어 있는 partition의 인덱스를 사용하는데 REF가 root 인덱스 VFID를 쓰면 두 해시가 만나지 않는다. REF도 실제 partition의 인덱스 공간을 사용하도록 맞췄다.

커밋 중인 부모 시험은 수정 전 2,000회 중 582행이 유실됐고 수정 후 10,000회 유실이 없었다. 분할 부모 시험도 수정 전 500/500 dependency 누락·81행 유실에서 수정 후 누락·유실·fail이 모두 0이 됐다.

### 2.11 2PC도 일반 COMMIT과 같은 dependency 경로를 탄다

초기 설계는 1PC local commit 경로만 구체화했다. 2PC가 NULL dependency로 나가고 키도 history에 게시하지 않으면, 해당 트랜잭션과 뒤의 같은 키 트랜잭션이 서로 독립인 것처럼 보인다.

2PC 완료도 복제 정보와 라벨을 기록하고 COMMIT LSA로 history를 게시하는 공통 완료 경로를 사용하도록 보완했다. 준비된 트랜잭션을 loose-end descriptor로 옮길 때는 로컬 키 목록, 폴백 상태·사유와 dependency를 함께 복사한다. 복제 레코드가 이동한 뒤에도 같은 키와 순서 정보로 커밋을 완료하기 위해서다.

loose-end 전환부터 라벨·COMMIT 기록과 history 게시까지 코드 경로를 확인했다. 분산 트랜잭션 HA 실측 기록은 없다.

### 2.12 로컬 writeset은 rollback 범위와 함께 줄어든다

전체 ABORT에서는 키를 게시하지 않으면 되지만, savepoint나 SYSOP의 부분 rollback 뒤에는 트랜잭션이 계속될 수 있다. 되돌린 변경의 키까지 바깥 COMMIT에 게시하면 실제로 남지 않은 변경 때문에 불필요한 dependency가 생긴다. 독립 SYSOP의 키를 바깥 COMMIT 위치에 다시 게시하는 것도 이미 확정한 SYSOP_END 경계와 맞지 않는다.

각 `LOG_WSET_ENTRY`에 수집 당시 LSA를 보관하고, `repl_log_abort_after_lsa()`가 복제 항목을 제거하는 경계에서 `wset_discard_keys_after_lsa()`로 같은 위치 이후의 키를 제거하도록 보완했다. 초기 설계에 없던 부분 rollback 처리를 추가한 것이다.

복제 항목과 키 제거가 같은 LSA를 쓰는 것은 코드로 확인했다. 별도 재현 기록은 없으며, 이 위치에 배치한 세부 이유는 코드에서 추정한 내용이다.

## 3. 슬레이브 구현에서 바뀐 내용

슬레이브에서는 로그 읽기, worker 배정, 완료 처리의 순서가 서로 다르다는 점을 실제 자료구조로 나눴다. 여기에 SYSOP 중간 적용, 재시작 중복 방지, failover와 자원 정리를 연결했다.

### 3.1 applylogdb 메인 스레드가 coordinator 역할을 맡는다

컨셉 설계는 로그 읽기와 배정·완료 처리를 역할별로 나눠 설명했다. 구현에서는 별도 coordinator 스레드를 만들지 않고, 기존 applylogdb 메인 스레드가 로그 읽기, task 구성, gate 판정, queue 배정, result 수거, retire와 apply info 저장을 맡는다.

로그를 읽은 위치, `LA_INFO`, 트랜잭션 슬롯은 기존 메인 스레드가 관리하던 상태다. coordinator를 별도 스레드로 만들면 이 자료를 함께 쓰기 위한 잠금과 전달 queue가 추가로 필요하다. 같은 스레드에서 처리하므로 coordinator 전용 자료는 잠금 없이 다루고, worker와 주고받는 task/result queue 및 공유 상태만 보호한다.

모듈 분리는 스레드 분리와 별개로 진행했다. 새 queue·목록·coordinator·worker 기능은 모듈로 나누되, 기존 적용 함수와 `LA_INFO` 상태는 `log_applier.c`에 두고 callback으로 연결했다. 기존 동작을 유지하면서 책임을 나누고, 코드 이동과 자원 수명 변경을 한꺼번에 진행하지 않기 위해서다. 이 경계는 현재 호출 관계를 기준으로 설명한 것이다.

### 3.2 task는 복제 항목을 복사하지 않고 트랜잭션 슬롯을 가리킨다

컨셉 설계에서는 완성된 task가 변경 목록을 가진다고 표현했다. 실제 구현은 복제 항목과 key image를 다시 복사하지 않고, `LA_TASK.apply`가 기존 `LA_APPLY` 슬롯을 가리키도록 했다. 목록을 복사할 때의 메모리 사용과 별도 소유권 관리를 줄이기 위한 선택이다.

worker는 슬롯의 복제 항목을 적용하면서 해제한다. 항목을 모두 처리해도 슬롯 자체는 coordinator가 result를 retire할 때까지 재사용하지 않는다. 슬롯에 남은 `start_lsa`가 필요한 로그의 보존 기준이기 때문이다. 항목 해제와 슬롯 반환은 서로 다른 시점이다.

이 수명은 task 정의와 in-flight 정리 경로에서 확인했다. `required_lsa`도 pending·in-flight task가 가리키는 슬롯을 포함하도록 연결했다.

### 3.3 완료 관리를 commit-order ring과 in-flight list로 나눴다

로그에서 읽은 순서, worker에 배정한 순서, worker가 끝낸 순서는 서로 다르다. 하나의 목록으로 모두 관리하면 worker가 완료한 슬롯을 반환하는 순서와 안전한 적용 위치를 계산하는 순서가 섞인다. 컨셉 설계의 pending·running·completed 상태를 다음 두 자료구조로 구체화했다.

- **commit-order ring**은 COMMIT과 라벨이 붙은 SYSOP_END를 로그 순서대로 보관한다. result가 오면 해당 항목을 완료로 표시하고, 앞에서부터 연속으로 완료된 위치까지 frontier를 전진시킨다. 별도의 완료 집합은 두지 않는다.
- **in-flight list**는 배정한 task와 result를 배정 번호(`seq`)로 연결한다. result는 완료 순서대로 오지만, 슬롯과 통계는 목록 앞에서부터 retire하며 정리한다.

검토 중에는 in-flight가 완료된 task로 가득 찬 상태에서 새 result를 기다리는 문제가 발견됐다. 더 실행 중인 task가 없다면 앞으로 올 result도 없어 영구 대기한다. 그래서 공간이 부족하면 새 result를 기다리기 전에 이미 완료된 head부터 retire하도록 고쳤다.

이 대기 조건은 코드 시나리오로 확인했으며 운영 부하로 재현한 결과는 없다. `committed_lsa`는 frontier에 따라 이동하고, 슬롯 반환은 in-flight의 배정 순서를 따르도록 두 역할을 분리했다.

### 3.4 gate는 frontier 하나만 보고, 막힌 task는 별도 pending list에 둔다

2.6절의 순서 역전 문제를 수정하면서 모든 dependency를 frontier로 판정하도록 통일했다. 이때 완료를 기다리는 task 때문에 coordinator의 로그 읽기까지 멈추면 뒤에 있는 독립 task도 실행하지 못한다.

gate는 dependency 판정과 commit-order ring을 맡고, 아직 실행할 수 없는 task는 별도 pending list에 보관하도록 나눴다. dependency가 충족되지 않았거나 task queue에 공간이 없으면 pending에 두고, coordinator는 뒤의 로그를 계속 읽는다. 대기 조건이 풀리면 pending task를 다시 확인한다.

마스터 재시작의 복구 위치처럼 현재 task보다 앞서 읽은 마지막 적용 경계보다 높은 dependency는 그 경계로 낮춘 뒤 ring에 넣는다. frontier가 도달할 수 없는 위치를 기다리지 않게 하는 보정이며, 배경은 2.8절에서 설명했다.

A1 동일 seed 시험에서는 독립 task가 계속 배정됐고, 역전·미해제 pending은 0이었다. 재시작 하한 보정은 gate 단위 테스트로 확인했다. pending 앞의 장기 트랜잭션이 뒤의 독립 task까지 막지 않도록 한 구조다.

### 3.5 worker별 queue 대신 공유 task/result queue를 사용한다

worker별 queue를 두면 coordinator가 어느 worker에게 보낼지 선택해야 하고, 긴 task가 몰린 worker의 queue에서 뒤 작업이 기다릴 수 있다. 이를 줄이기 위해 공유 task queue에 넣으면 먼저 준비된 worker가 꺼내도록 바꿨다. 완료 결과도 공유 result queue로 받으므로 별도의 worker 선택 정책은 두지 않는다.

worker 수는 `ha_apply_worker_count`로 기동 시 정한다. 기본값은 1이고 최댓값은 `HB_MAX_APPLY_WORKER_COUNT`다. queue의 단위 용량은 고정하며 task queue는 1024, commit-order ring·in-flight list·result queue는 `worker_count × 1024`다. 이 값과 공유 ring 구조는 현재 구현에서 확인했다.

같은 트랜잭션의 SYSOP fragment와 바깥 COMMIT을 같은 worker에 고정하지는 않는다. 두 적용 단위의 순서는 dependency로 지킨다.

공유 queue를 사용해도 coordinator가 무제한으로 로그를 읽을 수는 없다. commit-order ring이 가득 차면 로그 읽기를 멈추고 result 수거·frontier 전진을 수행한다. 별도 용량 token은 두지 않는다. 가장 오래된 ring 항목은 그보다 앞선 적용 경계까지만 기다리므로, worker가 정상 처리하면 완료되고 공간이 생긴다. 이 용량 제한은 coordinator가 worker보다 빠를 때 메모리가 계속 늘어나는 것을 막기 위해 추가했다(`la_coordinator_wait_for_commit_order_slot()`, `LA_COMMIT_ORDER_CAPACITY`).

### 3.6 라벨이 붙은 SYSOP_END를 fragment task로 적용한다

마스터가 독립 SYSOP에 라벨을 남기더라도, 슬레이브가 그 항목을 바깥 COMMIT까지 쌓아 두면 중간 적용의 의미가 사라진다. 바깥 트랜잭션이 ABORT해도 남아야 하는 serial 변경 등이 함께 버려질 수 있기 때문이다. coordinator가 그 자리에서 직접 적용하는 것도 worker의 적용·커밋 경로와 나뉘므로 피했다.

coordinator는 해당 SYSOP_END까지의 복제 항목을 바깥 `LA_APPLY`에서 떼어 별도 fragment 슬롯과 task를 만든다. fragment도 일반 task처럼 gate·queue·result 경로를 거치며 SYSOP_END LSA를 완료 처리한다. 바깥 COMMIT은 마지막 fragment LSA를 dependency에 포함해 그 뒤에 실행되게 한다.

라벨이 있지만 적용 항목이 없는 SYSOP_END도 처리해야 했다. worker task를 만들지 않았다는 이유로 완료 표시까지 빠지면, 뒤 task가 앞으로 오지 않을 result를 기다리며 frontier가 멈춘다. 해당 경우는 task 없이 ring에서 바로 완료 처리하도록 보완했다. 실패를 재현한 뒤 `complete_without_task` 경로가 4회 실행되는 것을 확인했고, fragment 시험은 역전·미해제 pending·fail이 모두 0이었다.

fragment 전용 슬롯은 원래 트랜잭션 슬롯 풀에 속하지 않는다. retire되지 않은 슬롯은 종료 경로에서 별도로 해제한다.

### 3.7 worker는 자기 DB connection과 적용 context를 가진다

컨셉 설계는 worker가 트랜잭션 전체를 한 DB 트랜잭션으로 적용한다고 설명했다. 이를 실행하려면 기존 단일 스레드가 사용하던 연결·오류 상태·압축 해제 버퍼·레코드 풀을 worker마다 분리해야 했다. 그대로 공유하면 한 worker의 적용 과정에서 다른 worker의 상태와 버퍼를 덮을 수 있다.

worker는 `db_restart_sub()`로 자기 sub-client를 열고, 오류 context, unzip buffer, RECDES pool, applied-marker statement를 따로 가진다. 로그 page pin 목록도 스레드별로 관리한다. 연결을 여는 과정은 기존 client 전역 초기화 때문에 mutex로 직렬화한다.

공유 queue이므로 모든 worker의 READY를 기다리지는 않는다. session이나 적용 context 초기화에 실패한 worker만 live count에서 빠지고, 남은 worker가 task를 계속 처리한다. 마지막 worker까지 빠지면 전체 종료를 요청한다. `pthread_create()` 자체가 실패한 경우는 시작 함수가 오류를 반환하고, caller의 종료 경로에서 이미 만든 thread에 종료를 알린 뒤 join한다.

worker별 session 정리와 시작 실패 처리는 코드 및 실패 훅으로 확인했다. 실패한 worker를 개별 재생성하는 시험은 없다. `MULTI_CONN_TO_A_SERVER`가 없는 빌드는 worker를 1개로 제한하고 coordinator와 client를 번갈아 사용한다.

여기에는 CS의 다중 연결 기반이 필요하다. 인증·trigger·session parameter·network state·error context 등을 sub-client별 또는 thread-local로 분리한 기반 위에, 현재 브랜치가 worker 수명주기와 API 호출을 연결했다. develop 병합 커밋은 `53fe1a6d13`이며, 진입 API는 `db_restart_sub()`·`db_shutdown_sub()`다.

### 3.8 worker 1개는 commit order로만 적용한다

worker가 하나인데도 dependency에 따라 pending에 두면, 뒤의 독립 task가 먼저 queue에 들어가 COMMIT 순서를 앞지를 수 있다. worker가 하나라 병렬 적용의 이득도 없으므로, 이 경우에는 develop처럼 COMMIT 순서를 지키도록 했다.

pending을 사용하지 않고 모든 task를 FIFO task queue에 넣는다. 다중 연결이 없는 빌드는 task 하나가 retire될 때까지 coordinator가 기다린다. 기본값 1은 직렬 적용 순서를 유지하고, worker 수를 늘릴 때 병렬 배정을 시작한다.

worker 1개 HA 시험에서 큰 UPDATE → 같은 키 UPDATE → 독립 marker가 로그 순서로 적용됐으며 pending 배정은 0이었다.

### 3.9 worker 결과 대기는 종료 요청을 주기적으로 확인한다

result queue에서 무기한 기다리는 동안 마지막 worker가 시작에 실패하면 앞으로 올 result가 없다. coordinator가 대기에서 빠져나오지 못해 SIGTERM도 처리하지 못하는 상태가 재현됐다.

result를 100ms 단위로 기다리고 대기할 때마다 종료 요청을 확인하도록 바꿨다. 시작 실패로 살아 있는 worker가 0이 되거나 worker가 서버 연결 오류를 만나면 전체 종료를 요청한다. 수정 후에는 전체 worker 시작 실패에서도 무기한 대기하지 않고 heartbeat의 재시작 경로로 빠져나왔다.

### 3.10 적용 데이터 COMMIT과 apply info COMMIT의 간극을 마커로 메웠다

worker는 자기 connection에서 데이터를 COMMIT하고, coordinator는 `committed_lsa`를 다른 트랜잭션에서 나중에 저장한다. 이 사이에 프로세스가 종료되면 이미 적용한 데이터가 있어도 재시작 위치는 앞에 남는다. 초기에는 이 구간을 다시 적용하면서 제한된 오류를 skip했지만, 재적용으로 생기는 모든 문제를 해결하지는 못했다.

현재는 실제 적용 항목이 있는 task(`total_rows > 0`)에 대해 적용 데이터와 같은 DB 트랜잭션에 `ha_applied_tx_marker` 행을 기록한다. 일반 task는 COMMIT LSA, SYSOP fragment task는 SYSOP_END LSA를 저장한다. 재시작 시 저장된 완료 위치 뒤의 마커를 읽어 이미 적용한 task를 통째로 건너뛴다. 복사 로그 경로로 applier를 구분하고, 행 DML과 statement에 같은 방식을 사용한다.

이 방식으로 바꾸기까지는 병렬 재적용의 교착과, 직렬 재적용에서도 남는 데이터 불일치를 차례로 확인했다.

**오류 skip에서 task별 마커로 바꾼 과정**

1. **재적용 가능 구간을 구분했다.** `max_committed_lsa`를 worker에게 task를 넘기기 전에 저장해, 재시작 시 이미 적용됐을 가능성이 있는 구간의 상한으로 사용했다. 이 구간에서 INSERT의 중복 키와 UPDATE·DELETE의 대상 행 없음 오류를 허용했다. 이 값은 연속 완료 위치나 실제 완료 최댓값을 뜻하지 않았다.
2. **복구 구간을 직렬로 실행했다.** 이미 후속 변경까지 적용된 행에 과거 행 이미지를 다시 적용하면, master에서 독립적이었던 트랜잭션도 slave에서 새롭게 잠금 충돌을 일으킬 수 있었다. 교착 후 재시작해도 같은 구간에서 교착을 반복해, 복구 구간에서는 task 하나가 retire될 때까지 기다린 뒤 다음을 넘겼다(`edd32308ac`).
3. **statement 재실행을 먼저 막았다.** DDL의 재실행 오류와 `UPDATE t SET n = n + 1`의 이중 반영은 행 오류 skip으로 해결할 수 없었다. statement가 포함된 트랜잭션에 데이터와 함께 단일 마커를 기록하도록 했다(`74acb3ea8a`).
4. **행 DML까지 task별 마커로 확장했다.** 아래 키 변경 예제처럼, COMMIT 순서대로 다시 적용해도 데이터가 달라질 수 있었다. statement 전용 마커를 모든 적용 task의 마커로 확장해 재실행 자체를 막았다(`72650ce0d0`). 이에 따라 복구 구간의 직렬 실행·오류 skip·`max_committed_lsa` 저장을 제거했다(`fe230a932f`).

키를 바꾸는 UPDATE에서는 최초 적용 순서를 지켜도 문제가 발생한다. 다음은 T1과 T2의 데이터 COMMIT은 끝났지만 apply info가 그 위치까지 저장되지 않은 상태에서 중단된 경우다.

```text
최초 적용
T1: PK=1 INSERT            → slave에 PK=1
T2: PK를 1 → 2로 UPDATE   → slave에 PK=2만 남음

apply info 저장 전 중단 → 마커 없이 재시작
T1 재적용: PK=1이 없으므로 INSERT 성공 → PK=1이 다시 생김
T2 재적용: 옛 PK=1로 찾아 PK=2로 변경하려 하지만 기존 PK=2와 충돌

결과: master에 없는 PK=1 행이 slave에 남음
```

*예제 3-1. 마커 없이 INSERT와 키 변경 UPDATE를 다시 적용하면, COMMIT 순서를 지켜도 이전 키가 되살아나는 경우*

T1의 INSERT는 중복 오류가 나지 않아 skip할 수 없다. T2의 UPDATE 유일 키 충돌은 당시 허용 오류에도 포함되지 않아 오류로 드러난다. 이 오류까지 무시하더라도 T1이 되살린 행은 남는다. 따라서 dependency나 gate의 순서를 바꾸는 것으로는 해결되지 않으며, 이미 적용한 T1·T2를 식별해 건너뛰어야 한다.

재적용 교착은 10월 11일 시험에서 9건이 기록됐고, 10월 19일에도 교착에 따른 재시작 반복이 기록됐다. 정확한 잠금 순환은 전부 확인하지 못했다. statement 시험에서는 수정 전 master `n=1`, slave `n=2`였고, 마커 적용 후 2회 모두 `n=1`, DDL 재실행 오류·fail 0이었다. 10월 28일 PK 시험의 유효 회차에서는 마커 적용 후 T1·T2가 모두 `rows=0`으로 건너뛰어졌고 데이터가 일치했다. 이는 note에 남은 확인 범위이며, 모든 재시작 조합을 검증했다는 뜻은 아니다.

재시작 시 개별 오류를 보고 재적용을 허용하는 방식에서, task의 적용 완료 기록을 확인하는 방식으로 바뀌었다. 마커는 apply info 저장과 같은 coordinator 트랜잭션에서 `committed_lsa` 이하만 지운다. 통계 저장 실패로 apply info UPDATE까지 취소된 경우에는 마커를 남기고, 기동 시 마커를 일부만 읽었다면 worker를 시작하지 않는다. 마커 DELETE는 잠금 승격에 따른 worker INSERT와의 교착을 피하기 위해 coordinator COMMIT 직전 마지막 SQL로 실행한다.

### 3.11 `required_lsa`가 pending·in-flight fragment까지 포함한다

기존 `required_lsa`는 미완료 트랜잭션 슬롯의 `start_lsa` 최솟값을 기준으로 했다. fragment를 별도 task로 나눈 뒤에는 원래 슬롯만 보면 안 된다. 바깥 트랜잭션이 ABORT돼 슬롯이 비어도 fragment는 pending·in-flight에 남아 그 로그를 사용할 수 있기 때문이다.

pending list와 in-flight list의 fragment 슬롯도 함께 확인하도록 보완했다. coordinator가 로그를 앞서 읽어도 미완료 task가 사용하는 archive log를 먼저 삭제하지 않기 위한 처리다.

ABORT 뒤 fragment만 남는 코드 경로를 확인했다. backlog와 archive 삭제를 결합한 장애 재현은 없다.

### 3.12 DONE 전환은 읽은 작업이 모두 끝날 때까지 보류한다

컨셉 설계에는 failover 시 queue를 drain한 뒤 DONE으로 바꾸는 원칙이 있었다. 구현에서는 queue만 비었다고 완료된 것이 아니라는 점을 보완했다. pending task, 실행 중이거나 아직 retire하지 않은 task, 앞의 완료를 기다리는 ring 항목도 남을 수 있다.

pending list·in-flight list·commit-order ring이 모두 비어야 drain이 끝난 것으로 판단한다. DONE 조건을 먼저 만나도 `holding done`으로 두고 result 수거와 retire를 계속한다. 임의의 30초 timeout으로 기다림을 끝내던 처리도 제거했다. 미완료 작업을 남긴 채 DONE과 dbname 잠금 해제를 알리면 다른 applier가 같은 DB에 쓰거나 승격된 DB에 아직 적용하지 않은 데이터가 남을 수 있기 때문이다.

failback 시험에서는 DONE 조건을 다시 확인하지 않아 상태가 멈춘 사례가 있었다. `done_deferred` 처리와 timeout 제거 후 회귀 시험에서는 worker COMMIT을 기다린 뒤 정상 승격했다. 긴 트랜잭션 때문에 failover가 늦어질 수는 있어도, 미완료 작업을 버리고 승격하지는 않는다.

### 3.13 dbname lock을 실제 쓰기 task 앞에서 다시 잡는다

develop은 트랜잭션을 적용하기 전에 dbname 잠금을 얻었다. 이식 중 이를 기동 시 한 번만 얻도록 바꾸면서 두 문제가 발생했다. 적용할 항목이 없는 비활성 applier도 시작부터 잠금을 기다려 로그 읽기·상태 보고·종료를 하지 못했고, HA 상태 변경으로 잠금을 놓은 뒤에는 다시 얻지 않은 채 적용을 계속했다.

컨셉 설계를 바꾼 것이 아니라 이식 과정의 오류를 수정한 것이다. 복제 항목이 있는 task를 queue에 넣기 전에 coordinator가 잠금을 확인·획득하고, drain이 끝난 뒤에만 해제하도록 고쳤다. 여러 applier 중 하나만 같은 슬레이브 DB에 쓴다는 기존 보장을 실제 task 실행 시점에도 유지한다.

replica·3노드 시험에서 잠금 소유자가 없는 쓰기 경로를 확인했다. 수정 후에는 실제 쓰기 applier가 소유자로 기록됐다.

### 3.14 항목 오류와 flush 오류를 트랜잭션 경계에서 처리한다

컨셉 설계는 worker가 오류를 result로 반환한다고만 설명했다. 실제 적용에서는 develop이 이미 구분하던 항목 오류와 task를 중단해야 하는 오류를 유지해야 했다. 마지막 항목의 비치명 오류가 함수 반환값으로 남으면, 같은 오류를 앞에서 만났을 때와 달리 task 전체가 중단되는 문제가 있었다.

서버 연결·flush 오류는 task 실패로 반환해 applier를 멈춘다. retry 목록의 항목 오류는 같은 항목을 다시 시도하고, 나머지 항목 오류는 develop처럼 fail 통계와 로그를 남긴 뒤 다음 항목으로 진행한다. 마지막 항목에서도 같은 정책을 적용하도록 반환값을 정리했다.

서버의 복제 force가 교착 희생 오류를 만났을 때도 호출 전체를 실패시켜야 했다. 잠금을 쥔 채 같은 호출의 다음 항목에서 다시 기다리면 교착을 끊지 못하기 때문이다.

중복 CREATE INDEX 오류 뒤에도 applier가 후속 INSERT를 적용하는 것을 확인했다. 교착 오류 전파 보완 뒤 400,000건 부하는 deadlock·worker 오류·fail이 모두 0이었다. 다만 비치명 항목 오류를 허용하는 기존 정책은 해당 행이 빠진 부분 COMMIT이 될 수 있으며, 이는 `fail_counter`와 error log에 남는다.

### 3.15 단일 스레드에서 공유하던 자원을 병렬 적용에 맞췄다

초기 설계는 worker 내부 적용을 하나의 기능으로 다뤘지만, develop의 파일 offset·SQL 로그·페이지 cache·레코드 버퍼는 한 스레드가 사용한다는 전제였다. 여러 worker가 적용을 시작하면서 공유 상태의 경쟁과 메모리 사용 문제가 드러났다.

| 대상 | 발생한 문제와 보완 |
|---|---|
| 파일 읽기·쓰기 | 같은 file descriptor의 offset을 바꿀 수 있어 `pread`·`pwrite`로 바꿨다. |
| SQL 로그 | 여러 worker의 문장과 파일 교체가 섞이지 않도록 기록·교체를 mutex로 묶었다. |
| 로그 페이지 cache | 다른 스레드가 쓰는 fix를 함께 풀지 않도록 스레드별 고정 목록을 사용한다. 공유 헤더를 갱신하는 copied-log header 갱신·archive 제거도 cache mutex로 보호한다. |
| 큰 RECDES 영역 | worker 수만큼 큰 메모리가 남을 수 있어 트랜잭션 종료 후 바로 반환한다. |
| COMMIT 뒤 MOP 정리 | 정리 중 새로 얻은 클래스 잠금을 다음 task 대기 중에도 유지하면 다른 worker의 DDL이 막힌다. 정리를 했다면 다시 COMMIT해 잠금을 푼다. |
| VSZ 제한 | worker 시작에 따른 메모리 증가를 누수로 판단하지 않도록 기준 크기를 worker 시작 뒤에 측정한다. |

*표 3-1. 병렬 worker 적용을 위해 보완한 공유 자원과 메모리 처리*

수정 전에는 page cache 경합으로 `ER_LOG_PAGE_CORRUPTED` 재시작 루프가 발생했다. 보완 후 400,000건 부하는 page 오류·deadlock 없이 통과했고, SQL log 9,475항목과 worker 10개 VSZ 시험도 통과했다.

공유 자원 경쟁과 별개로, 복사 중인 큰 레코드를 손상으로 오판하는 검사도 수정했다. 5.4MB 행 20건을 적용하는 시험에서 이 검사 때문에 7회 재시작했다. coordinator가 헤더를 읽었을 때 본문은 아직 복사 중일 수 있으므로, 다음 레코드 위치가 현재 copied log 끝보다 뒤라는 이유만으로 손상으로 판단하지 않도록 고쳤다. 필요한 페이지가 복사될 때까지 기존 경로에서 기다린다(`20442b73b`).

### 3.16 통계는 apply info와 함께 별도 시스템 테이블에 저장한다

trace는 개별 task의 dependency와 적용 순서를 추적하는 데 유용하지만, 양이 많고 실행마다 조건이 달라 병목을 비교하기 어렵다. dependency를 기다린 것인지, worker·queue가 부족한 것인지, coordinator의 result 수거가 늦은 것인지 나눠 보기 위해 통계를 추가했다.

`CLOCK_MONOTONIC` 시각을 task/result에 이어 전달해 dependency 대기·실행 자원 대기·queue 체류·적용·result 수거 시간을 나눈다. `_db_ha_apply_stat`과 `_db_ha_apply_worker_stat`에는 queue·pending 최대 깊이, 순서가 바뀐 완료 건수, worker busy와 동시 실행 시간 분포(`concurrency_usec`)를 저장한다. `applyinfo`는 이를 바탕으로 평균 병렬도와 worker 활용률을 보여준다. busy·동시 실행·worker별 건수는 `has_items=true`인 task만 세어 빈 COMMIT이 병렬도를 부풀리지 않게 한다.

통계는 apply info를 저장하는 트랜잭션에서 함께 갱신한다. 통계 문장만 실패하면 savepoint로 돌아가 apply info 저장을 계속한다. 그러나 전체 트랜잭션이 취소됐을 때까지 저장을 계속하면, apply info UPDATE는 사라졌는데 마커만 삭제되는 문제가 생긴다. 시험에서도 이 상태로 재시작해 29개 COMMIT이 재적용됐다. `b984637bb`에서 savepoint 복귀 실패를 오류로 전달하고, coordinator가 마커를 남긴 채 ABORT하도록 수정했다.

시각 수집, 집계식, 카탈로그 저장과 `applyinfo` 출력은 코드로 확인했다. 지표 선정 효과를 비교한 별도 성능 시험은 없다. 마스터의 고빈도 카운터는 이 테이블에 저장하지 않고 메모리와 `SHOW WRITESET STATUS`로 조회한다.

### 3.17 라벨이 없거나 읽히지 않을 때 독립 task로 만들지 않는다

정상 경로에서는 마스터가 COMMIT 앞에 `LOG_DUMMY_WSET_LABEL`을 기록한다. 하지만 슬레이브가 이 레코드를 읽지 못했을 때 dependency를 NULL로 두고 넘어가면, 순서 정보를 모르는 task가 아무것도 기다리지 않고 실행된다.

라벨이 페이지 경계 등으로 완전히 읽히지 않으면 `final_lsa`를 전진시키지 않고 같은 레코드를 다시 읽도록 했다. 복제 항목이 있는 COMMIT인데 같은 `trid`의 라벨이 없으면 직전 ring tail을 dependency로 사용해 앞선 적용 단위가 모두 끝난 뒤 실행한다. 읽은 라벨은 같은 트랜잭션의 다음 COMMIT 또는 SYSOP_END가 소비하면 비운다.

라벨 읽기 실패가 NULL dependency로 이어지는 경로는 코드로 확인했다. 실패 훅 실측은 없고 수정 후 일반 회귀 시험만 수행했다. 데이터 변경이 없는 COMMIT은 기존처럼 dependency 없이 완료할 수 있다.

## 4. 배포와 종료에서 추가로 정한 사항

새 로그 형식과 테이블은 양쪽 노드가 함께 이해해야 한다. 종료할 때도 worker만 멈추는 것으로 끝나지 않아, 공유 자료와 재시작에 남길 상태의 수명을 함께 정리했다.

### 4.1 로그 레코드 형식은 양 노드가 동시에 이해해야 한다

`LOG_DUMMY_WSET_LABEL`은 같은 `trid`의 COMMIT 또는 SYSOP_END 바로 앞에 기록하고 슬레이브가 읽는 형식이다. `dependency_is_ref`를 제거할 때도 마스터 기록 형식과 슬레이브 해석을 함께 바꿨다. 한쪽만 바뀌면 dependency LSA의 offset을 잘못 읽을 수 있다.

따라서 서로 다른 로그 형식을 쓰는 바이너리의 혼합 HA 운용은 이번 범위에서 지원하지 않는다. 새 로그 타입의 구버전 호환은 버전 업그레이드 정책에서 다뤄야 한다. 기록·복구·읽기 형식은 코드로 확인했으며, 신·구 버전 혼합 HA 시험은 없다.

### 4.2 통계·마커 테이블은 서로 다른 수명 정책을 쓴다

기존 설계는 `_db_ha_apply_info`에 적용 위치를 저장하는 구조가 중심이었고, 새 테이블의 생성·실패 처리는 구체화하지 않았다. 구현에서는 통계와 마커의 역할이 달라 생성 방식과 실패 정책도 나눴다.

통계 테이블은 시스템 카탈로그로 설치한다. 관측 기능이므로 테이블이 없으면 통계만 끄고 적용은 계속한다. 반면 `ha_applied_tx_marker`는 재시작 중복 적용을 막는 상태이며, worker 데이터와 같은 DB 트랜잭션에 기록해야 한다. applylogdb가 직접 만들고, 생성하거나 끝까지 읽는 데 실패하면 worker를 시작하지 않는다. 행 DML과 statement를 별도 마커로 나누지는 않는다.

HA 시험에서는 마커 테이블 생성이 상대 노드로 복제되지 않고 마커 행에 적용 데이터의 COMMIT LSA가 기록되는 것을 확인했다. 기존 DB에 카탈로그 컬럼을 자동 추가하는 migration은 이번 범위에 포함하지 않았다.

### 4.3 worker가 참조하는 자료는 join 뒤에 해제한다

컨셉 설계에는 worker를 깨우고 join한 뒤 자원을 해제하는 큰 순서가 있었다. 구현에서는 task가 가리키는 슬롯·마커 배열·page cache까지 그 순서를 지켜야 했다. 이 자료를 먼저 해제하거나 이전 task의 포인터를 남기면, 같은 프로세스의 재시작에서 `required_lsa` 계산이나 다음 task가 잘못된 메모리를 참조할 수 있다.

slave kill 시험 3회 중 1회에서 해제된 자료를 가리키는 포인터 때문에 `required_lsa=0|0`이 저장됐고, 이후 699회 기동 실패가 반복됐다. 종료 처리는 다음 순서로 정리했다.

```text
task queue에 종료 알림
  → worker가 현재 task를 끝내고 종료
  → worker join
  → retire되지 않은 fragment 슬롯 해제
  → in-flight·pending 비우기
  → LA_APPLY 슬롯·page cache·마커 배열 정리
```

*그림 4-1. worker 종료 후 task와 공유 자원을 해제하는 순서*

다음 실행에서는 이전 pending·frontier·fragment 포인터가 사용되지 않도록 초기화한다. 해당 기동 실패 사례의 수정 후 반복 실측 기록은 없다.
