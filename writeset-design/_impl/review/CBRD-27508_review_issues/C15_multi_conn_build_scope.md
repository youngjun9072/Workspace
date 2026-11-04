# C15. `MULTI_CONN_TO_A_SERVER`가 전체 빌드에 켜짐

## 1. 메타
| 항목 | 내용 |
|---|---|
| 등급 | Medium → **판단 필요(빌드 범위, CS팀과 협의)** |
| 상태 | 사실 확인(10-23). 수정 안 함 |
| 판정 | 사실은 확정(코드). 이 브랜치의 커밋 `cb0095bf2`가 전체 빌드에 켬 |
| 신규/기존 | 신규(이 브랜치). 기반 브랜치(CBRD-26779, 리뷰 기준선 `a9a0dc78d`)에서는 `#add_definitions(-DMULTI_CONN_TO_A_SERVER)`로 꺼져 있다. 그 줄은 CS팀 POC 커밋 `bfabd3c3f`(CBRD-26484)가 처음 넣었다 |
| 지적한 리뷰어 | 4명(종합 문서 2절) |
| 코드 기준 | `882308890` |

## 2. 무엇인가
- CUBRID 클라이언트는 원래 한 프로세스가 서버에 접속 하나만 가지며, 접속 상태(트랜잭션, 오류, 작업 공간 등)를 프로세스 전역 하나로 관리한다.
- 병렬 applylogdb는 worker마다 자기 접속으로 동시에 적용하므로, 이 상태를 접속(스레드)마다 따로 두는 코드가 필요하다. 그 코드를 켜는 컴파일 스위치가 `MULTI_CONN_TO_A_SERVER`다.
- `#if defined (CS_MODE) && defined (MULTI_CONN_TO_A_SERVER)`로 동작이 갈리는 파일이 27개다. 예: `error_manager.c`, `boot_cl.c`, `db_admin.c`, `network_cl.c`, `network_interface_cl.c`, `schema_manager.c`, `authenticate.c`, `locator.c`, `connection_cl.cpp`, `client_support.cpp`, `util_cs.c`.

## 3. 지적
- 이 브랜치의 커밋 `cb0095bf2`(10-16, `[CBRD-27508] enable MULTI_CONN_TO_A_SERVER for the parallel applier`)가 기반 브랜치에서 주석 처리돼 있던 줄을 풀었다.
  - 커밋 메시지: 꺼져 있으면 worker가 `db_restart_sub ()`를 건너뛰고 coordinator의 접속 하나를 같이 써서, 요청과 응답이 한 소켓에서 섞여 applier가 멈춘다.
- 루트 `CMakeLists.txt:607`의 `add_definitions(-DMULTI_CONN_TO_A_SERVER)`로 켜져, applylogdb뿐 아니라 csql, broker(CAS), 각종 유틸리티 같은 모든 클라이언트가 이 경로로 빌드된다.
- 다른 클라이언트의 동작·성능 회귀는 확인되지 않았다.
- develop에는 이 스위치를 쓰는 파일이 7개 있지만 `CMakeLists.txt`에서 켜지 않는다.

## 4. 판단
- 병렬 applier에는 이 스위치가 필요하다. 꺼 두면 applier가 멈춘다(`cb0095bf2` 메시지).
- 문제는 켜는 범위다. 기반 브랜치는 기본으로 꺼 두었는데, 이 브랜치가 전체 빌드에 켰다. 이 파일들은 모든 클라이언트가 같이 쓰는 클라이언트 라이브러리(`cubridcs`)에 들어 있어서, applylogdb에만 켜려면 라이브러리를 따로 빌드해야 한다.
- 정할 것(CS팀과 협의):
  1. 다중 접속 기반을 develop에 넣을 때 이 스위치를 전체에 켜는 것이 CS팀의 계획인지.
  2. 그렇지 않다면 applylogdb용 라이브러리를 따로 빌드할지.
  3. 전체에 켠다면 다른 클라이언트(csql, CAS, 유틸리티)의 회귀 시험을 누가 할지.
- 이 결정 전까지는 지금 상태(전체에 켬)로 둔다.

## 5. 정정 기록
- 10-23 처음 작성할 때 "기반 브랜치의 CS팀 커밋 `bfabd3c3f`에서 들어왔다"고 적었다. 기준선의 `CMakeLists.txt`를 확인해 보니 그 줄은 꺼져 있었고, 켠 것은 이 브랜치의 `cb0095bf2`였다. 위 내용으로 고쳤다.
