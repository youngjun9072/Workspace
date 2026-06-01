# UPDATE 콜체인 분석 자료

CUBRID `cub_server testdb` 단일 프로세스 **on-CPU perf** 캡처(config 적용 병렬 복제 PoC 빌드, 2026-06-01)에서
UPDATE 워크로드의 콜체인을 분석한 자료. raw perf 데이터(`oncpu.data` 1.0GB, `oncpu.script` 149MB)는
용량 때문에 제외했고, **분석 산출물만** 담았다.

- 캡처: `-F 999`, dwarf call-graph, 전체 126,337 sample
- 진입 경로: 복제 적용 경로 (`slocator_repl_force`→`xlocator_repl_force`→`locator_update_force`→`heap_update_logical`)
- ※ root 를 `locator_update_force` 로 잡음 — 이 캡처는 복제 적용 경로라 클라이언트 SQL 엔트리 `qexec_execute_update` 는 거의 부재(68 frame)

---

## 먼저 볼 것

👉 **`CALLCHAIN.md`** — 이 자료의 메인 문서. 캡처 정보 + 그림 + 상위 함수표 + 콜트리 + 관찰(INSERT 대비 포함)을 한 곳에 모았다.
GitHub에서 그대로 렌더되고, 콜그래프 PNG도 인라인으로 보인다.

## 무엇을 볼 때 어떤 파일?

| 알고 싶은 것 | 볼 파일 |
|---|---|
| **전체 요약 / 처음 볼 때** | `CALLCHAIN.md` |
| UPDATE write 경로만 (locator_update_force=100% 기준) 콜트리 | `analysis/calltree_root.txt` |
| **전체 캡처**(모든 서버 스레드·기능) 콜트리 (% of total) | `analysis/calltree_full.txt` |
| 한 함수가 전체에서 차지하는 비중 (그림으로, 클릭 zoom) | `analysis/flame_full.svg` ※브라우저로 열기 |
| UPDATE write 경로만 flamegraph | `analysis/flame_locator_update_force.svg` ※브라우저로 열기 |
| 콜체인을 노드-엣지 그래프 그림으로 | `analysis/callgraph.png` (벡터: `callgraph.svg`) |
| UPDATE 경로에 등장한 **전 함수 평탄 목록** (컷오프 없음) | `analysis/inclusive_all.txt` |
| 캡처 **전체의 전 함수 평탄 목록** (1,615개, 컷오프 없음) | `analysis/inclusive_total.txt` |
| 재분석용 raw count (edge/inclusive) | `analysis/callgraph_data.json`, `fulltree_data.json` |

## 파일별 역할

### 문서
- **`CALLCHAIN.md`** — 메인. ① 캡처 정보 ② 그림 링크 ③ 상위 inclusive 함수표 ④ 관찰(+INSERT 대비) ⑤ root=100% 콜트리 전문 ⑥ 전 함수표 ⑦ 전체(thread별) 콜체인 전문.

### 그림
- **`analysis/flame_full.svg`** — 전체 on-CPU flamegraph. 모든 스레드·함수. 브라우저로 열면 클릭 zoom / Ctrl+F search.
- **`analysis/flame_locator_update_force.svg`** — `locator_update_force` 포함 stack 만 추린 write-path flamegraph.
- **`analysis/callgraph.png` / `.svg`** — graphviz 노드-엣지 콜그래프 (root subtree, 노드 ≥0.5% root, 엣지 ≥30 sample). PNG는 문서/GitHub 인라인용, SVG는 확대용.

### 콜트리 (텍스트)
- **`analysis/calltree_root.txt`** — `locator_update_force`=100% 기준 top-down 콜트리. UPDATE write 경로 내부 구조에 집중. 노드 % = root 포함 sample 대비. (노드컷 0.1%, MIN_EDGE 30)
- **`analysis/calltree_full.txt`** — `(ALL on-CPU)`→thread(comm)→함수 의 전체 콜트리. 노드 % = 전체 sample 대비. transaction 외 connections/vacuum/dwb-flush/log-flush 등 모든 서버 스레드 포함. (노드컷 0.2%, thread컷 0.3%, MIN_EDGE 30)

### 함수 평탄 표
- **`analysis/inclusive_all.txt`** — `locator_update_force` 경로에 등장한 함수 inclusive %(분모=root sample). 컷오프 없음.
- **`analysis/inclusive_total.txt`** — 캡처 전체 함수 inclusive %(분모=전체 sample). 컷오프 없음. **"이 함수 진짜 안 잡혔나?"** 확인할 때 여기 grep.

### 재현 (참고)
이 산출물은 raw perf 캡처(`oncpu.script`)에서 생성됐다. raw 와 생성 스크립트
(`build_callgraph.py`, `build_fulltree.py`)는 용량/무용 때문에 여기엔 두지 않았고,
원본 측정 디렉토리에 있다: `bench_sampling/perf-runs/20260601-203730-cubserver-oncpu-config-parallel-poc-update/`.
재생성이 필요하면 거기서 스크립트를 돌린다. (생성 규칙·컷오프는 위 §파일별 역할에 명시.)

## 읽는 법 (주의)

노드 % 는 **inclusive**(그 함수가 stack 어디든 등장한 sample 비율)이고, 한 함수가 여러 호출 지점에 나오면
**그 전역 % 가 매 위치마다 동일하게** 찍힌다(master perf REPORT 와 동일 규칙). 그래서 트리에서 자식 % 가
부모 % 보다 커 보일 수 있다(예: `log_append_undoredo_crumbs` 45%). edge-local 비율이 아니라 **전역 inclusive 비중**으로 읽을 것.

## INSERT 와 비교

`../1.insert_call_chain/` 에 동일 형식의 INSERT 자료가 있다. 요약:
- UPDATE 는 **로그 append 경로**(`heap_log_update_physical`→`log_append_undoredo_recdes`→`prior_lsa_*`)가 INSERT 보다 확연히 무겁다.
- `log_diff`(redo diff)는 UPDATE 에만 큼.
- UPDATE 는 기존 row lock+escalation(`locator_lock_and_get_object_*`, `lock_escalate_if_needed`) 부담이 별도.
- 페이지 갱신은 `spage_update`→`spage_compact`(가변길이 compaction)가 INSERT 의 `spage_insert_at` 자리를 대체.
