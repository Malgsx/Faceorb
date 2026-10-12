# Usage: python3 fetch_pixieset.py <share-link> <out-dir>   (pip install httpx)
import re, json, sys, time, concurrent.futures as cf
from pathlib import Path
from urllib.parse import urlparse
import httpx
url, dest = sys.argv[1], Path(sys.argv[2]); dest.mkdir(parents=True, exist_ok=True)
h = httpx.Client(follow_redirects=True, timeout=30, headers={"User-Agent": "FaceOrb-prototype/0.1"})
p = h.get(url); html = p.text
cuk = re.search(r"'collectionUrlKey':'([^']+)'", html).group(1)
base = f"{urlparse(str(p.url)).scheme}://{urlparse(str(p.url)).netloc}"
cid = re.search(r"'collectionId':(\d+)", html)
if not cid:
    html = h.get(f"{base}/{cuk}/").text; cid = re.search(r"'collectionId':(\d+)", html)
cid = cid.group(1)
seg = html.split("'allGalleries':", 1)[-1].split("]", 1)[0]
slugs = re.findall(r"'slug':'([^']+)'", seg) or ["photos"]
print("base", base, "cuk", cuk, "cid", cid, "slugs", slugs)
items = []
for gs in slugs:
    r = h.get(f"{base}/client/loadphotos/", params={"cuk": cuk, "cid": cid, "gs": gs, "page": 0, "all": 1}, headers={"X-Requested-With": "XMLHttpRequest"})
    items += json.loads(r.json()["content"] or "[]")
print(len(items), "photos"); print(json.dumps(items[0])[:800])
(dest/"listing.json").write_text(json.dumps(items))
def get(it):
    out = dest/f"{it['id']}.jpg"
    if not out.exists():
        out.write_bytes(h.get("https:" + (it.get("pathXxlarge") or it["pathXlarge"])).content); time.sleep(0.1)
with cf.ThreadPoolExecutor(4) as ex: list(ex.map(get, items))
print("done")
