# Normalize Arabic law text and split into upload parts at article boundaries.
# Usage: clean_law.py IN.txt OUTPREFIX [--fix-kaf] [--part-chars N]
import sys, re, unicodedata
src, out = sys.argv[1], sys.argv[2]
fix_kaf = "--fix-kaf" in sys.argv
part_chars = int(sys.argv[sys.argv.index("--part-chars") + 1]) if "--part-chars" in sys.argv else 24000
t = open(src, encoding="utf-8").read()
t = unicodedata.normalize("NFKC", t)
t = re.sub(r"[​-‏‪-‮⁦-⁩﻿]", "", t)
t = t.replace("ـ", "")
t = re.sub(r"[ً-ْٰ]", "", t)
t = re.sub(r"[٠-٩]", lambda m: str(ord(m.group()) - 0x660), t)
if fix_kaf:
    # this PDF renders ك as آ; keep the few real آ words
    keep = r"(?:آخر|الآخر|آخرين|آخرون|الآخرين|آخره|الآن|آثار|الآثار|آجل|آلات|الآلات|آلة|الآلة|القرآن|آبار)"
    t = re.sub(keep, lambda m: m.group().replace("آ", "\x00"), t)
    t = t.replace("آ", "ك").replace("\x00", "آ")
if fix_kaf:
    # bidi-reordered numbering: "مادة (1) – 87" -> "مادة 87 - (1)", "مادة – 86" -> "مادة 86 -"
    t = re.sub(r"مادة\s*\(\s*(\d+)\s*\)\s*[–\-]\s*(\d+)", r"مادة \2 - (\1)", t)
    t = re.sub(r"مادة\s*[–\-]\s*(\d+)", r"مادة \1 -", t)
lines = [re.sub(r"[ \t]+", " ", l).strip() for l in t.split("\n")]
t = "\n".join(lines)
t = re.sub(r"\n{3,}", "\n\n", t)
# blank line before each article so the splitter keeps articles whole
t = re.sub(r"\n\s*((?:ال)?مادة\s*[\(\[]?\s*\d+)", r"\n\n\1", t)
t = re.sub(r"\n{3,}", "\n\n", t).strip()
blocks = re.split(r"\n\n", t)
parts, cur = [], ""
for b in blocks:
    if len(cur) + len(b) > part_chars and cur:
        parts.append(cur); cur = ""
    cur += b + "\n\n"
if cur.strip(): parts.append(cur)
for i, p in enumerate(parts, 1):
    open(f"{out}.part{i:02d}.txt", "w", encoding="utf-8").write(p)
arts = re.findall(r"(?:^|\n)(?:ال)?مادة\s*[\(\[]?\s*(\d+)", t)
print(f"{out}: {len(t)} chars, {len(parts)} parts, articles {len(arts)} (max {max(map(int, arts)) if arts else 0})")
