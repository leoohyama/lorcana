"""Pull a Wikipedia fame proxy (12-month article pageviews) for each Disney
character in the card set, as an EXOGENOUS demand-side signal to replace the
weak printing-count popularity proxy.

Character resolution is fuzzy: a name like "Angel" or "Basil" needs Disney
context to land on the right article. Strategy per character:
  1. manual override for known-tricky titles;
  2. else MediaWiki search biased with Disney context, accepting the first
     result whose summary reads as a Disney/animation character;
  3. else a plain search; else unmatched.
Every match records how it resolved and whether Disney was confirmed, so match
quality is auditable. Reports how many characters could not be found.

Output: characters_wikipedia.csv
"""

import re
import time
import urllib.parse
import urllib.request
import json
from pathlib import Path

import pandas as pd

HERE = Path(__file__).parent
UA = {"User-Agent": "lorcana-latent-pricing/1.0 (research; contact leoohyama12@gmail.com)"}
PV_START, PV_END = "2025070100", "2026063000"   # last 12 complete months
DISNEY_HINT = ("disney", "pixar", "animated", "walt disney", "lucasfilm", "marvel")
FILM_RE = re.compile(r"\(\d{4} film\)|film series|\(franchise\)|\bfilm\b", re.I)

# Known-tricky characters -> exact Wikipedia title (avoids wrong / generic hits)
OVERRIDES = {
    "Angel": "Angel (Lilo & Stitch)",
    "Captain Amelia": "Treasure Planet",
    "Archimedes": "The Sword in the Stone (film)",
    "Basil": "The Great Mouse Detective",
    "Arthur": "The Sword in the Stone (film)",
    "Beast": "Beast (Beauty and the Beast)",
    "Robin Hood": "Robin Hood (1973 film)",
    "Bolt": "Bolt (2008 film)",
    "Chip 'n' Dale": "Chip 'n' Dale",
    "Tramp": "Lady and the Tramp",
    "Max": "Max Goof",
    # fix wrong-franchise namesakes the scorer still grabbed
    "Pegasus": "Hercules (1997 film)",
    "Goliath": "Gargoyles (TV series)",
    "Gramma Tala": "Moana (2016 film)",
    "Lilo": "Lilo & Stitch (2002 film)",
    "Yen Sid": "Fantasia (1940 film)",
}


def classify(title: str, s: dict | None) -> str:
    """character page (own article) / list / film / other — the fame proxy is
    cleanest for 'character', noisier for the fallbacks."""
    if not s or s.get("type") == "disambiguation":
        return "disambig"
    desc = (s.get("description", "") or "").lower()
    if "character" in desc or "fictional" in desc:
        return "character"
    if title.startswith("List of"):
        return "list"
    if FILM_RE.search(title):
        return "film"
    return "other"


def _get(url: str):
    req = urllib.request.Request(url, headers=UA)
    with urllib.request.urlopen(req, timeout=20) as r:
        return json.load(r)


def summary(title: str) -> dict | None:
    try:
        return _get("https://en.wikipedia.org/api/rest_v1/page/summary/"
                    + urllib.parse.quote(title.replace(" ", "_"), safe=""))
    except Exception:
        return None


def search(query: str, n: int = 6) -> list[str]:
    url = ("https://en.wikipedia.org/w/api.php?action=query&list=search&format=json"
           f"&srlimit={n}&srsearch=" + urllib.parse.quote(query))
    try:
        return [h["title"] for h in _get(url)["query"]["search"]]
    except Exception:
        return []


def is_disney(s: dict | None) -> bool:
    if not s or s.get("type") == "disambiguation":
        return False
    text = (s.get("extract", "") + " " + s.get("description", "")).lower()
    return any(k in text for k in DISNEY_HINT)


def _score(title: str, s: dict | None) -> float:
    """Prefer an actual character page over a film/list/disambiguation hit."""
    if not s or s.get("type") == "disambiguation":
        return -100.0
    ptype = classify(title, s)
    return {"character": 10, "other": 2, "list": -3, "film": -5}.get(ptype, 0) \
        + (3 if is_disney(s) else 0)


def resolve(name: str) -> tuple[str | None, str, str]:
    """Return (wiki_title, method, page_type). Picks the best-scoring Disney
    candidate, preferring the character's own article over a film/list page."""
    if name in OVERRIDES:
        s = summary(OVERRIDES[name])
        return OVERRIDES[name], "override", classify(OVERRIDES[name], s)

    best, best_score, best_type = None, -1e9, "notfound"
    for cand in search(f"{name} Disney character") + search(name):
        if cand == best:
            continue
        s = summary(cand)
        sc = _score(cand, s)
        # require some Disney signal so we don't grab an unrelated namesake
        if sc > best_score and (is_disney(s) or classify(cand, s) == "character"):
            best, best_score, best_type = cand, sc, classify(cand, s)
    method = "search" if best else "notfound"
    return best, method, best_type


def pageviews_12mo(title: str) -> int | None:
    t = urllib.parse.quote(title.replace(" ", "_"), safe="")
    url = ("https://wikimedia.org/api/rest_v1/metrics/pageviews/per-article/"
           f"en.wikipedia/all-access/user/{t}/monthly/{PV_START}/{PV_END}")
    try:
        return sum(item["views"] for item in _get(url)["items"])
    except Exception:
        return None


def character_names() -> list[str]:
    names = pd.read_csv(HERE / "card_names.csv")
    tab = pd.read_parquet(HERE.parents[1] / "data/tabular/ready_for_pytorch.parquet")
    chars = names.merge(tab[["id", "is_character"]], on="id")
    chars = chars[chars.is_character == 1]
    return sorted(chars.name.dropna().unique())


def main():
    chars = character_names()
    print(f"resolving {len(chars)} unique Disney characters on Wikipedia...")
    rows = []
    for i, name in enumerate(chars, 1):
        title, method, ptype = resolve(name)
        views = pageviews_12mo(title) if title else None
        rows.append({"character": name, "wiki_title": title, "method": method,
                     "page_type": ptype, "pageviews_12mo": views})
        flag = {"character": ""}.get(ptype, f"  <-- {ptype}")
        print(f"  [{i:3d}/{len(chars)}] {name:22s} -> {str(title):42s} "
              f"{'' if views is None else format(views, ',')}{flag}")
        time.sleep(0.05)

    df = pd.DataFrame(rows)
    import math
    df["log_pageviews"] = df.pageviews_12mo.apply(
        lambda v: None if pd.isna(v) or v <= 0 else math.log(v))
    df.to_csv(HERE / "characters_wikipedia.csv", index=False)

    found = df.wiki_title.notna()
    print("\n=== coverage ===")
    print(f"characters:            {len(df)}")
    print(f"matched to a page:     {found.sum()} ({found.mean():.0%})")
    print(f"NOT found:             {(~found).sum()}"
          + ("  " + ", ".join(df[~found].character) if (~found).any() else ""))
    print("\nmatch quality (page type resolved to):")
    print(df.page_type.value_counts().to_string())
    print("  character = own article (clean fame); film/list/other = noisier fallback")
    print("\nnon-character-page matches to review:")
    review = df[found & (df.page_type != "character")]
    print(review[["character", "wiki_title", "page_type"]].to_string(index=False))
    print("\ntop by pageviews:")
    print(df.dropna(subset=["pageviews_12mo"]).nlargest(12, "pageviews_12mo")[
        ["character", "wiki_title", "page_type", "pageviews_12mo"]].to_string(index=False))


if __name__ == "__main__":
    main()
