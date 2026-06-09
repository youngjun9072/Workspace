#!/usr/bin/env python3
import html
import re
import sys
from pathlib import Path

from PIL import Image as PILImage
from reportlab.lib import colors
from reportlab.lib.enums import TA_CENTER, TA_RIGHT
from reportlab.lib.pagesizes import A4
from reportlab.lib.styles import ParagraphStyle, getSampleStyleSheet
from reportlab.lib.units import mm
from reportlab.pdfbase import pdfmetrics
from reportlab.pdfbase.ttfonts import TTFont
from reportlab.platypus import (
    Image,
    KeepTogether,
    ListFlowable,
    ListItem,
    PageBreak,
    Paragraph,
    Preformatted,
    SimpleDocTemplate,
    Spacer,
    Table,
    TableStyle,
)


ROOT = Path.cwd()
FONT_PATH = Path("/System/Library/Fonts/Supplemental/AppleGothic.ttf")
FONT_NAME = "AppleGothic"
MONO_FONT = "Courier"


def register_fonts():
    pdfmetrics.registerFont(TTFont(FONT_NAME, str(FONT_PATH)))


def inline(text: str) -> str:
    text = html.escape(text)
    text = re.sub(r"`([^`]+)`", rf'<font name="{MONO_FONT}" backColor="#eef2f7">\1</font>', text)
    text = re.sub(r"\*\*([^*]+)\*\*", r"<b>\1</b>", text)
    return text


def styles():
    base = getSampleStyleSheet()
    normal = ParagraphStyle(
        "NormalK",
        parent=base["Normal"],
        fontName=FONT_NAME,
        fontSize=9.8,
        leading=15,
        spaceAfter=5,
    )
    return {
        "normal": normal,
        "h1": ParagraphStyle("H1K", parent=normal, fontSize=24, leading=31, spaceAfter=14, textColor=colors.HexColor("#111827")),
        "h2": ParagraphStyle("H2K", parent=normal, fontSize=16, leading=22, spaceBefore=12, spaceAfter=7, textColor=colors.HexColor("#111827"), keepWithNext=True),
        "h3": ParagraphStyle("H3K", parent=normal, fontSize=12.5, leading=18, spaceBefore=8, spaceAfter=5, textColor=colors.HexColor("#111827"), keepWithNext=True),
        "quote": ParagraphStyle("QuoteK", parent=normal, leftIndent=8, rightIndent=4, borderColor=colors.HexColor("#9ca3af"), borderWidth=0.8, borderPadding=7, backColor=colors.HexColor("#f6f8fa"), spaceBefore=4, spaceAfter=8),
        "bullet": ParagraphStyle("BulletK", parent=normal, leftIndent=8, firstLineIndent=0, spaceAfter=2),
        "code": ParagraphStyle("CodeK", parent=normal, fontName=MONO_FONT, fontSize=7.8, leading=10, textColor=colors.HexColor("#111827"), backColor=colors.HexColor("#f3f4f6"), borderPadding=6, spaceBefore=4, spaceAfter=8),
        "caption": ParagraphStyle("CaptionK", parent=normal, fontSize=8.5, leading=12, alignment=TA_CENTER, textColor=colors.HexColor("#4b5563")),
        "num": ParagraphStyle("NumK", parent=normal, alignment=TA_RIGHT),
    }


def is_table_sep(line: str) -> bool:
    return bool(re.match(r"^\s*\|?\s*:?-{3,}:?\s*(\|\s*:?-{3,}:?\s*)+\|?\s*$", line))


def make_table(lines, i, st):
    header = [c.strip() for c in lines[i].strip().strip("|").split("|")]
    align = [c.strip() for c in lines[i + 1].strip().strip("|").split("|")]
    rows = []
    i += 2
    while i < len(lines) and lines[i].lstrip().startswith("|"):
        rows.append([c.strip() for c in lines[i].strip().strip("|").split("|")])
        i += 1

    data = []
    for row_index, row in enumerate([header] + rows):
        rendered = []
        for col_index, cell in enumerate(row):
            style = st["num"] if col_index < len(align) and align[col_index].endswith(":") else st["normal"]
            rendered.append(Paragraph(inline(cell), style))
        data.append(rendered)

    table = Table(data, repeatRows=1, hAlign="LEFT")
    table.setStyle(
        TableStyle(
            [
                ("FONTNAME", (0, 0), (-1, -1), FONT_NAME),
                ("BACKGROUND", (0, 0), (-1, 0), colors.HexColor("#eef2f7")),
                ("TEXTCOLOR", (0, 0), (-1, 0), colors.HexColor("#111827")),
                ("GRID", (0, 0), (-1, -1), 0.4, colors.HexColor("#cbd5e1")),
                ("VALIGN", (0, 0), (-1, -1), "TOP"),
                ("LEFTPADDING", (0, 0), (-1, -1), 5),
                ("RIGHTPADDING", (0, 0), (-1, -1), 5),
                ("TOPPADDING", (0, 0), (-1, -1), 4),
                ("BOTTOMPADDING", (0, 0), (-1, -1), 4),
            ]
        )
    )
    return [table, Spacer(1, 5)], i


def make_image(src, alt, max_width):
    path = (ROOT / src).resolve()
    if not path.exists():
        return [Paragraph(inline(f"[missing image: {src}]"), styles()["normal"])]
    with PILImage.open(path) as im:
        width, height = im.size
    draw_width = min(max_width, width * 0.45)
    draw_height = height * (draw_width / width)
    return [Image(str(path), width=draw_width, height=draw_height), Paragraph(inline(alt), styles()["caption"]), Spacer(1, 8)]


def flush_para(story, para, st):
    if para:
        text = " ".join(para).strip()
        image_match = re.fullmatch(r"!\[([^\]]*)\]\(([^)]+)\)", text)
        if image_match:
            story.extend(make_image(image_match.group(2), image_match.group(1), A4[0] - 34 * mm))
        else:
            story.append(Paragraph(inline(text), st["normal"]))
        para.clear()


def build_story(markdown, st):
    story = []
    lines = markdown.splitlines()
    para = []
    code = []
    in_code = False
    list_items = []

    def flush_list():
        if list_items:
            flow = [
                ListItem(Paragraph(inline(text), st["bullet"]), leftIndent=10)
                for _, text in list_items
            ]
            story.append(ListFlowable(flow, bulletType="bullet", leftIndent=13, bulletFontName=FONT_NAME))
            story.append(Spacer(1, 3))
            list_items.clear()

    i = 0
    while i < len(lines):
        line = lines[i]

        if line.startswith("```"):
            flush_para(story, para, st)
            flush_list()
            if in_code:
                story.append(Preformatted("\n".join(code), st["code"]))
                code.clear()
                in_code = False
            else:
                in_code = True
            i += 1
            continue

        if in_code:
            code.append(line)
            i += 1
            continue

        if not line.strip():
            flush_para(story, para, st)
            flush_list()
            i += 1
            continue

        if line.strip() == "---":
            flush_para(story, para, st)
            flush_list()
            story.append(Spacer(1, 5))
            i += 1
            continue

        if i + 1 < len(lines) and line.lstrip().startswith("|") and is_table_sep(lines[i + 1]):
            flush_para(story, para, st)
            flush_list()
            table_flowables, i = make_table(lines, i, st)
            story.extend(table_flowables)
            continue

        heading = re.match(r"^(#{1,6})\s+(.+)$", line)
        if heading:
            flush_para(story, para, st)
            flush_list()
            level = min(len(heading.group(1)), 3)
            story.append(Paragraph(inline(heading.group(2)), st[f"h{level}"]))
            if level == 1:
                story.append(Spacer(1, 5))
            i += 1
            continue

        if line.startswith(">"):
            flush_para(story, para, st)
            flush_list()
            quote = []
            while i < len(lines) and lines[i].startswith(">"):
                quote.append(lines[i][1:].strip())
                i += 1
            story.append(Paragraph("<br/>".join(inline(q) for q in quote), st["quote"]))
            continue

        item = re.match(r"^\s*(?:[-*]|\d+\.)\s+(.+)$", line)
        if item:
            flush_para(story, para, st)
            list_items.append((0, item.group(1)))
            i += 1
            continue

        if re.fullmatch(r"!\[([^\]]*)\]\(([^)]+)\)", line.strip()):
            flush_para(story, para, st)
            flush_list()
            alt, src = re.fullmatch(r"!\[([^\]]*)\]\(([^)]+)\)", line.strip()).groups()
            story.extend(make_image(src, alt, A4[0] - 34 * mm))
            i += 1
            continue

        flush_list()
        para.append(line.strip())
        i += 1

    flush_para(story, para, st)
    flush_list()
    return story


def main():
    register_fonts()
    src = Path(sys.argv[1])
    dst = Path(sys.argv[2])
    st = styles()
    doc = SimpleDocTemplate(
        str(dst),
        pagesize=A4,
        rightMargin=16 * mm,
        leftMargin=16 * mm,
        topMargin=18 * mm,
        bottomMargin=18 * mm,
        title=src.stem,
    )
    story = build_story(src.read_text(encoding="utf-8"), st)
    doc.build(story)


if __name__ == "__main__":
    main()
