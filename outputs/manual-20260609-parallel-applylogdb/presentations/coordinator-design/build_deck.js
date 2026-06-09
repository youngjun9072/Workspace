const pptxgen = require("pptxgenjs");
const path = require("path");

const pptx = new pptxgen();
pptx.layout = "LAYOUT_WIDE";
pptx.author = "Codex";
pptx.subject = "Parallel applylogdb coordinator design";
pptx.title = "병렬 applylogdb 코디네이터 설계";
pptx.company = "CUBRID";
pptx.lang = "ko-KR";
pptx.theme = {
  headFontFace: "Arial",
  bodyFontFace: "Arial",
  lang: "ko-KR",
};
pptx.defineLayout({ name: "WIDE", width: 13.333, height: 7.5 });
pptx.layout = "WIDE";
pptx.margin = 0;

const ROOT = path.resolve(__dirname, "../../../..");
const IMG = path.join(ROOT, "8.concept_design/images");
const OUT = path.join(ROOT, "parallel-applylogdb-coordinator-design.pptx");

const C = {
  ink: "18212B",
  muted: "657180",
  light: "F4F6F8",
  line: "D8DEE6",
  blue: "2457A6",
  cyan: "00A7B5",
  green: "2F8F5B",
  orange: "D96C2C",
  red: "B74343",
  navy: "0E2942",
  white: "FFFFFF",
  yellow: "F1B434",
  violet: "6C5CE7",
};

function addFooter(slide, section, idx) {
  slide.addShape(pptx.ShapeType.line, { x: 0.5, y: 7.08, w: 12.33, h: 0, line: { color: C.line, width: 0.8 } });
  slide.addText(section, { x: 0.5, y: 7.15, w: 5.5, h: 0.18, fontFace: "Arial", fontSize: 7.5, color: C.muted, margin: 0 });
  slide.addText(String(idx).padStart(2, "0"), { x: 12.25, y: 7.13, w: 0.6, h: 0.2, fontFace: "Arial", fontSize: 8, bold: true, color: C.muted, align: "right", margin: 0 });
}

function title(slide, eyebrow, headline, sub) {
  slide.addText(eyebrow, { x: 0.58, y: 0.36, w: 4.6, h: 0.2, fontSize: 8.5, bold: true, color: C.cyan, breakLine: false, margin: 0 });
  slide.addText(headline, { x: 0.55, y: 0.68, w: 9.6, h: 0.58, fontSize: 25, bold: true, color: C.ink, fit: "shrink", margin: 0 });
  if (sub) slide.addText(sub, { x: 0.58, y: 1.28, w: 8.8, h: 0.28, fontSize: 10.5, color: C.muted, fit: "shrink", margin: 0 });
}

function pill(slide, text, x, y, w, color) {
  slide.addShape(pptx.ShapeType.roundRect, { x, y, w, h: 0.34, rectRadius: 0.06, fill: { color }, line: { color } });
  slide.addText(text, { x: x + 0.08, y: y + 0.085, w: w - 0.16, h: 0.12, fontSize: 7.2, bold: true, color: C.white, align: "center", margin: 0, fit: "shrink" });
}

function box(slide, text, x, y, w, h, opts = {}) {
  const fill = opts.fill || C.white;
  const line = opts.line || C.line;
  slide.addShape(pptx.ShapeType.roundRect, { x, y, w, h, rectRadius: 0.05, fill: { color: fill }, line: { color: line, width: opts.width || 1 } });
  slide.addText(text, { x: x + 0.14, y: y + 0.14, w: w - 0.28, h: h - 0.26, fontSize: opts.fontSize || 10.5, bold: !!opts.bold, color: opts.color || C.ink, fit: "shrink", valign: "mid", margin: 0 });
}

function arrow(slide, x1, y1, x2, y2, color = C.blue) {
  slide.addShape(pptx.ShapeType.line, { x: x1, y: y1, w: x2 - x1, h: y2 - y1, line: { color, width: 1.5, beginArrowType: "none", endArrowType: "triangle" } });
}

function bulletPanel(slide, x, y, w, items, color = C.ink) {
  items.forEach((item, i) => {
    const yy = y + i * 0.56;
    slide.addShape(pptx.ShapeType.ellipse, { x, y: yy + 0.08, w: 0.12, h: 0.12, fill: { color: item.color || C.cyan }, line: { color: item.color || C.cyan } });
    slide.addText(item.text || item, { x: x + 0.23, y: yy, w, h: 0.34, fontSize: 11, color, fit: "shrink", margin: 0 });
  });
}

function image(slide, file, x, y, w, h) {
  slide.addImage({ path: path.join(IMG, file), x, y, w, h });
}

function chapterSlide(num, label, claim, detail, color) {
  const s = pptx.addSlide();
  s.background = { color: C.navy };
  s.addShape(pptx.ShapeType.rect, { x: 0, y: 0, w: 13.333, h: 7.5, fill: { color: C.navy }, line: { color: C.navy } });
  s.addShape(pptx.ShapeType.rect, { x: 0, y: 0, w: 0.18, h: 7.5, fill: { color }, line: { color } });
  s.addText(num, { x: 0.7, y: 0.72, w: 1.0, h: 0.38, fontSize: 14, bold: true, color, margin: 0 });
  s.addText(label, { x: 0.7, y: 1.28, w: 4.5, h: 0.28, fontSize: 10, bold: true, color: "A8B4C2", margin: 0 });
  s.addText(claim, { x: 0.7, y: 2.0, w: 9.6, h: 1.2, fontSize: 30, bold: true, color: C.white, fit: "shrink", margin: 0 });
  s.addText(detail, { x: 0.73, y: 3.55, w: 8.2, h: 0.72, fontSize: 15, color: "DDE6EF", fit: "shrink", margin: 0 });
  return s;
}

// 1
{
  const s = pptx.addSlide();
  s.background = { color: C.light };
  s.addShape(pptx.ShapeType.rect, { x: 0, y: 0, w: 13.333, h: 7.5, fill: { color: C.light }, line: { color: C.light } });
  s.addShape(pptx.ShapeType.rect, { x: 0, y: 0, w: 4.8, h: 7.5, fill: { color: C.navy }, line: { color: C.navy } });
  s.addText("병렬 applylogdb\n코디네이터 설계", { x: 0.65, y: 0.9, w: 3.7, h: 1.45, fontSize: 31, bold: true, color: C.white, fit: "shrink", margin: 0 });
  s.addText("PoC 이후 실제 구현으로 넘어가기 위한 의존성 판단·분배·순서 보존 설계", { x: 0.68, y: 2.6, w: 3.55, h: 0.9, fontSize: 13.5, color: "DDE6EF", fit: "shrink", margin: 0 });
  pill(s, "CUBRID HA", 0.68, 4.35, 1.15, C.cyan);
  pill(s, "Logical replication", 1.98, 4.35, 1.65, C.green);
  pill(s, "Coordinator", 0.68, 4.82, 1.35, C.orange);
  image(s, "coordinator_d1.png", 5.25, 0.65, 7.45, 5.55);
  s.addText("Core thesis", { x: 5.28, y: 6.35, w: 1.1, h: 0.18, fontSize: 8, bold: true, color: C.cyan, margin: 0 });
  s.addText("병렬 실행과 durable commit 순서 보존을 분리하고, 마스터가 준 의존성으로 슬레이브 coordinator가 안전하게 dispatch한다.", { x: 6.18, y: 6.31, w: 6.4, h: 0.28, fontSize: 10.5, color: C.ink, fit: "shrink", margin: 0 });
  addFooter(s, "parallel_applylogdb_coordinator_design.md", 1);
}

// 2
{
  const s = pptx.addSlide();
  title(s, "01 / CURRENT STATE", "CUBRID HA는 copy와 apply가 분리되어 있고, 지연은 apply 단계에서 커진다", "병렬화 대상은 로그 수신이 아니라 슬레이브 DB에 변경을 재실행하는 applylogdb 단계다.");
  image(s, "ha_architecture.png", 0.75, 1.75, 5.0, 4.18);
  image(s, "lsa_mechanism.png", 6.15, 1.92, 5.9, 1.78);
  bulletPanel(s, 6.25, 4.15, 5.7, [
    { text: "copylogdb: 마스터 로그를 받아 로컬에 보관", color: C.blue },
    { text: "applylogdb: 복사된 로그를 읽어 슬레이브 DB에 반영", color: C.green },
    { text: "committed_lsa와 append_lsa 간격이 복제 지연(lag)", color: C.orange },
  ]);
  addFooter(s, "Background: CUBRID HA replication", 2);
}

// 3
{
  const s = pptx.addSlide();
  title(s, "02 / WHY LOGICAL MATTERS", "applylogdb는 행 재실행 기반 로지컬 복제라 병렬화 단위를 노출한다", "물리 페이지 재생이 아니라 class + PK + operation을 슬레이브 서버 경로로 다시 적용한다.");
  box(s, "PK 기반 로그\nclass + PK + operation", 0.75, 2.0, 2.8, 1.1, { fill: "EEF6FF", line: "B8D5FF", bold: true });
  box(s, "서버 FK 검사\n자식이 먼저 오면 apply 실패", 4.1, 2.0, 2.8, 1.1, { fill: "FFF3EA", line: "F4C3A6", bold: true });
  box(s, "일괄 flush\n워커별 변경을 모아 반영", 7.45, 2.0, 2.8, 1.1, { fill: "ECF8F1", line: "AEDCBF", bold: true });
  arrow(s, 3.58, 2.55, 4.02, 2.55, C.muted);
  arrow(s, 6.95, 2.55, 7.38, 2.55, C.muted);
  s.addShape(pptx.ShapeType.rect, { x: 0.75, y: 4.0, w: 11.85, h: 1.35, fill: { color: C.light }, line: { color: C.line } });
  s.addText("설계 의미", { x: 1.05, y: 4.23, w: 1.2, h: 0.22, fontSize: 10, bold: true, color: C.cyan, margin: 0 });
  s.addText("트랜잭션·행 단위 의존성을 계산할 수 있지만, FK와 unique 같은 제약은 commit 순서와 dispatch 조건이 틀리면 바로 정합성 문제가 된다.", { x: 2.05, y: 4.18, w: 9.8, h: 0.42, fontSize: 14, bold: true, color: C.ink, fit: "shrink", margin: 0 });
  s.addText("따라서 병렬 apply는 단순 워커 풀 문제가 아니라, 충돌 판단과 순서 보존을 함께 설계해야 하는 문제다.", { x: 2.05, y: 4.72, w: 9.5, h: 0.28, fontSize: 11.5, color: C.muted, fit: "shrink", margin: 0 });
  addFooter(s, "Logical replication properties", 3);
}

// 4
{
  const s = pptx.addSlide();
  title(s, "03 / POC RESULT", "PoC는 병렬화 가능성을 보였지만, 의존성 판단은 의도적으로 비워 두었다", "LogReader + worker pool 구조는 검증했고, 다음 단계는 coordinator의 dispatch 판단이다.");
  image(s, "poc_asis_develop.png", 0.8, 1.88, 2.55, 2.55);
  image(s, "poc_tobe_parallel.png", 4.05, 1.7, 7.75, 4.55);
  s.addText("AS-IS", { x: 1.43, y: 4.62, w: 1.2, h: 0.2, fontSize: 9, bold: true, color: C.muted, align: "center", margin: 0 });
  s.addText("TO-BE PoC", { x: 7.05, y: 6.3, w: 1.6, h: 0.2, fontSize: 9, bold: true, color: C.muted, align: "center", margin: 0 });
  box(s, "약 3.4x\n반영 시간 단축", 11.05, 1.05, 1.6, 0.9, { fill: C.navy, line: C.navy, color: C.white, bold: true, fontSize: 12 });
  box(s, "4~6x\nlag 감소", 11.05, 2.12, 1.6, 0.9, { fill: C.green, line: C.green, color: C.white, bold: true, fontSize: 12 });
  box(s, "한계\ntranid % worker", 11.05, 3.18, 1.6, 0.9, { fill: C.orange, line: C.orange, color: C.white, bold: true, fontSize: 11 });
  bulletPanel(s, 0.9, 5.65, 11.0, [
    { text: "PoC의 병렬성은 가능성 증명이다. 서로 의존하는 트랜잭션이 다른 워커에서 동시에 실행될 수 있다.", color: C.red },
    { text: "정식 구현은 LogReader 앞단의 enqueue 판단을 coordinator로 승격해야 한다.", color: C.blue },
  ]);
  addFooter(s, "PoC architecture and limitation", 4);
}

// 5
{
  const s = pptx.addSlide();
  title(s, "04 / PROBLEM STATEMENT", "정식 병렬화의 문제는 세 가지 게이트를 동시에 맞추는 것이다", "분배 가능성, durable commit 순서, 재시작 진도가 서로 따로 놀면 복제 정합성이 깨진다.");
  const xs = [0.9, 4.65, 8.4];
  const labels = [
    ["Dispatch gate", "이 트랜잭션을 지금 워커에 보내도 되는가?", C.blue],
    ["Commit gate", "병렬로 끝났더라도 마스터 commit 순서로 durable commit했는가?", C.green],
    ["Progress gate", "재시작 시 gap 없이 다시 읽을 수 있는 지점만 기록했는가?", C.orange],
  ];
  labels.forEach(([h, b, col], i) => {
    box(s, h, xs[i], 2.05, 3.0, 0.52, { fill: col, line: col, color: C.white, bold: true, fontSize: 13 });
    box(s, b, xs[i], 2.68, 3.0, 1.36, { fill: C.white, line: C.line, fontSize: 12 });
  });
  arrow(s, 3.95, 3.2, 4.45, 3.2, C.muted);
  arrow(s, 7.7, 3.2, 8.2, 3.2, C.muted);
  s.addText("핵심 설계 판단", { x: 0.9, y: 5.1, w: 1.5, h: 0.2, fontSize: 10, bold: true, color: C.cyan, margin: 0 });
  s.addText("병렬 실행을 허용하되, 최종 commit과 committed_lsa 전진은 마스터 순서로만 허용한다.", { x: 2.35, y: 5.02, w: 8.6, h: 0.35, fontSize: 15.5, bold: true, color: C.ink, fit: "shrink", margin: 0 });
  addFooter(s, "Design problem", 5);
}

// 6
{
  const s = pptx.addSlide();
  title(s, "05 / VENDOR LESSONS", "PostgreSQL·PGD는 참고점이고, CUBRID 모델은 MySQL 쪽에 가깝다", "CUBRID는 단방향 HA이며, 마스터가 의존성을 주고 슬레이브가 분배하는 구조가 가장 단순하다.");
  const rows = [
    ["PostgreSQL", "구독 단위 직렬 적용. 병렬은 초기 COPY·대형 tx streaming·수동 구독 분할 중심", "직접 모델로 부적합"],
    ["EDB PGD", "writer별 병렬 apply와 tuple 대기/롤백 backstop", "선례로만 참고"],
    ["MySQL", "source가 last_committed/sequence_number를 기록하고 replica coordinator가 dispatch", "채택 모델"],
  ];
  const y0 = 1.85;
  rows.forEach((r, i) => {
    const y = y0 + i * 1.18;
    const col = i === 2 ? C.green : i === 1 ? C.orange : C.blue;
    box(s, r[0], 0.75, y, 2.1, 0.68, { fill: col, line: col, color: C.white, bold: true, fontSize: 13 });
    box(s, r[1], 3.05, y, 6.9, 0.68, { fill: C.white, line: C.line, fontSize: 10.5 });
    box(s, r[2], 10.2, y, 2.25, 0.68, { fill: i === 2 ? "ECF8F1" : C.light, line: C.line, bold: i === 2, fontSize: 10.5 });
  });
  s.addText("가져올 결론", { x: 0.82, y: 5.65, w: 1.2, h: 0.18, fontSize: 9, bold: true, color: C.cyan, margin: 0 });
  s.addText("의존성 계산, 병렬 dispatch, commit 순서 보존을 서로 다른 책임으로 분리한다.", { x: 1.85, y: 5.56, w: 8.3, h: 0.32, fontSize: 15, bold: true, color: C.ink, fit: "shrink", margin: 0 });
  addFooter(s, "Replication models from other DBMS", 6);
}

// 7
{
  const s = pptx.addSlide();
  title(s, "06 / SELECTED MODEL", "MySQL식 3단 구조를 CUBRID applylogdb에 맞춰 옮긴다", "마스터는 의존성 토큰을 만들고, 슬레이브 coordinator는 그 토큰으로 워커를 열고 닫는다.");
  const y = 2.2;
  box(s, "MASTER\ncommit_seq / dependency_seq 계산", 0.75, y, 3.25, 1.2, { fill: "EEF6FF", line: "B8D5FF", bold: true });
  box(s, "COPY LOG\n복제 로그에 토큰 전달", 5.05, y, 2.65, 1.2, { fill: C.light, line: C.line, bold: true });
  box(s, "SLAVE COORDINATOR\nLOGICAL_CLOCK dispatch", 8.75, y, 3.35, 1.2, { fill: "ECF8F1", line: "AEDCBF", bold: true });
  arrow(s, 4.08, y + 0.6, 4.95, y + 0.6, C.blue);
  arrow(s, 7.78, y + 0.6, 8.65, y + 0.6, C.green);
  box(s, "❶ 의존성 계산", 0.95, 4.35, 2.75, 0.55, { fill: C.blue, line: C.blue, color: C.white, bold: true, fontSize: 12 });
  box(s, "❷ 병렬 실행", 5.18, 4.35, 2.35, 0.55, { fill: C.green, line: C.green, color: C.white, bold: true, fontSize: 12 });
  box(s, "❸ 순서 보존 commit", 8.98, 4.35, 2.9, 0.55, { fill: C.orange, line: C.orange, color: C.white, bold: true, fontSize: 12 });
  s.addText("MySQL의 sequence_number / last_committed 역할을 CUBRID에서는 commit_seq / dependency_seq로 일반화한다.", { x: 1.05, y: 5.36, w: 10.5, h: 0.34, fontSize: 14, bold: true, color: C.ink, fit: "shrink", margin: 0 });
  addFooter(s, "Adopted model", 7);
}

// 8
{
  const s = pptx.addSlide();
  title(s, "07 / TARGET ARCHITECTURE", "Coordinator는 LogReader와 ApplyWorker 사이의 분배·대기 게이트다", "PoC의 LogReader 책임 중 enqueue 판단을 독립 모듈화하고, retire/progress는 순서 보존 규칙을 유지한다.");
  image(s, "coordinator_d1.png", 0.75, 1.65, 8.05, 5.15);
  bulletPanel(s, 9.2, 1.92, 3.15, [
    { text: "LogReader: 로그를 순서대로 읽고 트랜잭션 구성", color: C.blue },
    { text: "Coordinator: dependency_seq 만족 여부로 dispatch", color: C.green },
    { text: "ApplyWorker: 독립 세션에서 apply/flush 수행", color: C.orange },
    { text: "Retire: commit 순서대로 완료 처리·진도 갱신", color: C.violet },
  ]);
  addFooter(s, "CUBRID target architecture", 8);
}

// 9
{
  const s = pptx.addSlide();
  title(s, "08 / DEPENDENCY POLICY", "1차 설계는 COMMIT_ORDER로 안전성을 먼저 확보하고, WRITESET은 확장점으로 둔다", "FK가 자동으로 안전해지고 구현 비용이 낮은 대신, 병렬도는 마스터 동시성 수준에 묶인다.");
  const y = 1.95;
  box(s, "v1 COMMIT_ORDER", 0.75, y, 5.3, 0.65, { fill: C.navy, line: C.navy, color: C.white, bold: true, fontSize: 14 });
  box(s, "마스터 commit 순서를 dependency watermark로 사용\nFK·unique·같은 행 위험을 넓게 덮는 보수적 정책", 0.75, y + 0.78, 5.3, 1.25, { fill: C.white, line: C.line, fontSize: 12 });
  box(s, "v2 WRITESET", 7.0, y, 5.3, 0.65, { fill: C.green, line: C.green, color: C.white, bold: true, fontSize: 14 });
  box(s, "(class, PK) 충돌 기준으로 dependency_seq를 더 정밀화\n동일 인터페이스 위에서 마스터 계산만 교체", 7.0, y + 0.78, 5.3, 1.25, { fill: C.white, line: C.line, fontSize: 12 });
  s.addText("공통 인터페이스", { x: 0.82, y: 4.86, w: 1.45, h: 0.2, fontSize: 9, bold: true, color: C.cyan, margin: 0 });
  s.addText("Tx(commit_seq=N, dependency_seq=M)  →  coordinator는 M 이하가 committed 되었을 때만 dispatch", { x: 2.2, y: 4.77, w: 9.1, h: 0.35, fontSize: 15, bold: true, color: C.ink, fit: "shrink", margin: 0 });
  addFooter(s, "Dependency policy: COMMIT_ORDER first, WRITESET later", 9);
}

// 10
{
  const s = pptx.addSlide();
  title(s, "09 / COORDINATOR ALGORITHM", "dispatch 조건은 단순하다: dependency_seq가 slave_committed_seq 이하이면 워커로 보낸다", "실행 완료 순서는 달라도 durable commit과 progress 전진은 commit_seq 순서를 따른다.");
  box(s, "Pending queue\nTx5 dep=3\nTx6 dep=4\nTx7 dep=4", 0.8, 1.85, 2.45, 1.55, { fill: C.light, line: C.line, bold: true, fontSize: 12 });
  box(s, "slave_committed_seq = 4", 4.3, 2.18, 2.2, 0.7, { fill: "EEF6FF", line: "B8D5FF", bold: true, fontSize: 12 });
  box(s, "Worker pool\nW1: Tx5\nW2: Tx6\nW3: Tx7", 7.5, 1.85, 2.3, 1.55, { fill: "ECF8F1", line: "AEDCBF", bold: true, fontSize: 12 });
  box(s, "Commit gate\n5 → 6 → 7", 10.55, 1.85, 1.9, 1.55, { fill: "FFF3EA", line: "F4C3A6", bold: true, fontSize: 12 });
  arrow(s, 3.35, 2.6, 4.15, 2.6, C.blue);
  arrow(s, 6.62, 2.6, 7.35, 2.6, C.green);
  arrow(s, 9.9, 2.6, 10.42, 2.6, C.orange);
  s.addShape(pptx.ShapeType.rect, { x: 0.8, y: 4.75, w: 11.65, h: 0.82, fill: { color: C.navy }, line: { color: C.navy } });
  s.addText("if (tx.dependency_seq <= slave_committed_seq) dispatch(tx); else wait(tx);", { x: 1.1, y: 5.02, w: 11.0, h: 0.18, fontFace: "Courier New", fontSize: 14, color: C.white, fit: "shrink", margin: 0 });
  addFooter(s, "Coordinator dispatch rule", 10);
}

// 11
{
  const s = pptx.addSlide();
  title(s, "10 / CORRECTNESS", "정확성은 dispatch gate와 commit gate를 분리할 때 설명 가능해진다", "dispatch는 '실행해도 되는가', commit gate는 '외부에 보이는 순서를 지켰는가'를 담당한다.");
  const cases = [
    ["FK", "부모보다 자식이 먼저 apply되면 서버 FK 검사에서 실패한다", "COMMIT_ORDER는 부모 commit 이후 자식 dispatch를 보장"],
    ["Same row / unique", "같은 PK·unique key 충돌은 순서가 바뀌면 결과가 달라질 수 있다", "commit_seq 순서로 durable commit"],
    ["Restart", "중간 tx만 먼저 기록하면 재시작 시 gap이 생긴다", "committed_lsa는 gap-free 지점만 전진"],
  ];
  cases.forEach((c, i) => {
    const y = 1.72 + i * 1.24;
    box(s, c[0], 0.75, y, 1.55, 0.72, { fill: i === 0 ? C.orange : i === 1 ? C.red : C.blue, line: i === 0 ? C.orange : i === 1 ? C.red : C.blue, color: C.white, bold: true, fontSize: 13 });
    box(s, c[1], 2.55, y, 4.8, 0.72, { fill: C.white, line: C.line, fontSize: 10.5 });
    box(s, c[2], 7.65, y, 4.7, 0.72, { fill: C.light, line: C.line, bold: true, fontSize: 10.5 });
  });
  addFooter(s, "Correctness scenarios", 11);
}

// 12
{
  const s = pptx.addSlide();
  title(s, "11 / RESTART MODEL", "재시작 기준은 기존 gap-free progress 모델을 유지한다", "병렬 완료 결과가 있어도, 순서대로 durable commit된 지점만 db_ha_apply_info에 기록한다.");
  box(s, "required_lsa", 0.9, 2.05, 2.1, 0.58, { fill: C.light, line: C.line, bold: true });
  box(s, "committed_lsa", 3.55, 2.05, 2.1, 0.58, { fill: "ECF8F1", line: "AEDCBF", bold: true });
  box(s, "final_lsa", 6.2, 2.05, 2.1, 0.58, { fill: "EEF6FF", line: "B8D5FF", bold: true });
  box(s, "append_lsa", 8.85, 2.05, 2.1, 0.58, { fill: "FFF3EA", line: "F4C3A6", bold: true });
  arrow(s, 3.05, 2.34, 3.47, 2.34, C.muted);
  arrow(s, 5.7, 2.34, 6.12, 2.34, C.muted);
  arrow(s, 8.35, 2.34, 8.77, 2.34, C.muted);
  s.addText("정상 불변식: required_lsa <= committed_lsa <= final_lsa <= append_lsa", { x: 0.95, y: 3.25, w: 10.2, h: 0.35, fontFace: "Courier New", fontSize: 13.5, bold: true, color: C.ink, fit: "shrink", margin: 0 });
  bulletPanel(s, 0.98, 4.35, 10.8, [
    { text: "재시작은 committed_lsa 이후를 다시 읽는 보수적 모델을 따른다.", color: C.blue },
    { text: "out-of-order 완료는 retire 단계에서 대기하고, gap-free commit_seq가 이어질 때만 진도 전진.", color: C.green },
    { text: "develop에도 있던 crash window는 별도 내구성 문제로 분리해 다룬다.", color: C.orange },
  ]);
  addFooter(s, "Restart and progress invariants", 12);
}

// 13
{
  const s = pptx.addSlide();
  title(s, "12 / IMPLEMENTATION ROADMAP", "1차 구현은 안전한 COMMIT_ORDER coordinator, 이후 WRITESET으로 병렬도를 넓힌다", "설계의 핵심은 인터페이스를 먼저 고정해 v2 확장을 갈아끼울 수 있게 만드는 것이다.");
  const steps = [
    ["1", "마스터 로그에 commit_seq / dependency_seq 추가", C.blue],
    ["2", "슬레이브 Coordinator pending/ready 큐와 dispatch 조건 구현", C.green],
    ["3", "commit gate와 retire/progress 갱신을 commit_seq 순서로 강제", C.orange],
    ["4", "FK·same row·unique·crash restart 시나리오 검증", C.red],
    ["5", "WRITESET 계산으로 행 단위 병렬성 확장", C.violet],
  ];
  steps.forEach((st, i) => {
    const x = 0.85 + i * 2.35;
    s.addShape(pptx.ShapeType.ellipse, { x, y: 2.03, w: 0.56, h: 0.56, fill: { color: st[2] }, line: { color: st[2] } });
    s.addText(st[0], { x, y: 2.19, w: 0.56, h: 0.14, fontSize: 11, bold: true, color: C.white, align: "center", margin: 0 });
    if (i < steps.length - 1) arrow(s, x + 0.7, 2.31, x + 2.1, 2.31, C.muted);
    box(s, st[1], x - 0.12, 3.0, 1.75, 1.0, { fill: C.white, line: C.line, fontSize: 10.5 });
  });
  s.addShape(pptx.ShapeType.rect, { x: 0.85, y: 5.35, w: 11.6, h: 0.78, fill: { color: C.navy }, line: { color: C.navy } });
  s.addText("결론: 병렬 applylogdb의 핵심은 워커 수가 아니라, 의존성 토큰과 gap-free commit/progress 계약이다.", { x: 1.15, y: 5.58, w: 11.0, h: 0.2, fontSize: 14.5, bold: true, color: C.white, fit: "shrink", margin: 0 });
  addFooter(s, "Conclusion and next steps", 13);
}

pptx.writeFile({ fileName: OUT });
