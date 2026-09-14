#!/usr/bin/env python3
"""Pull Apple's Human Interface Guidelines into references/hig/*.md and references/hig-index.md.

Apple renders every HIG page from JSON served at
  https://developer.apple.com/tutorials/data/design/human-interface-guidelines/<slug>.json
This crawls from the root collection, writes one Markdown file per article page in Apple's own
wording and headings (all six platforms kept), and rebuilds the index that routes a topic to
its file. Stdlib only, Python 3.9+. A second run over unchanged pages changes nothing.

Usage: pull_hig.py [--cache DIR] [--workers N] [--force-prune]
"""
import argparse
import json
import re
import sys
import urllib.request
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "references" / "hig"
INDEX = ROOT / "references" / "hig-index.md"
DATA = "https://developer.apple.com/tutorials/data/design/human-interface-guidelines"
WEB = "https://developer.apple.com/design/human-interface-guidelines"
SITE = "https://developer.apple.com"
SLUG_RE = re.compile(r"/Human-Interface-Guidelines/([a-z0-9-]+)(?:#(.*))?$", re.I)
GLYPHS = {"checkmark": "✓", "crossout": "✗", "xmark": "✗"}
PLATFORMS = {"ios": "iOS", "ipados": "iPadOS", "macos": "macOS", "tvos": "tvOS", "visionos": "visionOS", "watchos": "watchOS"}
SOURCE_LINE = f"> Source: <{WEB}/"
PRUNE_SHARE = 0.1


def fetch(slug, cache):
    name = (slug or "index") + ".json"
    if cache and (cache / name).exists():
        return json.loads((cache / name).read_text())
    url = f"{DATA}/{slug}.json" if slug else f"{DATA}.json"
    with urllib.request.urlopen(urllib.request.Request(url, headers={"User-Agent": "pull_hig.py"}), timeout=60) as r:
        raw = r.read()
    if cache:
        cache.mkdir(parents=True, exist_ok=True)
        (cache / name).write_bytes(raw)
    return json.loads(raw)


def slug_of(identifier):
    m = SLUG_RE.search(identifier)
    return m.group(1) if m else None


def children(doc):
    return [s for ts in doc.get("topicSections", []) for s in (slug_of(i) for i in ts["identifiers"]) if s]


def crawl(cache, workers):
    """Breadth-first over Apple's collections. Returns {slug: {json, path}}, path = section titles."""
    root = fetch("", cache)
    pages = {}
    frontier = {s: [] for s in children(root)}
    with ThreadPoolExecutor(workers) as pool:
        while frontier:
            docs = pool.map(lambda s: fetch(s, cache), frontier)
            nxt = {}
            for (slug, path), doc in zip(frontier.items(), docs):
                pages[slug] = {"json": doc, "path": path}
                for c in children(doc):
                    if c not in pages and c not in nxt:
                        nxt[c] = path + [doc["metadata"]["title"]]
            frontier = nxt
    return root, pages


def is_article(doc):
    return doc["metadata"].get("role") == "article"


# --- rendering -------------------------------------------------------------

def wrap(mark, text):
    core = text.strip()
    if not core:
        return text
    lead = " " if text[:1] == " " else ""
    trail = " " if text[-1:] == " " else ""
    return f"{lead}{mark}{core}{mark}{trail}"


def link(node, ctx):
    ref = ctx["refs"].get(node["identifier"], {})
    title = node.get("overridingTitle") or ref.get("title") or node["identifier"]
    m = SLUG_RE.search(node["identifier"])
    if m:
        slug, anchor = m.group(1), m.group(2)
        if slug in ctx["articles"]:
            return f"[{title}]({slug}.md{'#' + anchor.lower() if anchor else ''})"
        return f"[{title}]({WEB}/{slug})"
    url = ref.get("url") or ""
    if url.startswith("/"):
        url = SITE + url
    return f"[{title}]({url})" if url.startswith("http") else title


def image(node, ctx):
    ident = node["identifier"].lower()
    glyph = next((g for k, g in GLYPHS.items() if k in ident), "")
    if glyph:
        return glyph
    caption = inline(node.get("metadata", {}).get("abstract"), ctx).strip()
    return f"*{caption}*" if caption else ""


def inline(nodes, ctx):
    out = []
    for n in nodes or []:
        t = n.get("type")
        if t == "text":
            out.append(n.get("text", ""))
        elif t == "strong":
            out.append(wrap("**", inline(n.get("inlineContent"), ctx)))
        elif t == "emphasis":
            out.append(wrap("*", inline(n.get("inlineContent"), ctx)))
        elif t == "codeVoice":
            out.append(f"`{n.get('code', '')}`")
        elif t == "reference":
            out.append(link(n, ctx))
        elif t == "image":
            out.append(image(n, ctx))
        else:
            out.append(inline(n.get("inlineContent"), ctx))
    return "".join(out)


def render(blocks, ctx):
    out = []
    for b in blocks or []:
        t = b.get("type")
        if t == "paragraph":
            s = inline(b.get("inlineContent"), ctx).strip()
            if s:
                out += [s, ""]
        elif t == "heading":
            out += ["#" * b["level"] + " " + b["text"], ""]
        elif t in ("unorderedList", "orderedList"):
            for i, item in enumerate(b["items"], 1):
                lines = "\n".join(render(item["content"], ctx)).strip().split("\n")
                out.append(f"{'-' if t == 'unorderedList' else f'{i}.'} {lines[0]}")
                out += ["  " + l if l else "" for l in lines[1:]]
            out.append("")
        elif t == "aside":
            lines = "\n".join(render(b["content"], ctx)).strip().split("\n")
            out.append(f"> **{b.get('name') or b.get('style', 'Note').title()}:** {lines[0]}")
            out += ["> " + l for l in lines[1:]]
            out.append("")
        elif t == "table":
            rows = [[cell(c, ctx) for c in row] for row in b["rows"]]
            width = max(len(r) for r in rows)
            rows = [r + [""] * (width - len(r)) for r in rows]
            out.append("| " + " | ".join(rows[0]) + " |")
            out.append("|" + " --- |" * width)
            out += ["| " + " | ".join(r) + " |" for r in rows[1:]]
            out.append("")
        elif t == "tabNavigator":
            for tab in b["tabs"]:
                body = render(tab["content"], ctx)
                if not "".join(body).strip():
                    continue
                if not re.match(r"#+ " + re.escape(tab["title"]) + r"$", body[0]):
                    out += [f"**{tab['title']}**", ""]
                out += body
        elif t == "row":
            cols = [[l for l in render(col["content"], ctx) if l] for col in b["columns"]]
            if all(len(c) <= 2 and c and c[-1] in GLYPHS.values() for c in cols):
                captioned = [f"{c[-1]} {c[0]}" for c in cols if len(c) == 2]
                if captioned:  # a bare ✗ ✓ pair with no captions carries nothing without its images
                    out += ["  ".join(captioned), ""]
            else:
                for c in cols:
                    out += c + [""]
        elif t == "links":
            for ident in b["items"]:
                ref = ctx["refs"].get(ident, {})
                if not ref.get("title"):
                    continue
                target = link({"identifier": ident}, ctx)
                out.append(f"- {target}")
            out.append("")
        elif t == "small":
            s = inline(b.get("inlineContent"), ctx).strip()
            if s:
                out += [f"*{s}*", ""]
        # video and anything unknown: dropped
    return out


def cell(blocks, ctx):
    text = "<br>".join(l for l in render(blocks, ctx) if l).replace("|", "\\|")
    if text:
        return text
    for b in blocks:  # an image-only cell keeps its alt text so the row keeps its meaning
        for n in b.get("inlineContent", []):
            if n.get("type") == "image":
                return (ctx["refs"].get(n["identifier"], {}).get("alt") or "").replace("|", "\\|")
    return ""


def platforms_of(doc):
    raw = doc["metadata"].get("customMetadata", {}).get("supported-platforms", "")
    return ", ".join(PLATFORMS.get(p, p) for p in raw.split(",") if p)


def last_change(doc):
    cm = doc["metadata"].get("customMetadata", {})
    if not cm.get("alert-date"):
        return "-"
    return f"{cm['alert-date']} — {cm.get('alert-text', '').strip()}".rstrip(" —")


def plain(nodes, refs):
    return "".join(
        n.get("text", "") if n.get("type") == "text"
        else n.get("overridingTitle") or refs.get(n.get("identifier", ""), {}).get("title", "") if n.get("type") == "reference"
        else n.get("code", "") if n.get("type") == "codeVoice"
        else plain(n.get("inlineContent"), refs)
        for n in nodes or []
    )


def render_page(slug, page, articles):
    doc = page["json"]
    ctx = {"refs": doc.get("references", {}), "articles": articles}
    content = next((s["content"] for s in doc.get("primaryContentSections", []) if s.get("kind") == "content"), [])
    if not content:
        raise SystemExit(f"{slug}: no content blocks; Apple's page format may have changed. Nothing written.")
    header = [
        f"# {doc['metadata']['title']}",
        "",
        f"> Source: <{WEB}/{slug}>",
        f"> Section: {' › '.join(page['path'])}",
        f"> Platforms: {platforms_of(doc) or '-'}",
        f"> Last changed: {last_change(doc)}",
        "",
        inline(doc.get("abstract"), ctx).strip(),
        "",
        "---",
        "",
    ]
    text = "\n".join(header + render(content, ctx))
    return re.sub(r"\n{3,}", "\n\n", text).strip() + "\n"


def render_index(root, pages):
    lines = [
        "# HIG index",
        "",
        "Generated by `scripts/pull_hig.py` from developer.apple.com; re-run it rather than editing. One row per page of Apple's Human Interface Guidelines, grouped as Apple groups them. `Covers` is Apple's own summary; `Last changed` is the date Apple stamps on the page. Load only the files a task needs.",
        "",
    ]

    def esc(s):
        return s.replace("|", "\\|")

    def section(slug, doc, depth):
        nonlocal lines
        lines.extend(["#" * depth + " " + doc["metadata"]["title"], ""])
        summary = plain(doc.get("abstract"), doc.get("references", {})).strip()
        if summary:
            lines += [summary, ""]
        kids = [(c, pages[c]) for c in children(doc)]
        arts = [(c, p) for c, p in kids if is_article(p["json"])]
        if arts:
            lines += ["| Page | File | Covers | Platforms | Last changed |", "| --- | --- | --- | --- | --- |"]
            for c, p in arts:
                d = p["json"]
                lines.append(
                    f"| [{esc(d['metadata']['title'])}](hig/{c}.md) | `{c}.md` | {esc(plain(d.get('abstract'), d.get('references', {})).strip())} "
                    f"| {platforms_of(d) or '-'} | {d['metadata'].get('customMetadata', {}).get('alert-date', '-')} |"
                )
            lines.append("")
        for c, p in kids:
            if not is_article(p["json"]):
                section(c, p["json"], depth + 1)

    for c in children(root):
        section(c, pages[c]["json"], 2)
    return "\n".join(lines).rstrip() + "\n"


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--cache", type=Path, help="keep raw JSON here and reuse it on later runs")
    ap.add_argument("--workers", type=int, default=6)
    ap.add_argument("--force-prune", action="store_true", help=f"allow removing more than {int(PRUNE_SHARE * 100)}%% of existing pages")
    a = ap.parse_args()

    root, pages = crawl(a.cache, a.workers)
    articles = {s for s, p in pages.items() if is_article(p["json"])}
    OUT.mkdir(parents=True, exist_ok=True)
    rendered = {s: render_page(s, pages[s], articles) for s in sorted(articles)}

    existing = {f for f in OUT.glob("*.md") if f.read_text().splitlines()[2:3] and f.read_text().splitlines()[2].startswith(SOURCE_LINE)}
    stale = {f for f in existing if f.stem not in articles}
    if existing and len(stale) > max(3, PRUNE_SHARE * len(existing)) and not a.force_prune:
        raise SystemExit(f"would remove {len(stale)} of {len(existing)} pages; re-run with --force-prune if Apple really removed them")

    changed = 0
    for slug, text in rendered.items():
        f = OUT / f"{slug}.md"
        if not f.exists() or f.read_text() != text:
            f.write_text(text)
            changed += 1
    for f in stale:
        f.unlink()
        print(f"removed {f.name} (no longer published)")
    index = render_index(root, pages)
    if not INDEX.exists() or INDEX.read_text() != index:
        INDEX.write_text(index)
        changed += 1
    print(f"{len(articles)} pages in {OUT.relative_to(ROOT)}, {len(pages) - len(articles)} collections folded into {INDEX.name}; {changed} files written, {len(stale)} removed")


if __name__ == "__main__":
    sys.exit(main())
