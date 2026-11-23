# Split a cleaned law text into ~1800-char chunks (150 overlap, cut at paragraph/line/sentence boundaries, like the
# n8n Recursive Character Text Splitter) and print one SQL statement that inserts them into documents WITHOUT an
# embedding (keyword search finds them at once; scripts/embed backfill fills the vector later).
# Usage: insert_law_sql.py FILE "fileName shown to users" [source]
import sys, json
path, name = sys.argv[1], sys.argv[2]
source = sys.argv[3] if len(sys.argv) > 3 else "manual"
text = open(path, encoding="utf-8").read().strip()
SIZE, OVER = 1800, 150
chunks, i = [], 0
while i < len(text):
    end = min(i + SIZE, len(text))
    if end < len(text):
        cut = max(text.rfind(sep, i + SIZE // 2, end) for sep in ("\n\n", "\n", ". ", "، ", " "))
        if cut > i: end = cut
    chunks.append(text[i:end].strip())
    if end >= len(text): break
    i = max(end - OVER, i + 1)
rows = []
for n, c in enumerate(chunks, 1):
    meta = json.dumps({"userId": "public", "fileName": name, "source": source, "chunk": n, "embedding_pending": True}, ensure_ascii=False)
    assert "$c$" not in c and "$m$" not in meta
    rows.append(f"($c${c}$c$, $m${meta}$m$::jsonb)")
print(f"-- {name}: {len(chunks)} chunks\ninsert into documents (content, metadata) values\n" + ",\n".join(rows) + ";\nselect count(*) as rows from documents where metadata->>'fileName' = $m${name}$m$;")
