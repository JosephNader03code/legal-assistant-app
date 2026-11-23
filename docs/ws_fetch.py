# Fetch Arabic Wikisource pages (and their subpages) as plain text. Usage: ws_fetch.py OUTDIR "Title|slug" ...
import sys, json, re, html, urllib.request, urllib.error, urllib.parse, os, time
API = "https://ar.wikisource.org/w/api.php"
def get(params):
    q = API + "?" + urllib.parse.urlencode({**params, "format": "json"})
    req = urllib.request.Request(q, headers={"User-Agent": "legal-library-builder/1.0"})
    for i in range(6):
        try: return json.load(urllib.request.urlopen(req, timeout=60))
        except urllib.error.HTTPError as e:
            if e.code != 429: raise
            time.sleep(10 * (i + 1))
    raise RuntimeError("rate limited")
def page_text(title):
    d = get({"action": "parse", "page": title, "prop": "text", "redirects": 1})
    h = d["parse"]["text"]["*"]
    h = re.sub(r"<(script|style)[^>]*>.*?</\1>", " ", h, flags=re.S)
    h = re.sub(r'<div class="(printfooter|mw-references-wrap|ws-noexport|headertemplate)[^"]*".*?</div>', " ", h, flags=re.S)
    h = re.sub(r"<br\s*/?>|</p>|</li>|</h\d>|</tr>|</div>", "\n", h)
    t = html.unescape(re.sub(r"<[^>]+>", "", h))
    t = re.sub(r"\[\s*عدل\s*\]", "", t)
    return re.sub(r"\n\s*\n+", "\n\n", t).strip()
def subpages(title):
    out, cont = [], {}
    while True:
        d = get({"action": "query", "list": "allpages", "apprefix": title + "/", "apnamespace": 0, "aplimit": 500, **cont})
        out += [p["title"] for p in d["query"]["allpages"]]
        if "continue" not in d: return out
        cont = d["continue"]
outdir = sys.argv[1]
for arg in sys.argv[2:]:
    title, slug = arg.split("|")
    parts = [page_text(title)]
    subs = subpages(title)
    def key(t):
        m = re.search(r"(\d+)\s*$", t); return (0, int(m.group(1))) if m else (1, t)
    for s in sorted(subs, key=key):
        try: parts.append("\n\n" + s.split("/", 1)[1] + "\n" + page_text(s)); time.sleep(1.5)
        except Exception as e: print("skip", s, e)
    text = "\n".join(parts)
    open(os.path.join(outdir, slug + ".txt"), "w").write(text)
    print(f"{slug}: {len(text)} chars, {len(subs)} subpages, articles~{len(re.findall(r'(?:^|\n)\s*(?:ال)?مادة', text))}")
