const pptxgen = require("pptxgenjs");
const path = require("path");

const pptx = new pptxgen();
pptx.defineLayout({ name: "WIDE", width: 13.333, height: 7.5 });
pptx.layout = "WIDE";
pptx.author = "Codex";
pptx.subject = "Parallel applylogdb coordinator design TOC";
pptx.title = "병렬 applylogdb 코디네이터 설계 v2";
pptx.lang = "ko-KR";
pptx.theme = {
  headFontFace: "Arial",
  bodyFontFace: "Arial",
  lang: "ko-KR",
};

const ROOT = path.resolve(__dirname, "../../../..");
const OUT = path.join(ROOT, "parallel-applylogdb-coordinator-design-v2.pptx");

const C = {
  ink: "17202A",
  muted: "667085",
  light: "F5F7FA",
  line: "D7DCE3",
  navy: "102A43",
  blue: "2457A6",
  teal: "00A7B5",
  green: "2F8F5B",
  orange: "D96C2C",
  white: "FFFFFF",
};

function box(slide, text, x, y, w, h, opts = {}) {
  const fill = opts.fill || C.white;
  const line = opts.line || C.line;
  slide.addShape(pptx.ShapeType.roundRect, {
    x,
    y,
    w,
    h,
    rectRadius: 0.05,
    fill: { color: fill },
    line: { color: line, width: opts.lineWidth || 1 },
  });
  slide.addText(text, {
    x: x + (opts.padX || 0.11),
    y: y + (opts.padY || 0.08),
    w: w - 2 * (opts.padX || 0.11),
    h: h - 2 * (opts.padY || 0.08),
    fontSize: opts.fontSize || 10,
    bold: !!opts.bold,
    color: opts.color || C.ink,
    align: opts.align || "center",
    valign: "mid",
    margin: 0,
    fit: "shrink",
  });
}

function arrow(slide, x1, y1, x2, y2, color = C.muted, width = 1.2) {
  slide.addShape(pptx.ShapeType.line, {
    x: x1,
    y: y1,
    w: x2 - x1,
    h: y2 - y1,
    line: { color, width, endArrowType: "triangle" },
  });
}

function smallLabel(slide, text, x, y, w, color = C.muted) {
  slide.addText(text, {
    x,
    y,
    w,
    h: 0.14,
    fontSize: 7.5,
    color,
    align: "center",
    margin: 0,
    fit: "shrink",
  });
}

function lsaCell(slide, text, x, y, w, h, opts = {}) {
  slide.addShape(pptx.ShapeType.rect, {
    x,
    y,
    w,
    h,
    fill: { color: opts.fill || C.white },
    line: { color: opts.line || C.line, width: opts.lineWidth || 0.7 },
  });
  slide.addText(text, {
    x: x + 0.04,
    y: y + 0.06,
    w: w - 0.08,
    h: h - 0.1,
    fontSize: opts.fontSize || 7.7,
    bold: !!opts.bold,
    color: opts.color || C.ink,
    align: "center",
    valign: "mid",
    margin: 0,
    fit: "shrink",
  });
}

function lsaGrid(slide, x, y, opts = {}) {
  const cw = 0.92;
  const ch = 0.48;
  const pages = ["page 120", "page 121", "page 122"];
  const offsets = ["000", "120", "240", "360", "480"];
  const data = [
    ["BEGIN T7", "INSERT A:1", "UPDATE B:4", "", ""],
    ["INSERT A:2", "DELETE C:7", "COMMIT T7", "BEGIN T8", "UPDATE D:2"],
    ["INSERT D:3", "COMMIT T8", "", "", ""],
  ];

  lsaCell(slide, "pageid / offset", x, y, 1.18, ch, { fill: "EEF3F8", bold: true, fontSize: 7.1 });
  offsets.forEach((o, i) => lsaCell(slide, o, x + 1.18 + i * cw, y, cw, ch, { fill: "EEF3F8", bold: true }));
  pages.forEach((p, r) => {
    lsaCell(slide, p, x, y + ch + r * ch, 1.18, ch, { fill: "EEF3F8", bold: true, fontSize: 7.5 });
    offsets.forEach((_, c) => {
      const label = data[r][c];
      const isCommit = label.startsWith("COMMIT");
      const isBegin = label.startsWith("BEGIN");
      lsaCell(slide, label, x + 1.18 + c * cw, y + ch + r * ch, cw, ch, {
        fill: isCommit ? "FFF3EA" : isBegin ? "F4F7FA" : label ? "FFFFFF" : "FAFBFC",
        line: isCommit ? "E7A94F" : C.line,
        bold: isCommit,
        fontSize: label.length > 9 ? 6.5 : 7.3,
      });
    });
  });
  if (opts.final) {
    const [r, c, text] = opts.final;
    const cx = x + 1.18 + c * cw + cw / 2;
    const cy = y + ch + r * ch;
    arrow(slide, cx, cy - 0.52, cx, cy - 0.05, C.blue, 1.6);
    box(slide, text || "final_lsa", cx - 0.45, cy - 0.88, 0.9, 0.26, { fill: C.blue, line: C.blue, color: C.white, bold: true, fontSize: 7.5 });
  }
  if (opts.committed) {
    const [r, c, text] = opts.committed;
    const cx = x + 1.18 + c * cw + cw / 2;
    const cy = y + ch + r * ch + ch;
    arrow(slide, cx, cy + 0.55, cx, cy + 0.08, C.green, 1.6);
    box(slide, text || "committed_lsa", cx - 0.55, cy + 0.63, 1.1, 0.26, { fill: C.green, line: C.green, color: C.white, bold: true, fontSize: 7.2 });
  }
}

function miniStep(slide, num, text, x, y, active = false) {
  const color = active ? C.teal : "A9B7C7";
  slide.addShape(pptx.ShapeType.ellipse, {
    x,
    y,
    w: 0.32,
    h: 0.32,
    fill: { color },
    line: { color },
  });
  slide.addText(String(num), {
    x,
    y: y + 0.092,
    w: 0.32,
    h: 0.08,
    fontSize: 7.5,
    bold: true,
    color: C.white,
    align: "center",
    margin: 0,
  });
  slide.addText(text, {
    x: x + 0.42,
    y: y + 0.03,
    w: 2.25,
    h: 0.15,
    fontSize: 8.5,
    bold: active,
    color: active ? C.ink : C.muted,
    margin: 0,
    fit: "shrink",
  });
}

function footer(slide, n) {
  slide.addShape(pptx.ShapeType.line, {
    x: 0.55,
    y: 7.08,
    w: 12.2,
    h: 0,
    line: { color: C.line, width: 0.8 },
  });
  slide.addText("parallel_applylogdb_coordinator_design.md", {
    x: 0.55,
    y: 7.18,
    w: 4.5,
    h: 0.15,
    fontSize: 7.5,
    color: C.muted,
    margin: 0,
  });
  slide.addText(String(n).padStart(2, "0"), {
    x: 12.35,
    y: 7.16,
    w: 0.42,
    h: 0.16,
    fontSize: 8,
    bold: true,
    color: C.muted,
    align: "right",
    margin: 0,
  });
}

function title(slide, eyebrow, main, sub) {
  slide.addText(eyebrow, {
    x: 0.65,
    y: 0.42,
    w: 5.3,
    h: 0.18,
    fontSize: 8.5,
    bold: true,
    color: C.teal,
    margin: 0,
  });
  slide.addText(main, {
    x: 0.62,
    y: 0.82,
    w: 10.5,
    h: 0.52,
    fontSize: 25,
    bold: true,
    color: C.ink,
    margin: 0,
    fit: "shrink",
  });
  if (sub) {
    slide.addText(sub, {
      x: 0.65,
      y: 1.45,
      w: 10.8,
      h: 0.24,
      fontSize: 10.8,
      color: C.muted,
      margin: 0,
      fit: "shrink",
    });
  }
}

function tocItem(slide, index, heading, desc, x, y, color) {
  slide.addShape(pptx.ShapeType.roundRect, {
    x,
    y,
    w: 0.46,
    h: 0.46,
    rectRadius: 0.05,
    fill: { color },
    line: { color },
  });
  slide.addText(String(index).padStart(2, "0"), {
    x,
    y: y + 0.145,
    w: 0.46,
    h: 0.1,
    fontSize: 8.8,
    bold: true,
    color: C.white,
    align: "center",
    margin: 0,
  });
  slide.addText(heading, {
    x: x + 0.62,
    y: y - 0.01,
    w: 4.55,
    h: 0.2,
    fontSize: 13.3,
    bold: true,
    color: C.ink,
    margin: 0,
    fit: "shrink",
  });
  slide.addText(desc, {
    x: x + 0.62,
    y: y + 0.26,
    w: 4.65,
    h: 0.22,
    fontSize: 9.2,
    color: C.muted,
    margin: 0,
    fit: "shrink",
  });
}

// Slide 1: cover
{
  const s = pptx.addSlide();
  s.background = { color: C.light };
  s.addShape(pptx.ShapeType.rect, {
    x: 0,
    y: 0,
    w: 13.333,
    h: 7.5,
    fill: { color: C.light },
    line: { color: C.light },
  });
  s.addShape(pptx.ShapeType.rect, {
    x: 0,
    y: 0,
    w: 3.15,
    h: 7.5,
    fill: { color: C.navy },
    line: { color: C.navy },
  });
  s.addText("병렬\napplylogdb\n코디네이터\n설계", {
    x: 0.55,
    y: 0.78,
    w: 2.25,
    h: 2.1,
    fontSize: 25,
    bold: true,
    color: C.white,
    breakLine: false,
    margin: 0,
    fit: "shrink",
  });
  s.addText("Version 2 / 목차 초안", {
    x: 0.58,
    y: 4.72,
    w: 1.95,
    h: 0.22,
    fontSize: 10.5,
    bold: true,
    color: "D7E2EE",
    margin: 0,
  });
  s.addText("PoC 이후 실제 구현으로 넘어가기 위한 의존성 판단, 분배, 순서 보존 설계", {
    x: 4.15,
    y: 1.02,
    w: 7.4,
    h: 0.64,
    fontSize: 23,
    bold: true,
    color: C.ink,
    margin: 0,
    fit: "shrink",
  });
  s.addText("오늘은 목차까지만 잡고, 이후 슬라이드는 필요한 지점마다 추가·교체한다.", {
    x: 4.18,
    y: 1.95,
    w: 6.7,
    h: 0.25,
    fontSize: 11.5,
    color: C.muted,
    margin: 0,
  });
  s.addShape(pptx.ShapeType.line, {
    x: 4.18,
    y: 2.62,
    w: 7.4,
    h: 0,
    line: { color: C.line, width: 1 },
  });
  s.addText("핵심 흐름", {
    x: 4.18,
    y: 3.12,
    w: 1.2,
    h: 0.2,
    fontSize: 10,
    bold: true,
    color: C.teal,
    margin: 0,
  });
  s.addText("현재 구조 → PoC 결과 → 타 DBMS 비교 → CUBRID coordinator 설계 → 정확성·재시작 → 구현 계획", {
    x: 4.18,
    y: 3.52,
    w: 7.7,
    h: 0.55,
    fontSize: 16,
    bold: true,
    color: C.ink,
    margin: 0,
    fit: "shrink",
  });
  footer(s, 1);
}

// Slide 2: TOC
{
  const s = pptx.addSlide();
  title(s, "TABLE OF CONTENTS", "목차", "발표 흐름은 문제 정의에서 시작해, PoC의 한계를 coordinator 설계로 닫는 구조다.");
  const items = [
    ["CUBRID HA 복제 현황", "copylogdb / applylogdb / LSA / lag"],
    ["applylogdb의 로지컬 복제 특성", "PK 기반 변경 재실행과 FK 검사"],
    ["병렬화 필요성과 PoC 결과", "성능 개선, 단순 분배 방식의 한계"],
    ["정식 병렬화의 핵심 과제", "충돌 판단, commit 순서, 재시작 정합성"],
    ["타 DBMS 사례 비교", "PostgreSQL, EDB PGD, MySQL"],
    ["채택 모델: MySQL식 Coordinator", "의존성 계산, 병렬 dispatch, commit gate"],
    ["CUBRID Coordinator 설계", "LogReader, Coordinator, ApplyWorker, Retire"],
    ["의존성 정책", "v1 COMMIT_ORDER, v2 WRITESET 확장"],
    ["정확성 시나리오", "FK, 같은 행, unique, dispatch/commit 분리"],
    ["재시작과 구현 계획", "gap-free progress, 불변식, 검증 항목"],
  ];
  const colors = [C.blue, C.teal, C.green, C.orange, C.blue, C.green, C.teal, C.orange, C.blue, C.navy];
  items.forEach((it, i) => {
    const col = i < 5 ? 0.78 : 7.02;
    const row = i % 5;
    tocItem(s, i + 1, it[0], it[1], col, 2.05 + row * 0.86, colors[i]);
  });
  footer(s, 2);
}

// Slide 3: CUBRID HA replication status
{
  const s = pptx.addSlide();
  title(s, "01 / CURRENT STATE", "Cubrid ha 복제 현황", "cubrid ha 구조도");

  // Containers
  s.addShape(pptx.ShapeType.roundRect, {
    x: 0.62,
    y: 1.72,
    w: 12.1,
    h: 1.55,
    rectRadius: 0.06,
    fill: { color: "EEF3F8" },
    line: { color: "BFD0E1", width: 1 },
  });
  s.addText("MASTER node", {
    x: 0.88,
    y: 1.92,
    w: 1.55,
    h: 0.16,
    fontSize: 8.5,
    bold: true,
    color: "526477",
    margin: 0,
  });
  s.addShape(pptx.ShapeType.roundRect, {
    x: 0.62,
    y: 3.55,
    w: 12.1,
    h: 3.18,
    rectRadius: 0.06,
    fill: { color: "EEF8F1" },
    line: { color: "A9D5B7", width: 1 },
  });
  s.addText("SLAVE node", {
    x: 0.88,
    y: 3.75,
    w: 1.35,
    h: 0.16,
    fontSize: 8.5,
    bold: true,
    color: "577461",
    margin: 0,
  });

  // Clients -> cub_server
  box(s, "Client 1", 1.0, 2.22, 0.9, 0.36, { fill: C.white, line: "A9B7C7", fontSize: 8.5 });
  box(s, "Client 2", 1.0, 2.66, 0.9, 0.36, { fill: C.white, line: "A9B7C7", fontSize: 8.5 });
  box(s, "Client 3", 1.0, 3.10, 0.9, 0.36, { fill: C.white, line: "A9B7C7", fontSize: 8.5 });
  box(s, "cub_server", 2.72, 2.45, 1.55, 0.58, { fill: C.white, line: "5F8FC9", bold: true, fontSize: 11 });
  arrow(s, 1.92, 2.40, 2.64, 2.62, C.blue, 1);
  arrow(s, 1.92, 2.84, 2.64, 2.74, C.blue, 1);
  arrow(s, 1.92, 3.28, 2.64, 2.88, C.blue, 1);
  smallLabel(s, "Request", 2.0, 2.2, 0.65, C.blue);

  box(s, "Tx log", 5.03, 2.45, 1.42, 0.58, { fill: "FFF7E8", line: "E7A94F", bold: true, fontSize: 11 });
  arrow(s, 4.34, 2.74, 4.95, 2.74, C.muted, 1.3);
  smallLabel(s, "write", 4.42, 2.5, 0.42);

  // Copy flow
  box(s, "copylogdb", 8.35, 3.92, 1.55, 0.5, { fill: C.white, line: "5F8FC9", bold: true, fontSize: 10 });
  arrow(s, 6.46, 2.74, 9.12, 3.88, C.muted, 1.2);
  smallLabel(s, "fetch repl log over network", 6.55, 3.07, 2.1);
  box(s, "Copied repl log\nha_copy_log_base", 8.18, 4.62, 1.9, 0.62, { fill: "FFF7E8", line: "E7A94F", fontSize: 9.2 });
  arrow(s, 9.12, 4.43, 9.12, 4.58, C.muted, 1.1);
  smallLabel(s, "store", 9.28, 4.45, 0.35);

  // applylogdb module with internal AS-IS details
  box(s, "applylogdb\nsingle process · serial", 5.52, 4.17, 2.35, 0.62, {
    fill: "FFFFFF",
    line: "D94444",
    lineWidth: 1.2,
    bold: true,
    fontSize: 10.3,
  });
  box(s, "read active/archive log", 5.75, 4.92, 1.88, 0.26, { fill: "F7FAFC", line: "DCE3EA", fontSize: 7.6 });
  box(s, "decode → LA_ITEM / LA_APPLY", 5.75, 5.24, 1.88, 0.26, { fill: "F7FAFC", line: "DCE3EA", fontSize: 7.6 });
  box(s, "la_apply_insert/update/delete", 5.75, 5.56, 1.88, 0.26, { fill: "F7FAFC", line: "DCE3EA", fontSize: 7.2 });
  box(s, "locator_repl_flush_all", 5.75, 5.88, 1.88, 0.26, { fill: "F7FAFC", line: "DCE3EA", fontSize: 7.4 });
  box(s, "commit + update apply_info", 5.75, 6.20, 1.88, 0.26, { fill: "F7FAFC", line: "DCE3EA", fontSize: 7.4 });
  arrow(s, 8.15, 4.93, 7.92, 4.76, C.muted, 1.1);
  smallLabel(s, "logical re-apply", 7.86, 4.63, 0.9);

  // Slave DB and apply info, similar sizing with apply info smaller
  box(s, "Slave DB\ncub_server", 2.35, 5.06, 2.05, 0.62, { fill: C.white, line: "5F8FC9", fontSize: 10.2 });
  box(s, "db_ha_apply_info\nfinal_lsa / required_lsa / committed_lsa", 2.42, 6.02, 1.9, 0.48, {
    fill: "FFF7E8",
    line: "E7A94F",
    fontSize: 7.6,
  });
  arrow(s, 5.48, 5.36, 4.48, 5.36, C.muted, 1.2);
  smallLabel(s, "apply", 4.62, 5.14, 0.42);
  arrow(s, 5.48, 6.18, 4.39, 6.25, C.muted, 1.1);
  smallLabel(s, "save progress", 4.46, 5.96, 0.78);
  smallLabel(s, "re-execution → slave's own log (LSA ≠ master)", 2.25, 5.75, 2.45, C.orange);

  // Current target note
  box(s, "병렬화 대상\napplylogdb의 apply 단계", 10.55, 5.0, 1.55, 0.86, {
    fill: C.navy,
    line: C.navy,
    color: C.white,
    bold: true,
    fontSize: 10.5,
  });
  arrow(s, 10.45, 5.42, 7.9, 5.42, C.navy, 1.2);

  footer(s, 3);
}

// Slide 4: LSA scan frame 1
{
  const s = pptx.addSlide();
  title(s, "02 / LSA SCAN", "LSA를 따라 복제 로그를 읽기 시작한다", "LSA는 pageid + offset 좌표이며, final_lsa는 마지막으로 읽어 처리한 위치를 가리킨다.");
  lsaGrid(s, 0.85, 2.25, {
    final: [0, 0, "final_lsa"],
    committed: [0, 0, "committed_lsa"],
  });
  box(s, "읽기 전 상태", 7.25, 2.18, 4.7, 0.48, { fill: C.navy, line: C.navy, color: C.white, bold: true, fontSize: 13 });
  box(s, "applylogdb는 active/archive log를 LSA 순서대로 읽는다.\n아직 새 트랜잭션을 끝까지 적용하지 않았으므로 committed_lsa는 이전 commit 위치에 머문다.", 7.25, 2.88, 4.7, 1.05, {
    fill: C.white,
    line: C.line,
    fontSize: 11.3,
    align: "left",
  });
  miniStep(s, 1, "cursor 위치 확인", 7.32, 4.55, true);
  miniStep(s, 2, "repl item 수집", 7.32, 5.0, false);
  miniStep(s, 3, "commit record 확인", 7.32, 5.45, false);
  miniStep(s, 4, "committed_lsa 전진", 7.32, 5.9, false);
  footer(s, 4);
}

// Slide 5: LSA scan frame 2
{
  const s = pptx.addSlide();
  title(s, "02 / LSA SCAN", "final_lsa가 전진하며 변경 로그를 LA_ITEM으로 모은다", "commit 전까지는 트랜잭션 내부 변경을 리스트에 쌓고, committed_lsa는 아직 움직이지 않는다.");
  lsaGrid(s, 0.85, 2.25, {
    final: [1, 1, "final_lsa"],
    committed: [0, 0, "committed_lsa"],
  });
  box(s, "LA_ITEM list", 7.15, 2.0, 4.85, 0.42, { fill: C.blue, line: C.blue, color: C.white, bold: true, fontSize: 12.5 });
  box(s, "T7\nBEGIN", 7.2, 2.68, 0.92, 0.52, { fill: "F4F7FA", line: C.line, fontSize: 8.8, bold: true });
  box(s, "A:1\nINSERT", 8.35, 2.68, 0.92, 0.52, { fill: C.white, line: C.line, fontSize: 8.8 });
  box(s, "B:4\nUPDATE", 9.5, 2.68, 0.92, 0.52, { fill: C.white, line: C.line, fontSize: 8.8 });
  box(s, "C:7\nDELETE", 10.65, 2.68, 0.92, 0.52, { fill: C.white, line: C.line, fontSize: 8.8 });
  arrow(s, 8.12, 2.94, 8.32, 2.94, C.muted, 1);
  arrow(s, 9.27, 2.94, 9.47, 2.94, C.muted, 1);
  arrow(s, 10.42, 2.94, 10.62, 2.94, C.muted, 1);
  box(s, "decode → build LA_ITEM", 7.2, 3.75, 4.75, 0.58, { fill: "EEF3F8", line: "BFD0E1", bold: true, fontSize: 12 });
  miniStep(s, 1, "cursor 위치 확인", 7.32, 4.85, false);
  miniStep(s, 2, "repl item 수집", 7.32, 5.3, true);
  miniStep(s, 3, "commit record 확인", 7.32, 5.75, false);
  miniStep(s, 4, "committed_lsa 전진", 7.32, 6.2, false);
  footer(s, 5);
}

// Slide 6: LSA scan frame 3
{
  const s = pptx.addSlide();
  title(s, "02 / LSA SCAN", "COMMIT record를 만나면 트랜잭션 단위 LA_APPLY가 확정된다", "LogReader는 commit 로그 위치를 기준으로 트랜잭션을 닫고, apply 대상 묶음을 만든다.");
  lsaGrid(s, 0.85, 2.25, {
    final: [1, 2, "final_lsa"],
    committed: [0, 0, "committed_lsa"],
  });
  box(s, "LA_APPLY", 7.15, 1.95, 4.85, 0.42, { fill: C.teal, line: C.teal, color: C.white, bold: true, fontSize: 12.5 });
  box(s, "tranid: T7\nstart_lsa: page120:000\ncommit_lsa: page121:240", 7.25, 2.62, 2.15, 1.0, {
    fill: C.white,
    line: C.line,
    fontSize: 9.5,
    align: "left",
  });
  box(s, "items\nA:1 INSERT\nB:4 UPDATE\nC:7 DELETE", 9.75, 2.62, 2.05, 1.0, {
    fill: C.white,
    line: C.line,
    fontSize: 9.5,
    align: "left",
  });
  arrow(s, 9.42, 3.12, 9.68, 3.12, C.muted, 1);
  box(s, "commit record LSA는 이 트랜잭션의 완료 기준점이다.\n단, committed_lsa는 실제 apply/commit 완료 전까지 전진하지 않는다.", 7.2, 4.1, 4.75, 0.76, {
    fill: "FFF7E8",
    line: "E7A94F",
    fontSize: 10.8,
    align: "left",
  });
  miniStep(s, 1, "cursor 위치 확인", 7.32, 5.28, false);
  miniStep(s, 2, "repl item 수집", 7.32, 5.68, false);
  miniStep(s, 3, "commit record 확인", 7.32, 6.08, true);
  miniStep(s, 4, "committed_lsa 전진", 7.32, 6.48, false);
  footer(s, 6);
}

// Slide 7: LSA scan frame 4
{
  const s = pptx.addSlide();
  title(s, "02 / LSA SCAN", "적용이 끝난 뒤에만 committed_lsa가 commit record 위치로 전진한다", "final_lsa는 읽기 커서이고, committed_lsa는 gap 없이 반영 완료된 진도선이다.");
  lsaGrid(s, 0.85, 2.25, {
    final: [1, 3, "final_lsa"],
    committed: [1, 2, "committed_lsa"],
  });
  box(s, "Apply / flush / commit 완료", 7.15, 2.04, 4.85, 0.48, { fill: C.green, line: C.green, color: C.white, bold: true, fontSize: 12.5 });
  box(s, "worker 또는 단일 apply 경로가 LA_APPLY를 슬레이브 DB에 반영한다.\n완료 결과가 commit 순서에 맞게 retire되면 db_ha_apply_info가 갱신된다.", 7.2, 2.85, 4.75, 0.98, {
    fill: C.white,
    line: C.line,
    fontSize: 11,
    align: "left",
  });
  box(s, "정상 진도선\nrequired_lsa <= committed_lsa <= final_lsa <= append_lsa", 7.2, 4.35, 4.75, 0.56, {
    fill: C.navy,
    line: C.navy,
    color: C.white,
    bold: true,
    fontSize: 10.2,
  });
  miniStep(s, 1, "cursor 위치 확인", 7.32, 5.38, false);
  miniStep(s, 2, "repl item 수집", 7.32, 5.78, false);
  miniStep(s, 3, "commit record 확인", 7.32, 6.18, false);
  miniStep(s, 4, "committed_lsa 전진", 7.32, 6.58, true);
  footer(s, 7);
}

pptx.writeFile({ fileName: OUT });
