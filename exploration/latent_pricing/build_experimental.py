"""Assemble the per-card dataset for the Experimental Quarto page and write
`experimental.qmd` (self-contained: data embedded inline, no DB dependency, so
the daily site render stays fast and never touches MotherDuck).

Run after the pipeline: reconcile -> latent_pipeline -> viz -> this.
Output: ../../experimental.qmd  (renders to docs/experimental.html)
"""

import json
import re
from pathlib import Path

import numpy as np
import pandas as pd

HERE = Path(__file__).parent
ROOT = HERE.parents[1]
folder = lambda s: re.sub(r"[ ']", "_", str(s))


def clean_rvec(s):
    """R stringifies list-columns as c("a","b") or character(0); tidy to a
    plain comma-joined string (or None when empty)."""
    if pd.isna(s):
        return None
    s = str(s)
    if s in ("character(0)", "NA", "list()", ""):
        return None
    toks = re.findall(r'"([^"]*)"', s)
    if toks:
        return ", ".join(toks)
    s = re.sub(r'^c\(|\)$|["\'\[\]]', "", s).strip()
    return s or None


def assemble() -> list[dict]:
    mis = pd.read_csv(HERE / "mispricing_deltas.csv")
    tv = pd.read_parquet(HERE / "true_value.parquet")
    obs = pd.read_parquet(HERE / "listing_observations.parquet")
    stats = pd.read_csv(HERE / "card_raw_stats.csv")
    wiki = pd.read_csv(HERE / "characters_wikipedia.csv")
    names = pd.read_csv(HERE / "card_names.csv")

    ebay_med = obs[obs.tier == "raw"].groupby("card_id").price.median().rename("ebay_raw_median")
    jt = obs[obs.tier == "justtcg"].set_index("card_id").price.rename("justtcg")
    rel = names.set_index("id").released_at
    days = (pd.Timestamp.now().normalize() - pd.to_datetime(rel)).dt.days

    df = (mis
          .merge(tv[["card_id", "n_obs", "n_raw", "n_graded", "graded_adj_log",
                     "value_tier"]], left_on="id", right_on="card_id", how="left")
          .merge(stats, on="id", how="left")
          .merge(ebay_med, left_on="id", right_index=True, how="left")
          .merge(jt, left_on="id", right_index=True, how="left")
          .merge(wiki[["character", "wiki_title", "page_type", "pageviews_12mo"]],
                 left_on="name", right_on="character", how="left"))
    df["days_since_release"] = df.id.map(days)
    df["released_at"] = df.id.map(rel)
    df["image"] = df.apply(lambda r: f"data/enchanteds/images/{folder(r.set_name)}/{r.id}.avif", axis=1)
    df["grade_premium_mult"] = np.exp(df.graded_adj_log.fillna(0))

    def rec(r):
        g = lambda v: None if pd.isna(v) else v
        return {
            # r["name"] not r.name: Series.name is the row index, not the column
            "id": r.id, "name": r["name"], "version": g(r.version), "set": r.set_name,
            "rarity": r.rarity, "image": r.image, "released": g(r.released_at),
            "days_since_release": g(r.days_since_release),
            # raw card stats (interpretable units)
            "cost": g(r.cost), "strength": g(r.strength), "willpower": g(r.willpower),
            "lore": g(r.lore), "ink": g(r.ink), "type": g(r.type_clean),
            "keywords": clean_rvec(r.keywords), "classifications": clean_rvec(r.classifications),
            "illustrator": clean_rvec(r.illustrators), "flavor": g(r.flavor_text),
            # pricing (USD)
            "true_value": round(float(r.true_value_usd), 2),
            "fair_value": round(float(r.fair_char_usd), 2),
            "justtcg": None if pd.isna(r.justtcg) else round(float(r.justtcg), 2),
            "ebay_median": None if pd.isna(r.ebay_raw_median) else round(float(r.ebay_raw_median), 2),
            "mispricing_pct": round(float(r.mispricing_pct), 4),
            "fame_premium_pct": round(float(np.expm1(r.fame_premium)), 4),
            # reconciliation provenance
            "n_listings": int(r.n_obs) if pd.notna(r.n_obs) else 0,
            "n_raw": int(r.n_raw) if pd.notna(r.n_raw) else 0,
            "n_graded": int(r.n_graded) if pd.notna(r.n_graded) else 0,
            "grade_premium_mult": round(float(r.grade_premium_mult), 2),
            "value_tier": g(r.value_tier),
            # wikipedia
            "wiki_title": g(r.wiki_title), "wiki_page_type": g(r.page_type),
            "wiki_pageviews": None if pd.isna(r.pageviews_12mo) else int(r.pageviews_12mo),
        }

    return [rec(r) for _, r in df.iterrows()]


QMD = r'''---
title: ""
pagetitle: "Lorecaster · Fair Value Lab"
format:
  html:
    theme: darkly
    page-layout: full
    toc: false
    include-in-header: google-analytics.html
resources:
  - "data/enchanteds/images/"
  - "lorecaster_logo.png"
---

{{< include _styles.qmd >}}

```{=html}
<style>
  /* Force the dark ground always (Quarto ships a light bootstrap variant that
     activates under prefers-color-scheme: light; this page is dark-only to
     match the main dashboard). Set explicit text color so nothing inherits
     the light theme's dark body text onto our dark cards. */
  :root { color-scheme: dark; }
  body, .quarto-container, main, #quarto-content, .page-columns {
    background-color: var(--bg-base) !important; }
  .fv-wrap { max-width: 1400px; margin: 0 auto; color: var(--text-main); }
  .fv-wrap h2, .fv-wrap h3, .fv-wrap h4 { color: var(--text-main); }
  .fv-top { display:flex; align-items:center; gap:16px; padding:10px 4px 20px; flex-wrap:wrap; }
  .fv-top img { height:56px; }
  .fv-badge { font-size:12px; font-weight:800; letter-spacing:1px; text-transform:uppercase;
    color:#fff; background:linear-gradient(135deg,var(--accent-purple),var(--accent-blue));
    padding:5px 12px; border-radius:999px; }
  .fv-back { margin-left:auto; color:var(--brand); font-weight:700; text-decoration:none; font-size:14px; }
  .fv-back:hover { text-decoration:underline; }
  .fv-h1 { font-size:26px; font-weight:800; margin:0; color:var(--text-main); }

  .fv-defs { display:grid; grid-template-columns:repeat(3,1fr); gap:16px; margin-bottom:14px; }
  @media(max-width:820px){ .fv-defs{ grid-template-columns:1fr; } }
  .fv-def { background:var(--bg-card); border:1px solid var(--border-subtle); border-radius:12px;
    padding:16px 18px; border-top:4px solid var(--border-subtle); }
  .fv-def h3 { margin:0 0 6px; font-size:14px; font-weight:800; text-transform:uppercase; letter-spacing:.5px; }
  .fv-def p { margin:0; color:var(--text-muted); font-size:13px; line-height:1.55; }
  .fv-def.tv h3 { color:var(--price); } .fv-def.tv { border-top-color:var(--price); }
  .fv-def.fv h3 { color:var(--brand); } .fv-def.fv { border-top-color:var(--brand); }
  .fv-def.mp h3 { color:var(--accent-purple); } .fv-def.mp { border-top-color:var(--accent-purple); }
  .fv-disclaim { background:rgba(192,132,252,.08); border:1px solid var(--accent-purple);
    border-radius:10px; padding:11px 16px; font-size:12.5px; color:var(--text-muted); margin-bottom:22px; }
  .fv-disclaim b { color:var(--accent-purple); }

  .fv-controls { display:flex; gap:12px; margin-bottom:12px; flex-wrap:wrap; }
  .fv-controls input, .fv-controls select { background:var(--bg-card); border:1px solid var(--border-subtle);
    color:var(--text-main); padding:9px 13px; border-radius:9px; font-family:'Inter',sans-serif; font-size:14px; }
  .fv-controls input { flex:1; min-width:180px; }

  .fv-split { display:grid; grid-template-columns:390px 1fr; gap:18px; }
  @media(max-width:900px){ .fv-split{ grid-template-columns:1fr; } }
  .fv-list { background:var(--bg-card); border:1px solid var(--border-subtle); border-radius:12px;
    max-height:78vh; overflow-y:auto; }
  .fv-row { display:grid; grid-template-columns:38px 1fr auto; gap:11px; align-items:center;
    padding:9px 13px; border-bottom:1px solid var(--border-subtle); cursor:pointer; }
  .fv-row:hover { background:var(--bg-hover); }
  .fv-row.sel { background:var(--bg-hover); box-shadow:inset 4px 0 0 var(--brand); }
  .fv-row img { width:38px; border-radius:4px; }
  .fv-row .nm { font-size:13px; color:var(--text-main); line-height:1.25; }
  .fv-row .nm small { color:var(--text-muted); display:block; font-size:11px; }
  .fv-chip { font-family:'Inter'; font-weight:800; font-size:12.5px; text-align:right; white-space:nowrap; }

  .fv-detail { background:var(--bg-card); border:1px solid var(--border-subtle); border-radius:12px; padding:22px; }
  .fv-dhead { display:grid; grid-template-columns:150px 1fr; gap:20px; }
  @media(max-width:560px){ .fv-dhead{ grid-template-columns:1fr; } }
  .fv-dhead img { width:100%; border-radius:10px; box-shadow:0 8px 20px rgba(0,0,0,.5); }
  .fv-title { font-size:22px; font-weight:800; margin:0; color:var(--text-main); }
  .fv-sub { color:var(--text-muted); font-size:14px; margin:2px 0 10px; }
  .fv-meta { display:flex; flex-wrap:wrap; gap:6px; margin-bottom:8px; }
  .fv-tag { font-size:11px; font-weight:700; padding:3px 9px; border-radius:999px;
    background:var(--bg-base); border:1px solid var(--border-subtle); color:var(--text-muted); }

  .fv-gauges { display:grid; grid-template-columns:1.2fr 1fr; gap:18px; margin:20px 0; }
  @media(max-width:680px){ .fv-gauges{ grid-template-columns:1fr; } }
  .fv-panel { background:var(--bg-base); border:1px solid var(--border-subtle); border-radius:10px; padding:16px; }
  .fv-panel h4 { margin:0 0 10px; font-size:12px; font-weight:800; text-transform:uppercase;
    letter-spacing:.5px; color:var(--text-muted); }
  .fv-bignum { font-size:30px; font-weight:800; font-variant-numeric:tabular-nums; }

  .fv-bars { display:flex; flex-direction:column; gap:9px; }
  .fv-bar { display:grid; grid-template-columns:80px 1fr auto; gap:9px; align-items:center; font-size:13px; }
  .fv-bar .lb { color:var(--text-muted); }
  .fv-track { height:10px; background:var(--bg-card); border-radius:5px; overflow:hidden; }
  .fv-fill { height:100%; border-radius:5px; }
  .fv-bar .vl { font-weight:700; font-variant-numeric:tabular-nums; }

  .fv-stats { display:grid; grid-template-columns:repeat(4,1fr); gap:12px; margin:18px 0; }
  @media(max-width:560px){ .fv-stats{ grid-template-columns:repeat(2,1fr); } }
  .fv-dial { text-align:center; }
  .fv-dial .cap { font-size:11px; color:var(--text-muted); text-transform:uppercase; font-weight:700; margin-top:4px; }

  .fv-facts { display:grid; grid-template-columns:1fr 1fr; gap:10px 22px; margin:16px 0; }
  @media(max-width:560px){ .fv-facts{ grid-template-columns:1fr; } }
  .fv-fact { display:flex; justify-content:space-between; gap:12px; font-size:13px;
    border-bottom:1px solid var(--border-subtle); padding:6px 0; }
  .fv-fact .k { color:var(--text-muted); } .fv-fact .v { color:var(--text-main); font-weight:600; text-align:right; }
  .fv-flavor { font-style:italic; color:var(--text-muted); font-size:13px; border-left:3px solid var(--border-subtle);
    padding:6px 0 6px 12px; margin-top:14px; }
  .fv-secttl { font-size:12px; font-weight:800; text-transform:uppercase; letter-spacing:.5px;
    color:var(--brand); margin:18px 0 8px; border-bottom:1px solid var(--border-subtle); padding-bottom:6px; }
</style>

<div class="fv-wrap">
  <div class="fv-top">
    <img src="lorecaster_logo.png" alt="Lorecaster">
    <div>
      <div class="fv-h1">Fair Value Lab</div>
      <span class="fv-badge">Experimental</span>
    </div>
    <a class="fv-back" href="index.html">&larr; Back to Dashboard</a>
  </div>

  <div class="fv-defs">
    <div class="fv-def tv"><h3>True Value</h3><p>What the card is <b>really worth today</b>, reconciled
      from every live price signal &mdash; eBay raw &amp; graded asks and the JustTCG market &mdash; into one
      figure. Grading premiums are divided back out and inflated asks discounted, so it reads as a realized,
      raw-card price.</p></div>
    <div class="fv-def fv"><h3>Fair Value</h3><p>What the card <b>should be worth</b> given only its own
      characteristics &mdash; art, stats, rarity, set, demand and character fame &mdash; learned from every
      other card. It ignores the card's own price, so it's an independent second opinion.</p></div>
    <div class="fv-def mp"><h3>Mispricing</h3><p><b>True &divide; Fair &minus; 1.</b> Positive (red) = the market
      pays <b>above</b> what the card's traits justify; negative (blue) = it trades <b>below</b>. A read on
      dislocation, not a guaranteed trade.</p></div>
  </div>
  <div class="fv-disclaim"><b>Experimental &mdash;</b> a research view of a latent-pricing model, not investment
    advice. "Fair value" is a statistical estimate with real uncertainty; treat large gaps as questions to
    investigate, not signals to act on. Static snapshot as of __SNAPSHOT__ (the main dashboard is live).</div>

  <div class="fv-controls">
    <input id="fv-search" placeholder="Search a card or character&hellip;">
    <select id="fv-sort">
      <option value="mis_under">Sort: most underpriced</option>
      <option value="mis_over">Sort: most overpriced</option>
      <option value="value">Sort: highest true value</option>
      <option value="name">Sort: name (A&ndash;Z)</option>
    </select>
  </div>

  <div class="fv-split">
    <div class="fv-list" id="fv-list"></div>
    <div class="fv-detail" id="fv-detail"></div>
  </div>
</div>

<script>
const FVDATA = __DATA__;
const usd = v => v==null ? "&mdash;" : "$" + (v>=1000 ? Math.round(v).toLocaleString()
  : v>=100 ? Math.round(v) : v.toFixed(v<10?2:1));
const pct = v => (v>=0?"+":"") + Math.round(v*100) + "%";
const misColor = v => v==null ? "var(--text-muted)"
  : v>0.02 ? "var(--neg)" : v<-0.02 ? "var(--brand)" : "var(--text-muted)";

// diverging semicircle gauge for mispricing (blue under <- -> red over)
function misGauge(pctVal){
  const lim=0.6, t=Math.max(-1,Math.min(1,(pctVal||0)/lim));
  const ang=Math.PI*(1-(t+1)/2);           // -lim -> pi (left), +lim -> 0 (right)
  const cx=110,cy=110,r=82,nx=cx+r*Math.cos(ang),ny=cy-r*Math.sin(ang);
  const col=misColor(pctVal);
  return `<svg viewBox="0 0 220 132" width="100%" style="max-width:260px">
    <defs><linearGradient id="fvg" x1="0" x2="1">
      <stop offset="0" stop-color="#2a6fd6"/><stop offset="0.5" stop-color="#64748b"/>
      <stop offset="1" stop-color="#e2564f"/></linearGradient></defs>
    <path d="M 28 110 A 82 82 0 0 1 192 110" fill="none" stroke="url(#fvg)" stroke-width="16" stroke-linecap="round"/>
    <line x1="${cx}" y1="${cy}" x2="${nx.toFixed(1)}" y2="${ny.toFixed(1)}" stroke="var(--text-main)" stroke-width="3.5" stroke-linecap="round"/>
    <circle cx="${cx}" cy="${cy}" r="6" fill="var(--text-main)"/>
    <text x="28" y="128" fill="var(--brand)" font-size="10" font-weight="700">UNDER</text>
    <text x="165" y="128" fill="var(--neg)" font-size="10" font-weight="700">OVER</text>
    <text x="${cx}" y="150" text-anchor="middle" fill="${col}" font-size="24" font-weight="800" font-family="Inter">${pct(pctVal)}</text>
  </svg>`;
}
// small radial stat dial (0..max)
function statDial(val,max,label){
  if(val==null) return `<div class="fv-dial"><svg viewBox="0 0 70 70" width="62"><circle cx="35" cy="35" r="28" fill="none" stroke="var(--bg-card)" stroke-width="7"/></svg><div class="cap">${label} &mdash;</div></div>`;
  const frac=Math.max(0,Math.min(1,val/max)), C=2*Math.PI*28, off=C*(1-frac);
  return `<div class="fv-dial"><svg viewBox="0 0 70 70" width="62">
    <circle cx="35" cy="35" r="28" fill="none" stroke="var(--bg-card)" stroke-width="7"/>
    <circle cx="35" cy="35" r="28" fill="none" stroke="var(--brand)" stroke-width="7" stroke-linecap="round"
      stroke-dasharray="${C.toFixed(1)}" stroke-dashoffset="${off.toFixed(1)}" transform="rotate(-90 35 35)"/>
    <text x="35" y="41" text-anchor="middle" fill="var(--text-main)" font-size="20" font-weight="800" font-family="Inter">${val}</text>
  </svg><div class="cap">${label}</div></div>`;
}
function priceBars(d){
  const rows=[["True value",d.true_value,"var(--price)"],["Fair value",d.fair_value,"var(--brand)"],
    ["JustTCG",d.justtcg,"var(--series-ebay)"],["eBay median",d.ebay_median,"var(--text-muted)"]];
  const mx=Math.max(...rows.map(r=>r[1]||0))||1;
  return rows.map(([l,v,c])=>`<div class="fv-bar"><span class="lb">${l}</span>
    <span class="fv-track"><span class="fv-fill" style="width:${v?Math.max(3,100*v/mx):0}%;background:${c}"></span></span>
    <span class="vl">${usd(v)}</span></div>`).join("");
}
function fact(k,v){ return v==null||v===""?"":`<div class="fv-fact"><span class="k">${k}</span><span class="v">${v}</span></div>`; }

function renderDetail(d){
  const el=document.getElementById("fv-detail");
  const kw=(d.keywords&&d.keywords!=="NA")?d.keywords.replace(/[\[\]']/g,""):"";
  const cls=(d.classifications&&d.classifications!=="NA")?d.classifications.replace(/[\[\]']/g,""):"";
  el.innerHTML=`
    <div class="fv-dhead">
      <img src="${d.image}" alt="${d.name}" loading="lazy"
        onerror="this.style.visibility='hidden'">
      <div>
        <h2 class="fv-title">${d.name}</h2>
        <div class="fv-sub">${d.version||""}</div>
        <div class="fv-meta">
          <span class="fv-tag">${d.rarity}</span>
          <span class="fv-tag">${d.set}</span>
          ${d.ink?`<span class="fv-tag">${d.ink}</span>`:""}
          ${d.type?`<span class="fv-tag">${d.type}</span>`:""}
          ${d.days_since_release!=null?`<span class="fv-tag">${d.days_since_release}d since release</span>`:""}
        </div>
        <div class="fv-stats">
          ${statDial(d.cost,10,"Cost")}${statDial(d.strength,10,"Strength")}
          ${statDial(d.willpower,10,"Willpower")}${statDial(d.lore,5,"Lore")}
        </div>
      </div>
    </div>

    <div class="fv-gauges">
      <div class="fv-panel" style="text-align:center">
        <h4>Mispricing vs fair value</h4>
        ${misGauge(d.mispricing_pct)}
        <div style="color:var(--text-muted);font-size:12px;margin-top:8px">
          True ${usd(d.true_value)} vs fair ${usd(d.fair_value)}</div>
      </div>
      <div class="fv-panel">
        <h4>Price signals</h4>
        <div class="fv-bars">${priceBars(d)}</div>
      </div>
    </div>

    <div class="fv-secttl">How true value was reconciled</div>
    <div class="fv-facts">
      ${fact("Live listings used",d.n_listings)}
      ${fact("Raw / graded",`${d.n_raw} / ${d.n_graded}`)}
      ${fact("This card's grade premium",d.grade_premium_mult?d.grade_premium_mult+"&times; the ladder":null)}
      ${fact("Value tier (ask-inflation band)",d.value_tier)}
    </div>

    <div class="fv-secttl">Character fame (Wikipedia)</div>
    <div class="fv-facts">
      ${fact("Article",d.wiki_title||"&mdash; (non-character card)")}
      ${fact("12-mo pageviews",d.wiki_pageviews!=null?d.wiki_pageviews.toLocaleString():null)}
      ${fact("Match quality",d.wiki_page_type?(d.wiki_page_type==="character"?"own character page":d.wiki_page_type+" page (noisier)"):null)}
      ${fact("Fame premium (model)",d.fame_premium_pct?pct(d.fame_premium_pct):null)}
    </div>

    ${(kw||cls||d.illustrator)?`<div class="fv-secttl">Card details</div><div class="fv-facts">
      ${fact("Keywords",kw)}${fact("Classifications",cls)}${fact("Illustrator",d.illustrator)}</div>`:""}
    ${d.flavor&&d.flavor!=="NA"?`<div class="fv-flavor">${d.flavor}</div>`:""}`;
}

let selected=null;
function renderList(){
  const q=document.getElementById("fv-search").value.toLowerCase();
  const sort=document.getElementById("fv-sort").value;
  let rows=FVDATA.filter(d=>(d.name+" "+(d.version||"")).toLowerCase().includes(q));
  const cmp={mis_under:(a,b)=>a.mispricing_pct-b.mispricing_pct,
    mis_over:(a,b)=>b.mispricing_pct-a.mispricing_pct,
    value:(a,b)=>b.true_value-a.true_value,
    name:(a,b)=>a.name.localeCompare(b.name)}[sort];
  rows.sort(cmp);
  document.getElementById("fv-list").innerHTML=rows.map(d=>`
    <div class="fv-row ${selected&&selected.id===d.id?'sel':''}" data-id="${d.id}">
      <img src="${d.image}" loading="lazy" onerror="this.style.visibility='hidden'">
      <span class="nm">${d.name}<small>${d.version||""}</small></span>
      <span class="fv-chip" style="color:${misColor(d.mispricing_pct)}">${pct(d.mispricing_pct)}</span>
    </div>`).join("");
  document.querySelectorAll(".fv-row").forEach(r=>r.onclick=()=>{
    selected=FVDATA.find(d=>d.id===r.dataset.id); renderDetail(selected); renderList();
  });
}
document.getElementById("fv-search").oninput=renderList;
document.getElementById("fv-sort").onchange=renderList;
selected=[...FVDATA].sort((a,b)=>a.mispricing_pct-b.mispricing_pct)[0];
renderList(); renderDetail(selected);
</script>
```
'''


def write_qmd():
    data = assemble()
    out = (QMD.replace("__DATA__", json.dumps(data))
              .replace("__SNAPSHOT__", pd.Timestamp.now().strftime("%b %-d, %Y")))
    (ROOT / "experimental.qmd").write_text(out)
    print(f"wrote experimental.qmd ({len(out):,} bytes, {len(data)} cards)")


if __name__ == "__main__":
    write_qmd()
