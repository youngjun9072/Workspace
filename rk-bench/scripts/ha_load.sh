#!/bin/bash
#
# HA 복제 부하 생성기 — applylogdb 병렬 writeset 관찰용
#
# csql 은 단일 세션이므로 병렬 트랜잭션은 csql 프로세스를 N 개 동시에
# 띄워서 만든다. 세션마다 SQL 파일을 미리 만들어 두고
# `csql --no-auto-commit -i <file>` 로 먹이므로, 접속은 라운드당 한 번뿐이고
# 그 안에서 트랜잭션 수백 개가 흐른다.
#
# 부하는 "트랜잭션 N 개 돌고 끝"이 아니라 "DURATION 초 동안 계속"이다.
# pstack 을 여러 번 뜰 시간을 확보하기 위한 것.
#
#   ./ha_load.sh setup          스키마 + 시드 데이터
#   ./ha_load.sh A [초]         시나리오 A — 무충돌 (세션별 전용 키 구간)
#   ./ha_load.sh B [초]         시나리오 B — 고충돌 (전 세션이 좁은 핫키 구간)
#   ./ha_load.sh C [초]         시나리오 C — 혼합
#   ./ha_load.sh D [초]         시나리오 D — 대형 트랜잭션
#   ./ha_load.sh clean          테이블 삭제
#
# 환경변수:
#   DB=basic DBUSER=dba SESSIONS=8 KEYSPACE=100000 HOT_KEYS=50 ./ha_load.sh B 120
#

set -u

DB=${DB:-testdb}
DBUSER=${DBUSER:-dba}
DBPASS=${DBPASS:-}

SESSIONS=${SESSIONS:-8}            # 동시 csql 프로세스 수
KEYSPACE=${KEYSPACE:-100000}       # 전체 키 범위
# 충돌을 일으킬 좁은 구간. 너무 좁으면(50 등) 마스터에서 트랜잭션끼리
# 거의 완전히 직렬화되어 슬레이브로 갈 로그가 안 생긴다. 슬레이브
# writeset 이 실제로 경합하면서도 마스터 처리량이 남는 선으로 잡는다.
HOT_KEYS=${HOT_KEYS:-500}
ROWS_PER_TXN=${ROWS_PER_TXN:-20}
BIG_ROWS=${BIG_ROWS:-2000}         # 시나리오 D 의 트랜잭션 크기
# 라운드가 길수록 지속시간 초과폭이 커진다(마감은 라운드 사이에만 본다).
TXNS_PER_ROUND=${TXNS_PER_ROUND:-100}

WORKDIR=${WORKDIR:-/tmp/ha_load}

# 로그인 셸을 거치지 않고 직접 실행해도 돌도록 환경을 자체 해결한다.
# 상속된 CUBRID 는 구버전 설치본을 가리킬 수 있으므로 신뢰하지 않는다.
# 다른 설치본으로 돌리려면 CUBRID_HOME 을 명시한다.
CUBRID=${CUBRID_HOME:-/home/youngjun/CUBRID_optdebug}
CUBRID_DATABASES=${CUBRID_DATABASES:-$CUBRID/databases}
LD_LIBRARY_PATH=$CUBRID/lib:$CUBRID/cci/lib:${LD_LIBRARY_PATH:-}
export CUBRID CUBRID_DATABASES LD_LIBRARY_PATH
CSQL=${CSQL:-$CUBRID/bin/csql}

# csql 은 CWD 에 csql.err / csql.access 를 떨구므로 WORKDIR 에서 실행한다.
csql_file () { ( cd "$WORKDIR" && "$CSQL" -u "$DBUSER" ${DBPASS:+-p "$DBPASS"} \
                   -C --no-auto-commit -i "$1" "$DB" ) ; }
csql_cmd ()  { ( cd "$WORKDIR" && "$CSQL" -u "$DBUSER" ${DBPASS:+-p "$DBPASS"} \
                   -C -c "$1" "$DB" ) ; }

# ------------------------------------------------------------------ setup

do_setup ()
{
  mkdir -p "$WORKDIR"

  echo "[setup] schema on $DB"
  csql_cmd "
CREATE TABLE IF NOT EXISTS ha_t1 (
  id     INT PRIMARY KEY,
  sess   INT,
  seq    INT,
  pad    VARCHAR(200),
  upd_at DATETIME
);
CREATE INDEX i_ha_t1_sess ON ha_t1 (sess, seq);

CREATE TABLE IF NOT EXISTS ha_t2 (
  id     BIGINT PRIMARY KEY,
  ref_id INT,
  val    BIGINT,
  pad    VARCHAR(100)
);
CREATE INDEX i_ha_t2_ref ON ha_t2 (ref_id);
" || return 1

  echo "[setup] seeding $KEYSPACE rows (batched 1000/stmt)"
  awk -v n="$KEYSPACE" -v batch=1000 '
    BEGIN {
      for (i = 1; i <= n; i++) {
        if ((i - 1) % batch == 0)
          printf "INSERT INTO ha_t1 (id,sess,seq,pad,upd_at) VALUES "
        printf "(%d,0,0,'\''seed%d'\'',SYSDATETIME)", i, i
        if (i % batch == 0 || i == n) print ";\nCOMMIT;"
        else printf ","
      }
    }' > "$WORKDIR/seed.sql"

  csql_file "$WORKDIR/seed.sql" > "$WORKDIR/seed.log" 2>&1 \
    && echo "[setup] done" \
    || { echo "[setup] FAILED — $WORKDIR/seed.log 확인"; return 1; }
}

# -------------------------------------------------------------------- gen
#
# 시나리오별 키 선택 규칙만 다르고 statement 구성은 공통이다.
#   A: 세션 전용 구간          — 충돌 없음, 최대 병렬
#   B: 전 세션이 핫키 구간     — 키마다 슬롯 대기 발생
#   C: 30% 핫키 + 70% 전용     — 실제 워크로드에 가까움
#   D: 전용 구간 + 대형 트랜잭션 — writeset 이 커질 때의 거동

gen_round ()
{
  local scen=$1 sess=$2 out=$3
  local base span rows i t id

  case $scen in
    A|D) base=$(( HOT_KEYS + 1 + (sess - 1) * ((KEYSPACE - HOT_KEYS) / SESSIONS) ))
         span=$(( (KEYSPACE - HOT_KEYS) / SESSIONS )) ;;
    B)   base=1 ; span=$HOT_KEYS ;;
    C)   base=1 ; span=$KEYSPACE ;;   # 아래에서 트랜잭션별로 재결정
  esac
  (( span < 1 )) && span=1

  rows=$ROWS_PER_TXN
  [ "$scen" = D ] && rows=$BIG_ROWS

  : > "$out"
  {
    for (( i = 1; i <= TXNS_PER_ROUND; i++ )); do
      if [ "$scen" = C ]; then
        if (( RANDOM % 100 < 30 )); then
          base=1 ; span=$HOT_KEYS
        else
          base=$(( HOT_KEYS + 1 + (sess - 1) * ((KEYSPACE - HOT_KEYS) / SESSIONS) ))
          span=$(( (KEYSPACE - HOT_KEYS) / SESSIONS ))
          (( span < 1 )) && span=1
        fi
      fi

      # 트랜잭션 안의 키를 오름차순으로 잠근다. 세션마다 잠금 순서가
      # 같아지므로 마스터에서 데드락 사이클이 생기지 않는다. 키 경합
      # 자체는 그대로 남으므로 슬레이브 writeset 충돌은 유지된다.
      # (정렬 없이 돌리면 핫키 구간에서 트랜잭션이 전부 abort 되어
      #  슬레이브로 갈 로그가 아예 생기지 않는다.)
      local plan=()
      for (( t = 0; t < rows; t++ )); do
        plan+=("$(( base + RANDOM % span )) $(( RANDOM % 10 )) $t")
      done
      while read -r id op seqno; do
        case $op in
          0|1|2|3|4|5)
            echo "UPDATE ha_t1 SET sess=$sess, seq=$i, pad='u$sess-$i-$seqno', upd_at=SYSDATETIME WHERE id=$id;" ;;
          6|7)
            # 같은 SQL 을 라운드마다 재사용하므로 PK 충돌을 upsert 로 흡수한다.
            echo "INSERT INTO ha_t2 (id,ref_id,val,pad) VALUES ($(( sess * 1000000000 + i * 10000 + seqno )),$id,$RANDOM,'i$sess') ON DUPLICATE KEY UPDATE ref_id=$id, val=$RANDOM;" ;;
          8)
            echo "DELETE FROM ha_t2 WHERE ref_id=$id;" ;;
          *)
            echo "UPDATE ha_t1 SET seq=seq+1 WHERE id=$id;" ;;
        esac
      done < <(printf '%s\n' "${plan[@]}" | sort -n -k1,1 -k3,3)
      # 10 번에 1 번은 롤백 — 미적용 트랜잭션 처리 경로도 같이 탄다.
      (( i % 10 == 0 )) && echo "ROLLBACK;" || echo "COMMIT;"
    done
  } >> "$out"
}

# -------------------------------------------------------------------- run

worker ()
{
  local scen=$1 sess=$2 deadline=$3
  local sql="$WORKDIR/${scen}_s${sess}.sql"
  local log="$WORKDIR/${scen}_s${sess}.log"
  local round=0

  # SQL 생성은 bash 루프라 느리다. 한 번만 만들고 재사용해야 csql 이
  # 쉬지 않고 돌아 applylogdb 에 부하가 끊기지 않는다.
  gen_round "$scen" "$sess" "$sql"

  : > "$log"
  while [ "$SECONDS" -lt "$deadline" ]; do
    round=$(( round + 1 ))
    csql_file "$sql" >> "$log" 2>&1
  done
  echo "$round" > "$WORKDIR/${scen}_s${sess}.rounds"
}

do_run ()
{
  local scen=$1 dur=${2:-120}
  mkdir -p "$WORKDIR"

  case $scen in A|B|C|D) ;; *) echo "unknown scenario: $scen" >&2; return 1 ;; esac

  local desc
  case $scen in
    A) desc="무충돌 — 세션별 전용 키 구간 (최대 병렬이 나와야 정상)" ;;
    B) desc="고충돌 — 전 세션이 키 $HOT_KEYS 개를 다툼 (슬롯 대기 관찰)" ;;
    C) desc="혼합 — 핫키 30% + 전용 70%" ;;
    D) desc="대형 트랜잭션 — 트랜잭션당 $BIG_ROWS 행" ;;
  esac

  echo "[run] 시나리오 $scen: $desc"
  echo "[run] 세션 $SESSIONS 개, ${dur}초 지속, db=$DB"
  echo "[run] ---- 지금부터 다른 터미널에서 샘플링 ----"
  echo "[run]   ./ha_pstack.sh applylogdb 40 1"
  echo

  local deadline=$(( SECONDS + dur ))
  local s pids=()
  for (( s = 1; s <= SESSIONS; s++ )); do
    worker "$scen" "$s" "$deadline" &
    pids+=($!)
  done

  # 진행 표시. \r 는 터미널에서만 의미가 있으므로, 파일로 리다이렉트된
  # 경우에는 찍지 않는다(안 그러면 로그가 한 줄로 수천 자 쏟아진다).
  while kill -0 "${pids[0]}" 2>/dev/null; do
    [ -t 1 ] && printf '\r[run] %ds / %ds' "$SECONDS" "$dur"
    sleep 2
  done
  wait
  [ -t 1 ] && printf '\r'
  printf '[run] 완료 (%ds)\n' "$SECONDS"

  local total=0 r
  for f in "$WORKDIR/${scen}"_s*.rounds; do
    [ -f "$f" ] && { read -r r < "$f"; total=$(( total + r )); }
  done
  echo "[run] 총 라운드 $total  (= 약 $(( total * TXNS_PER_ROUND )) 트랜잭션)"

  if grep -qiE "ERROR|error code" "$WORKDIR/${scen}"_s*.log 2>/dev/null; then
    echo "[run] 경고: 로그에 에러가 있습니다 — $WORKDIR/${scen}_s*.log"
  fi
}

# ------------------------------------------------------------------ clean

do_clean ()
{
  mkdir -p "$WORKDIR"
  echo "[clean] dropping tables"
  csql_cmd "DROP TABLE IF EXISTS ha_t2; DROP TABLE IF EXISTS ha_t1;"
  rm -f "$WORKDIR"/*.sql "$WORKDIR"/*.log "$WORKDIR"/*.rounds
  echo "[clean] done"
}

# ------------------------------------------------------------------------

[ -x "$CSQL" ] || { echo "csql not found: $CSQL (CUBRID 환경변수 확인)" >&2; exit 1; }

case "${1:-}" in
  setup)   do_setup ;;
  A|B|C|D) do_run "$1" "${2:-120}" ;;
  clean)   do_clean ;;
  *)       sed -n '2,28p' "$0"; exit 1 ;;
esac
