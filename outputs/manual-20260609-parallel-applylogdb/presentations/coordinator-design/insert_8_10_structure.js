const fs = require("fs");
const path = require("path");
const JSZip = require("jszip");
const pptxgen = require("pptxgenjs");

const ROOT = path.resolve(__dirname, "../../../..");
const SRC = path.join(ROOT, "parallel-applylogdb-coordinator-design-v2.pptx");
const KOREAN_SRC = path.join(ROOT, "병렬_applylogdb_코디네이터_설계.pptx");
const TMP = path.join(__dirname, "qa", "slides-8-10-temp.pptx");
const OUT = path.join(ROOT, "parallel-applylogdb-coordinator-design-v2-inserted.pptx");
const KOREAN_OUT = path.join(ROOT, "병렬_applylogdb_코디네이터_설계_8-10수정.pptx");

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
  red: "B74343",
  white: "FFFFFF",
};

function makeDeck() {
  fs.mkdirSync(path.dirname(TMP), { recursive: true });

  const pptx = new pptxgen();
  pptx.defineLayout({ name: "WIDE", width: 13.333, height: 7.5 });
  pptx.layout = "WIDE";
  pptx.author = "Codex";
  pptx.subject = "Slides 8-10 insertion";
  pptx.title = "병렬 applylogdb 코디네이터 설계 추가 슬라이드";
  pptx.lang = "ko-KR";
  pptx.theme = {
    headFontFace: "Arial",
    bodyFontFace: "Arial",
    lang: "ko-KR",
  };

  function text(slide, body, x, y, w, h, opts = {}) {
    slide.addText(body, {
      x,
      y,
      w,
      h,
      fontFace: opts.fontFace || "Arial",
      fontSize: opts.fontSize || 10,
      bold: !!opts.bold,
      color: opts.color || C.ink,
      align: opts.align || "left",
      valign: opts.valign || "mid",
      margin: opts.margin === undefined ? 0 : opts.margin,
      fit: "shrink",
      breakLine: false,
    });
  }

  function box(slide, body, x, y, w, h, opts = {}) {
    slide.addShape(pptx.ShapeType.roundRect, {
      x,
      y,
      w,
      h,
      rectRadius: 0.05,
      fill: { color: opts.fill || C.white },
      line: { color: opts.line || C.line, width: opts.lineWidth || 1 },
    });
    text(slide, body, x + (opts.padX || 0.12), y + (opts.padY || 0.08), w - 2 * (opts.padX || 0.12), h - 2 * (opts.padY || 0.08), {
      fontSize: opts.fontSize || 10,
      bold: opts.bold,
      color: opts.color || C.ink,
      align: opts.align || "center",
      valign: "mid",
    });
  }

  function arrow(slide, x1, y1, x2, y2, color = C.muted, width = 1.2, dashed = false) {
    slide.addShape(pptx.ShapeType.line, {
      x: x1,
      y: y1,
      w: x2 - x1,
      h: y2 - y1,
      line: {
        color,
        width,
        beginArrowType: "none",
        endArrowType: "triangle",
        dash: dashed ? "dash" : "solid",
      },
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
    text(slide, "parallel_applylogdb_coordinator_design.md", 0.55, 7.18, 4.5, 0.15, {
      fontSize: 7.5,
      color: C.muted,
    });
    text(slide, String(n).padStart(2, "0"), 12.35, 7.16, 0.42, 0.16, {
      fontSize: 8,
      bold: true,
      color: C.muted,
      align: "right",
    });
  }

  function title(slide, eyebrow, main, sub) {
    text(slide, eyebrow, 0.65, 0.42, 5.3, 0.18, {
      fontSize: 8.5,
      bold: true,
      color: C.teal,
    });
    text(slide, main, 0.62, 0.82, 10.5, 0.52, {
      fontSize: 25,
      bold: true,
      color: C.ink,
    });
    text(slide, sub, 0.65, 1.45, 10.8, 0.24, {
      fontSize: 10.8,
      color: C.muted,
    });
  }

  function addBlankSlide() {
    const s = pptx.addSlide();
    s.background = { color: C.white };
  }

  addBlankSlide();

  {
    const s = pptx.addSlide();
    s.background = { color: C.white };
    title(
      s,
      "09 / TARGET STRUCTURE",
      "Coordinator는 의존성 토큰으로 분배하고, commit gate로 순서를 보존한다",
      "설계문서 D.1/D.4/D.5/D.6 기준: 계산은 Master, 집행은 Slave Coordinator, durable commit은 commit_seq 순서."
    );

    s.addShape(pptx.ShapeType.roundRect, {
      x: 0.62,
      y: 1.82,
      w: 12.1,
      h: 1.45,
      rectRadius: 0.06,
      fill: { color: "EEF3F8" },
      line: { color: "BFD0E1", width: 1 },
    });
    text(s, "MASTER", 0.9, 2.02, 1.0, 0.14, { fontSize: 8.5, bold: true, color: "526477" });

    box(s, "cub_server\ncommit 처리", 1.0, 2.34, 1.55, 0.58, {
      fill: C.white,
      line: "5F8FC9",
      bold: true,
      fontSize: 10,
    });
    box(s, "dependency\ncalculator", 3.25, 2.22, 1.68, 0.82, {
      fill: "FFF7E8",
      line: "E7A94F",
      bold: true,
      fontSize: 10,
    });
    box(s, "commit_seq\n+\ndependency_seq", 5.78, 2.22, 1.75, 0.82, {
      fill: C.navy,
      line: C.navy,
      color: C.white,
      bold: true,
      fontSize: 10,
    });
    box(s, "copylogdb\ncopied repl log", 9.18, 2.28, 1.88, 0.68, {
      fill: C.white,
      line: "5F8FC9",
      bold: true,
      fontSize: 10,
    });
    arrow(s, 2.62, 2.63, 3.14, 2.63, C.blue, 1.2);
    arrow(s, 4.99, 2.63, 5.66, 2.63, C.orange, 1.2);
    arrow(s, 7.62, 2.63, 9.06, 2.63, C.muted, 1.2);
    text(s, "COMMIT_ORDER v1\ncommit 진입 시 durable watermark snapshot", 3.05, 1.86, 2.3, 0.22, {
      fontSize: 7.6,
      color: C.muted,
      align: "center",
    });

    s.addShape(pptx.ShapeType.roundRect, {
      x: 0.62,
      y: 3.7,
      w: 12.1,
      h: 3.15,
      rectRadius: 0.06,
      fill: { color: "EEF8F1" },
      line: { color: "A9D5B7", width: 1 },
    });
    text(s, "SLAVE", 0.9, 3.9, 0.8, 0.14, { fontSize: 8.5, bold: true, color: "577461" });

    box(s, "LogReader\nrepl log decode\nLA_APPLY 구성", 1.0, 4.55, 1.58, 0.88, {
      fill: C.white,
      line: "5F8FC9",
      bold: true,
      fontSize: 9.2,
    });
    box(s, "Coordinator\npending / ready queue\nworker 선택", 3.15, 4.38, 1.82, 1.22, {
      fill: "EAF7F8",
      line: C.teal,
      lineWidth: 1.4,
      bold: true,
      fontSize: 9.2,
    });
    box(s, "dispatch rule\nT.dependency_seq <=\nslave_committed_seq", 3.02, 5.92, 2.08, 0.5, {
      fill: C.navy,
      line: C.navy,
      color: C.white,
      bold: true,
      fontSize: 8.4,
    });
    box(s, "W1\napply / flush", 6.0, 4.18, 1.16, 0.48, {
      fill: C.white,
      line: "83C79D",
      bold: true,
      fontSize: 8.8,
    });
    box(s, "W2\napply / flush", 6.0, 4.82, 1.16, 0.48, {
      fill: C.white,
      line: "83C79D",
      bold: true,
      fontSize: 8.8,
    });
    box(s, "W3\napply / flush", 6.0, 5.46, 1.16, 0.48, {
      fill: C.white,
      line: "83C79D",
      bold: true,
      fontSize: 8.8,
    });
    box(s, "commit gate\ncommit_seq 순서 대기", 8.08, 4.62, 1.62, 0.72, {
      fill: "FFF3EA",
      line: "E7A94F",
      bold: true,
      fontSize: 9.2,
    });
    box(s, "Retire / Progress\ncommitted_lsa\nslave_committed_seq", 10.45, 4.56, 1.72, 0.84, {
      fill: C.white,
      line: "A9B7C7",
      bold: true,
      fontSize: 8.9,
    });
    box(s, "db_ha_apply_info\ngap-free progress", 10.45, 5.73, 1.72, 0.46, {
      fill: "FFF7E8",
      line: "E7A94F",
      fontSize: 7.8,
    });

    arrow(s, 11.05, 2.98, 1.78, 4.5, C.muted, 1.1, true);
    text(s, "copied repl log", 1.28, 4.18, 0.9, 0.12, { fontSize: 7.2, color: C.muted, align: "center" });
    arrow(s, 2.66, 5.0, 3.04, 5.0, C.blue, 1.2);
    arrow(s, 5.06, 4.7, 5.88, 4.42, C.teal, 1.1);
    arrow(s, 5.06, 5.0, 5.88, 5.06, C.teal, 1.1);
    arrow(s, 5.06, 5.3, 5.88, 5.7, C.teal, 1.1);
    arrow(s, 7.25, 5.06, 7.96, 5.0, C.green, 1.2);
    arrow(s, 9.78, 5.0, 10.34, 5.0, C.orange, 1.2);
    arrow(s, 11.3, 5.42, 11.3, 5.68, C.orange, 1.1);
    arrow(s, 10.42, 6.16, 4.6, 6.46, C.muted, 1.0, true);
    text(s, "완료 보고 후 pending 재평가", 6.35, 6.25, 2.0, 0.12, {
      fontSize: 7.2,
      color: C.muted,
      align: "center",
    });

    text(s, "핵심: Slave는 충돌을 재계산하지 않고 Master가 내려준 dependency_seq만 집행한다.", 0.74, 6.96, 9.4, 0.18, {
      fontSize: 10.2,
      bold: true,
      color: C.ink,
    });
    footer(s, 9);
  }

  addBlankSlide();

  return pptx.writeFile({ fileName: TMP });
}

function maxNumber(values) {
  return values.reduce((max, value) => Math.max(max, Number(value)), 0);
}

function insertBeforeCloseTag(xml, closeTag, insertion) {
  const index = xml.lastIndexOf(closeTag);
  if (index < 0) throw new Error(`Close tag not found: ${closeTag}`);
  return xml.slice(0, index) + insertion + xml.slice(index);
}

async function appendToSevenSlideDeck() {
  const srcZip = await JSZip.loadAsync(fs.readFileSync(SRC));
  const tmpZip = await JSZip.loadAsync(fs.readFileSync(TMP));

  for (let i = 1; i <= 3; i += 1) {
    const targetSlide = i + 7;
    const xml = await tmpZip.file(`ppt/slides/slide${i}.xml`).async("string");
    srcZip.file(`ppt/slides/slide${targetSlide}.xml`, xml);
    srcZip.file(
      `ppt/slides/_rels/slide${targetSlide}.xml.rels`,
      '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n' +
        '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">' +
        '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideLayout" Target="../slideLayouts/slideLayout1.xml"/>' +
        "</Relationships>"
    );
  }

  let presentationXml = await srcZip.file("ppt/presentation.xml").async("string");
  const slideIds = [...presentationXml.matchAll(/<p:sldId id="(\d+)" r:id="(rId\d+)"\/>/g)];
  const nextSlideId = maxNumber(slideIds.map((m) => m[1])) + 1;
  const newSlideIds = [8, 9, 10]
    .map((slideNo, idx) => `<p:sldId id="${nextSlideId + idx}" r:id="rId${14 + idx}"/>`)
    .join("");
  presentationXml = presentationXml.replace("</p:sldIdLst>", `${newSlideIds}</p:sldIdLst>`);
  srcZip.file("ppt/presentation.xml", presentationXml);

  let relsXml = await srcZip.file("ppt/_rels/presentation.xml.rels").async("string");
  const newRels = [8, 9, 10]
    .map(
      (slideNo, idx) =>
        `<Relationship Id="rId${14 + idx}" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slide" Target="slides/slide${slideNo}.xml"/>`
    )
    .join("");
  relsXml = relsXml.replace("</Relationships>", `${newRels}</Relationships>`);
  srcZip.file("ppt/_rels/presentation.xml.rels", relsXml);

  let contentTypes = await srcZip.file("[Content_Types].xml").async("string");
  const slideContentType = "application/vnd.openxmlformats-officedocument.presentationml.slide+xml";
  for (const slideNo of [8, 9, 10]) {
    const partName = `/ppt/slides/slide${slideNo}.xml`;
    if (!contentTypes.includes(`PartName="${partName}"`)) {
      contentTypes = insertBeforeCloseTag(
        contentTypes,
        "</Types>",
        `<Override PartName="${partName}" ContentType="${slideContentType}"/>`
      );
    }
  }
  srcZip.file("[Content_Types].xml", contentTypes);

  const buffer = await srcZip.generateAsync({
    type: "nodebuffer",
    compression: "DEFLATE",
    compressionOptions: { level: 6 },
  });
  fs.writeFileSync(OUT, buffer);
}

async function replaceSlidesInKoreanDeck() {
  if (!fs.existsSync(KOREAN_SRC)) return;

  const srcZip = await JSZip.loadAsync(fs.readFileSync(KOREAN_SRC));
  const tmpZip = await JSZip.loadAsync(fs.readFileSync(TMP));

  for (let i = 1; i <= 3; i += 1) {
    const targetSlide = i + 7;
    const xml = await tmpZip.file(`ppt/slides/slide${i}.xml`).async("string");
    srcZip.file(`ppt/slides/slide${targetSlide}.xml`, xml);
    srcZip.file(
      `ppt/slides/_rels/slide${targetSlide}.xml.rels`,
      '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n' +
        '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">' +
        '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideLayout" Target="../slideLayouts/slideLayout1.xml"/>' +
        "</Relationships>"
    );
  }

  const buffer = await srcZip.generateAsync({
    type: "nodebuffer",
    compression: "DEFLATE",
    compressionOptions: { level: 6 },
  });
  fs.writeFileSync(KOREAN_OUT, buffer);
}

async function main() {
  await makeDeck();
  await appendToSevenSlideDeck();
  await replaceSlidesInKoreanDeck();
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});
