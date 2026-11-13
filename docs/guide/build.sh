#!/usr/bin/env bash
# build.sh — turn ValveScope-Server-Guide.md into ValveScope-Server-Guide.pdf.
#
#   docs/guide/build.sh
#
# Needs: python3 with the markdown-it package (python3-markdown-it on Ubuntu) and
# Google Chrome or Chromium. Markdown -> one HTML page (with a table of contents
# and the diagrams from img/) -> PDF printed by the browser. Writes only the .pdf.
set -euo pipefail
cd "$(dirname "$0")"
NAME=ValveScope-Server-Guide
CHROME="$(command -v google-chrome || command -v chromium || command -v chromium-browser || true)"
[ -n "$CHROME" ] || { echo "build: no google-chrome or chromium on PATH" >&2; exit 1; }
python3 -c 'import markdown_it' 2>/dev/null || { echo "build: python3 package markdown-it is missing (sudo apt install python3-markdown-it)" >&2; exit 1; }
tmp="$(mktemp -d "${TMPDIR:-/tmp}/vs-guide.XXXXXX")"
trap 'rm -f "$tmp/$NAME.html"; rmdir "$tmp" 2>/dev/null || true' EXIT

python3 - "$NAME.md" "$tmp/$NAME.html" "$PWD" <<'PY'
import re, sys
from html import escape
from markdown_it import MarkdownIt

src, out, base = sys.argv[1:4]
text = open(src, encoding="utf-8").read()
md = MarkdownIt("commonmark", {"html": False, "typographer": False}).enable("table")
body = md.render(text)

# Give headings ids and collect a table of contents (parts and their sections).
toc, seen = [], {}
def slug(t):
    s = re.sub(r"[^a-z0-9]+", "-", re.sub(r"<[^>]+>", "", t).lower()).strip("-") or "section"
    seen[s] = seen.get(s, 0) + 1
    return s if seen[s] == 1 else f"{s}-{seen[s]}"
def heading(m):
    level, inner = int(m.group(1)), m.group(2)
    i = slug(inner)
    if level in (1, 2) and toc is not None and not (level == 1 and not toc and "Server Guide" in inner):
        toc.append((level, i, re.sub(r"<[^>]+>", "", inner)))
    return f'<h{level} id="{i}">{inner}</h{level}>'
body = re.sub(r"<h([1-4])>(.*?)</h\1>", heading, body, flags=re.S)

# A table whose header cells are all empty (used for the title block) loses its header row.
body = re.sub(r"<thead>\s*<tr>(\s*<th[^>]*></th>)+\s*</tr>\s*</thead>", "", body)
# Status marks become small labels.
for mark, cls in (("[done on Ludwig]", "done"), ("[rehearsed]", "reh"), ("[written, not tried]", "nt")):
    body = body.replace(f"<strong>{mark}</strong>", f'<span class="mark {cls}">{mark[1:-1]}</span>')
# Images are block figures with their alt text as caption.
body = re.sub(r'<p><img src="([^"]+)" alt="([^"]*)" ?/?></p>',
              lambda m: f'<figure><img src="{m.group(1)}" alt="{m.group(2)}"><figcaption>{m.group(2)}</figcaption></figure>', body)

toc_html = ['<nav class="toc"><h2 class="toc-title">Contents</h2><ul>']
for level, i, title in toc:
    if title in ("How to read this guide",):
        continue
    toc_html.append(f'<li class="l{level}"><a href="#{i}">{escape(title)}</a></li>')
toc_html.append("</ul></nav>")
# Contents go after the title block (everything before the first h2).
first_h2 = body.index("<h2")
body = body[:first_h2] + "".join(toc_html) + body[first_h2:]

css = """
@page { size: A4; margin: 18mm 16mm 20mm 16mm;
        @bottom-center { content: "ValveScope Server Guide  ·  page " counter(page) " of " counter(pages); font: 8.5pt "DejaVu Sans", sans-serif; color: #7b8794; } }
@page :first { @bottom-center { content: ""; } }
* { box-sizing: border-box; }
html { font: 10.5pt/1.5 "DejaVu Sans", "Liberation Sans", Arial, sans-serif; color: #1f2933; }
body { margin: 0; }
h1 { font-size: 21pt; line-height: 1.2; margin: 0 0 4pt; color: #102a43; break-before: page; }
h1:first-of-type { break-before: auto; font-size: 27pt; margin-top: 8mm; }
#the-system-on-one-page { break-before: page; }
p:has(> strong:only-child) { break-after: avoid; }
h2 { font-size: 14.5pt; margin: 20pt 0 6pt; padding-bottom: 3pt; border-bottom: 1.2pt solid #cbd2d9; color: #102a43; break-after: avoid; }
h3 { font-size: 11.5pt; margin: 14pt 0 4pt; color: #243b53; break-after: avoid; }
p { margin: 0 0 7pt; }
ul, ol { margin: 0 0 7pt; padding-left: 16pt; }
li { margin-bottom: 2.5pt; }
a { color: #0b69a3; text-decoration: none; }
code { font: 8.8pt "DejaVu Sans Mono", "Liberation Mono", monospace; background: #f0f4f8; padding: 0.5pt 3pt; border-radius: 3pt; }
pre { background: #f5f7fa; border: 0.8pt solid #d9e2ec; border-left: 3pt solid #829ab1; border-radius: 4pt; padding: 7pt 9pt; margin: 4pt 0 9pt;
      white-space: pre-wrap; overflow-wrap: anywhere; orphans: 3; widows: 3; }
pre code { background: none; padding: 0; font-size: 8.3pt; line-height: 1.45; }
table { border-collapse: collapse; width: 100%; margin: 4pt 0 10pt; font-size: 9.3pt; line-height: 1.4; }
th { text-align: left; background: #e9eef4; color: #102a43; padding: 4pt 6pt; border: 0.8pt solid #cbd2d9; }
td { padding: 4pt 6pt; border: 0.8pt solid #d9e2ec; vertical-align: top; }
tr { break-inside: avoid; }
thead { display: table-header-group; }
blockquote { margin: 8pt 0 10pt; padding: 7pt 10pt; background: #fff8e6; border-left: 3pt solid #d9a400; border-radius: 3pt; break-inside: avoid; }
blockquote p:last-child { margin-bottom: 0; }
hr { display: none; }
figure { margin: 8pt 0 12pt; text-align: center; break-inside: avoid; }
figure img { max-width: 100%; height: auto; border: 0.8pt solid #d9e2ec; border-radius: 4pt; }
figcaption { font-size: 8.8pt; color: #52606d; margin-top: 3pt; font-style: italic; }
.mark { font-size: 7.8pt; font-weight: bold; padding: 1pt 5pt; border-radius: 8pt; white-space: nowrap; vertical-align: 1pt; }
.mark.done { background: #def7e5; color: #14653a; }
.mark.reh { background: #fff1cc; color: #7a5200; }
.mark.nt { background: #fde3e3; color: #8a1c1c; }
h1:first-of-type + p { font-size: 13pt; color: #334e68; margin-bottom: 14pt; }
.toc { break-after: page; margin-top: 14pt; }
.toc ul { list-style: none; padding: 0; }
.toc li { margin-bottom: 1pt; }
.toc li.l1 { font-weight: bold; margin-top: 6pt; font-size: 10.5pt; }
.toc li.l2 { padding-left: 14pt; font-size: 9.5pt; }
.toc-title { border: none; }
"""
html = f"""<!doctype html><html lang="en"><head><meta charset="utf-8"><title>ValveScope Server Guide</title>
<base href="file://{base}/"><style>{css}</style></head><body>{body}</body></html>"""
open(out, "w", encoding="utf-8").write(html)
PY

"$CHROME" --headless=new --disable-gpu --no-pdf-header-footer --print-to-pdf="$PWD/$NAME.pdf" \
  "file://$tmp/$NAME.html" >/dev/null 2>&1
[ -s "$NAME.pdf" ] || { echo "build: the browser produced no PDF" >&2; exit 1; }
echo "wrote $PWD/$NAME.pdf ($(du -h "$NAME.pdf" | cut -f1))"
