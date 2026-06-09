#!/usr/bin/env python3
import html
import re
import sys
from pathlib import Path


def inline(text: str) -> str:
    text = html.escape(text)
    text = re.sub(r"!\[([^\]]*)\]\(([^)]+)\)", r'<img src="\2" alt="\1">', text)
    text = re.sub(r"`([^`]+)`", r"<code>\1</code>", text)
    text = re.sub(r"\*\*([^*]+)\*\*", r"<strong>\1</strong>", text)
    return text


def parse_table(lines, i):
    header = [c.strip() for c in lines[i].strip().strip("|").split("|")]
    align = [c.strip() for c in lines[i + 1].strip().strip("|").split("|")]
    rows = []
    i += 2
    while i < len(lines) and lines[i].lstrip().startswith("|"):
        rows.append([c.strip() for c in lines[i].strip().strip("|").split("|")])
        i += 1

    out = ["<table><thead><tr>"]
    for cell, spec in zip(header, align):
        cls = ' class="num"' if spec.endswith(":") else ""
        out.append(f"<th{cls}>{inline(cell)}</th>")
    out.append("</tr></thead><tbody>")
    for row in rows:
        out.append("<tr>")
        for idx, cell in enumerate(row):
            cls = ' class="num"' if idx < len(align) and align[idx].endswith(":") else ""
            out.append(f"<td{cls}>{inline(cell)}</td>")
        out.append("</tr>")
    out.append("</tbody></table>")
    return "\n".join(out), i


def render(markdown: str) -> str:
    lines = markdown.splitlines()
    out = []
    in_code = False
    code_lang = ""
    para = []
    list_stack = []

    def flush_para():
        if para:
            out.append(f"<p>{inline(' '.join(para))}</p>")
            para.clear()

    def close_lists(to_level=0):
        while len(list_stack) > to_level:
            out.append(f"</{list_stack.pop()}>")

    i = 0
    while i < len(lines):
        line = lines[i]

        if line.startswith("```"):
            flush_para()
            close_lists()
            if in_code:
                out.append("</code></pre>")
                in_code = False
            else:
                code_lang = html.escape(line[3:].strip())
                klass = f' class="language-{code_lang}"' if code_lang else ""
                out.append(f"<pre><code{klass}>")
                in_code = True
            i += 1
            continue

        if in_code:
            out.append(html.escape(line))
            i += 1
            continue

        if not line.strip():
            flush_para()
            close_lists()
            i += 1
            continue

        if line.strip() == "---":
            flush_para()
            close_lists()
            out.append("<hr>")
            i += 1
            continue

        if i + 1 < len(lines) and line.lstrip().startswith("|") and re.match(r"^\s*\|?\s*:?-{3,}:?\s*(\|\s*:?-{3,}:?\s*)+\|?\s*$", lines[i + 1]):
            flush_para()
            close_lists()
            table, i = parse_table(lines, i)
            out.append(table)
            continue

        heading = re.match(r"^(#{1,6})\s+(.+)$", line)
        if heading:
            flush_para()
            close_lists()
            level = len(heading.group(1))
            out.append(f"<h{level}>{inline(heading.group(2))}</h{level}>")
            i += 1
            continue

        if line.startswith(">"):
            flush_para()
            close_lists()
            quote_lines = []
            while i < len(lines) and lines[i].startswith(">"):
                quote_lines.append(lines[i][1:].strip())
                i += 1
            out.append(f"<blockquote>{'<br>'.join(inline(q) for q in quote_lines)}</blockquote>")
            continue

        item = re.match(r"^(\s*)([-*]|\d+\.)\s+(.+)$", line)
        if item:
            flush_para()
            indent = len(item.group(1)) // 2
            tag = "ol" if item.group(2).endswith(".") else "ul"
            while len(list_stack) > indent and list_stack[-1] != tag:
                close_lists(len(list_stack) - 1)
            while len(list_stack) <= indent:
                list_stack.append(tag)
                out.append(f"<{tag}>")
            out.append(f"<li>{inline(item.group(3))}</li>")
            i += 1
            continue

        close_lists()
        para.append(line.strip())
        i += 1

    flush_para()
    close_lists()
    return "\n".join(out)


def main():
    src = Path(sys.argv[1])
    dst = Path(sys.argv[2])
    body = render(src.read_text(encoding="utf-8"))
    doc = f"""<!doctype html>
<html lang="ko">
<head>
<meta charset="utf-8">
<title>{html.escape(src.stem)}</title>
<style>
@page {{ size: A4; margin: 18mm 16mm; }}
body {{
  font-family: -apple-system, BlinkMacSystemFont, "Apple SD Gothic Neo", "Noto Sans CJK KR", "Malgun Gothic", sans-serif;
  color: #1f2933;
  font-size: 10.5pt;
  line-height: 1.58;
}}
h1 {{ font-size: 25pt; margin: 0 0 10mm; border-bottom: 2px solid #111827; padding-bottom: 5mm; }}
h2 {{ font-size: 17pt; margin: 12mm 0 4mm; break-after: avoid; }}
h3 {{ font-size: 13pt; margin: 8mm 0 3mm; break-after: avoid; }}
p {{ margin: 0 0 3.5mm; }}
blockquote {{ margin: 0 0 5mm; padding: 3mm 4mm; border-left: 4px solid #9ca3af; background: #f6f8fa; }}
ul, ol {{ margin: 0 0 4mm 6mm; padding-left: 5mm; }}
li {{ margin: 1.2mm 0; }}
table {{ width: 100%; border-collapse: collapse; margin: 4mm 0 6mm; font-size: 9.5pt; }}
th, td {{ border: 1px solid #cbd5e1; padding: 2.3mm 2.5mm; vertical-align: top; }}
th {{ background: #eef2f7; font-weight: 700; }}
.num {{ text-align: right; }}
pre {{ background: #111827; color: #f9fafb; padding: 4mm; overflow-wrap: anywhere; white-space: pre-wrap; font-size: 8.3pt; line-height: 1.35; }}
code {{ font-family: "SFMono-Regular", Consolas, monospace; font-size: 0.92em; }}
p code, li code, blockquote code, td code {{ background: #eef2f7; padding: 0.2mm 0.8mm; border-radius: 2px; }}
img {{ max-width: 100%; display: block; margin: 5mm auto 7mm; }}
hr {{ border: 0; border-top: 1px solid #d0d7de; margin: 7mm 0; }}
strong {{ color: #111827; }}
</style>
</head>
<body>
{body}
</body>
</html>
"""
    dst.write_text(doc, encoding="utf-8")


if __name__ == "__main__":
    main()
