"""Assemble the self-contained interactive dashboard (latent_dashboard.html)
from latent_dashboard_data.json. Regenerate after any pipeline rerun.
"""
import json
from pathlib import Path

import numpy as np

HERE = Path(__file__).parent
data = json.loads((HERE / "latent_dashboard_data.json").read_text())

# context stats for the header tiles
ratios = [d["ebay_raw_median"] / d["true_value_usd"]
          for d in data if d.get("ebay_raw_median")]
ctx = {
    "n_cards": len(data),
    "ask_inflation": round(float(np.median(ratios)), 2),
    "oof_r2": 0.72,       # full + character-fame model, from latent_pipeline.py
    "psa10_mult": 7.1,    # from premium_ladder.csv
}

HTML = r"""<title>Lorcana Latent Pricing</title>
<style>
  :root {
    --bg: #f6f7f9; --panel: #ffffff; --ink: #12151c; --ink-2: #565d6b;
    --muted: #878e9c; --line: #e5e8ee; --line-2: #d3d8e1;
    --neutral-pt: #cdd2da;           /* diverging midpoint on this ground */
    --pole-lo: #1f5fb0; --pole-hi: #cf3b3a;
    --accent: #2a6ff0; --focus: #2a6ff0;
    --shadow: 0 1px 2px rgba(18,21,28,.06), 0 8px 24px rgba(18,21,28,.06);
    --mono: ui-monospace, "SF Mono", "Menlo", "Cascadia Code", monospace;
    --sans: system-ui, -apple-system, "Segoe UI", sans-serif;
  }
  @media (prefers-color-scheme: dark) {
    :root {
      --bg: #0f1218; --panel: #171b23; --ink: #eef1f6; --ink-2: #a6adbc;
      --muted: #6d7484; --line: #242a34; --line-2: #2f3641;
      --neutral-pt: #3a414d; --pole-lo: #4b91ec; --pole-hi: #e2605e;
      --accent: #4b91ec; --focus: #4b91ec;
      --shadow: 0 1px 2px rgba(0,0,0,.4), 0 10px 30px rgba(0,0,0,.35);
    }
  }
  :root[data-theme="light"] {
    --bg: #f6f7f9; --panel: #ffffff; --ink: #12151c; --ink-2: #565d6b;
    --muted: #878e9c; --line: #e5e8ee; --line-2: #d3d8e1;
    --neutral-pt: #cdd2da; --pole-lo: #1f5fb0; --pole-hi: #cf3b3a;
    --accent: #2a6ff0; --focus: #2a6ff0;
    --shadow: 0 1px 2px rgba(18,21,28,.06), 0 8px 24px rgba(18,21,28,.06);
  }
  :root[data-theme="dark"] {
    --bg: #0f1218; --panel: #171b23; --ink: #eef1f6; --ink-2: #a6adbc;
    --muted: #6d7484; --line: #242a34; --line-2: #2f3641;
    --neutral-pt: #3a414d; --pole-lo: #4b91ec; --pole-hi: #e2605e;
    --accent: #4b91ec; --focus: #4b91ec;
    --shadow: 0 1px 2px rgba(0,0,0,.4), 0 10px 30px rgba(0,0,0,.35);
  }

  * { box-sizing: border-box; }
  body { margin: 0; }
  .wrap {
    font-family: var(--sans); background: var(--bg); color: var(--ink);
    min-height: 100vh; padding: clamp(16px, 3vw, 34px);
    max-width: 1280px; margin: 0 auto;
  }
  .eyebrow {
    font-size: 11px; letter-spacing: .14em; text-transform: uppercase;
    color: var(--muted); font-weight: 600;
  }
  h1 { font-size: clamp(22px, 3vw, 30px); margin: 6px 0 4px; letter-spacing: -.01em;
       text-wrap: balance; font-weight: 650; }
  .sub { color: var(--ink-2); font-size: 14px; max-width: 62ch; line-height: 1.5; margin: 0; }

  .tiles { display: flex; flex-wrap: wrap; gap: 10px; margin: 20px 0 8px; }
  .tile {
    background: var(--panel); border: 1px solid var(--line); border-radius: 10px;
    padding: 12px 16px; box-shadow: var(--shadow); flex: 1 1 130px;
  }
  .tile .k { font-size: 11px; color: var(--muted); letter-spacing: .04em;
             text-transform: uppercase; }
  .tile .v { font-family: var(--mono); font-size: 21px; font-weight: 600;
             margin-top: 3px; font-variant-numeric: tabular-nums; }

  .toolbar { display: flex; align-items: center; gap: 14px; flex-wrap: wrap;
             margin: 18px 0 12px; }
  .seg { display: inline-flex; background: var(--panel); border: 1px solid var(--line);
         border-radius: 9px; padding: 3px; box-shadow: var(--shadow); }
  .seg button {
    font-family: var(--sans); font-size: 13px; font-weight: 550; color: var(--ink-2);
    background: transparent; border: 0; padding: 7px 14px; border-radius: 7px;
    cursor: pointer;
  }
  .seg button[aria-pressed="true"] { background: var(--accent); color: #fff; }
  .seg button:focus-visible { outline: 2px solid var(--focus); outline-offset: 2px; }

  .legend { display: flex; align-items: center; gap: 8px; font-size: 12px;
            color: var(--ink-2); margin-left: auto; }
  .legend .bar { width: 150px; height: 8px; border-radius: 4px;
    background: linear-gradient(90deg, var(--pole-lo), var(--neutral-pt), var(--pole-hi)); }

  .stage { display: grid; grid-template-columns: 1fr 300px; gap: 16px; }
  @media (max-width: 780px) { .stage { grid-template-columns: 1fr; } }
  .card {
    background: var(--panel); border: 1px solid var(--line); border-radius: 12px;
    box-shadow: var(--shadow);
  }
  .plotwrap { position: relative; padding: 10px; }
  canvas { display: block; width: 100%; height: 460px; border-radius: 8px; }
  .axhint { position: absolute; left: 18px; bottom: 16px; font-size: 11px;
            color: var(--muted); font-family: var(--mono); pointer-events: none; }
  .tip {
    position: absolute; pointer-events: none; opacity: 0; transition: opacity .1s;
    background: var(--ink); color: var(--bg); font-size: 12px; padding: 5px 8px;
    border-radius: 6px; font-family: var(--mono); white-space: nowrap; transform: translate(-50%, -140%);
    z-index: 5;
  }

  .detail { padding: 16px; }
  .detail .rare { font-size: 11px; letter-spacing: .06em; text-transform: uppercase;
                  color: var(--muted); }
  .detail h2 { font-size: 17px; margin: 3px 0 1px; line-height: 1.2; }
  .detail .ver { color: var(--ink-2); font-size: 13px; margin-bottom: 14px; }
  .pill { display: inline-block; font-family: var(--mono); font-size: 12px; font-weight: 600;
          padding: 3px 9px; border-radius: 999px; margin-bottom: 16px; }

  .bars { display: flex; flex-direction: column; gap: 10px; }
  .barrow { display: grid; grid-template-columns: 74px 1fr auto; align-items: center; gap: 8px; }
  .barrow .lbl { font-size: 12px; color: var(--ink-2); }
  .track { height: 9px; background: var(--line); border-radius: 5px; overflow: hidden; }
  .fill { height: 100%; border-radius: 5px; }
  .barrow .amt { font-family: var(--mono); font-size: 12.5px; font-variant-numeric: tabular-nums; }
  .empty { color: var(--muted); font-size: 13px; line-height: 1.5; }

  .boards { display: grid; grid-template-columns: 1fr 1fr; gap: 16px; margin-top: 16px; }
  @media (max-width: 560px) { .boards { grid-template-columns: 1fr; } }
  .board { padding: 14px 16px; }
  .board h3 { font-size: 12px; letter-spacing: .04em; text-transform: uppercase;
              color: var(--muted); margin: 0 0 10px; font-weight: 600; }
  .row { display: grid; grid-template-columns: 1fr auto; gap: 8px; align-items: baseline;
         padding: 6px 0; border-top: 1px solid var(--line); cursor: pointer; }
  .row:hover .nm { color: var(--accent); }
  .row .nm { font-size: 13px; }
  .row .nm small { color: var(--muted); }
  .row .mp { font-family: var(--mono); font-size: 12.5px; font-variant-numeric: tabular-nums; }
  .foot { color: var(--muted); font-size: 12px; margin-top: 22px; line-height: 1.55; }
  .foot code { font-family: var(--mono); }
</style>

<div class="wrap">
  <div class="eyebrow">Lorcana · latent measurement model</div>
  <h1>Where cards sit in latent space — and where the market has them wrong</h1>
  <p class="sub">Each card's <strong>true value</strong> is reconciled from eBay raw &amp; graded
     asks and JustTCG, then positioned by its art + attributes + demand + character fame. Color is
     mispricing versus fundamentals — <span style="color:var(--pole-lo);font-weight:600">underpriced</span>
     to <span style="color:var(--pole-hi);font-weight:600">overpriced</span>. Point size is true value.</p>

  <div class="tiles" id="tiles"></div>

  <div class="toolbar">
    <div class="seg" role="group" aria-label="View">
      <button id="v-latent" aria-pressed="true">Latent space</button>
      <button id="v-naive" aria-pressed="false">True vs naive</button>
    </div>
    <div class="legend"><span>underpriced</span><span class="bar"></span><span>overpriced</span></div>
  </div>

  <div class="stage">
    <div class="card plotwrap">
      <canvas id="plot" aria-label="Card scatter plot"></canvas>
      <div class="axhint" id="axhint"></div>
      <div class="tip" id="tip"></div>
    </div>
    <div class="card detail" id="detail"></div>
  </div>

  <div class="boards">
    <div class="card board"><h3>Most underpriced vs fundamentals</h3><div id="under"></div></div>
    <div class="card board"><h3>Most overpriced vs fundamentals</h3><div id="over"></div></div>
  </div>

  <p class="foot">True value reconciled by a weighted fixed-effects model (JustTCG-anchored) with a
    per-card grading-premium ladder; fundamentals from a leave-one-out regression on frozen
    ResNet-50 art features + card attributes + demand. Mispricing = <code>true value ÷ fair value − 1</code>.
    A positive value means the market prices the card above what its characteristics justify.</p>
</div>

<script>
const DATA = __DATA__;
const CTX = __CTX__;

const cssVar = n => getComputedStyle(document.documentElement).getPropertyValue(n).trim();
const fmt = v => v == null ? "—" : "$" + (v >= 1000 ? Math.round(v).toLocaleString()
                : v >= 100 ? Math.round(v) : v.toFixed(v < 10 ? 2 : 1));
const pct = v => (v >= 0 ? "+" : "") + Math.round(v * 100) + "%";

// ---- color: diverging blue-neutral-red on delta_char (net of fame) ----
const LIM = (() => { const a = DATA.map(d => Math.abs(d.delta_char)).sort((x,y)=>x-y);
  return a[Math.floor(a.length*0.98)]; })();
function hexToRgb(h){h=h.replace('#','');return [parseInt(h.slice(0,2),16),parseInt(h.slice(2,4),16),parseInt(h.slice(4,6),16)];}
function mix(a,b,t){return a.map((v,i)=>Math.round(v+(b[i]-v)*t));}
function colorFor(delta){
  const lo=hexToRgb(cssVar('--pole-lo')), mid=hexToRgb(cssVar('--neutral-pt')), hi=hexToRgb(cssVar('--pole-hi'));
  let t = Math.max(-1, Math.min(1, delta / LIM));
  const rgb = t < 0 ? mix(mid, lo, -t) : mix(mid, hi, t);
  return `rgb(${rgb[0]},${rgb[1]},${rgb[2]})`;
}
const rOf = d => 3 + 9 * Math.sqrt(d.true_value_usd) / Math.sqrt(Math.max(...DATA.map(x=>x.true_value_usd)));

// ---- canvas plumbing ----
const cv = document.getElementById('plot'), ctx2 = cv.getContext('2d');
const tip = document.getElementById('tip'), axhint = document.getElementById('axhint');
let view = 'latent', W=0, H=0, pts=[], hovered=null, selected=null;
const PAD = 34;

function layout(){
  const rect = cv.getBoundingClientRect(); const dpr = window.devicePixelRatio || 1;
  W = rect.width; H = rect.height;
  cv.width = W*dpr; cv.height = H*dpr; ctx2.setTransform(dpr,0,0,dpr,0,0);
  let xs, ys, logAxis=false;
  if(view==='latent'){ xs = DATA.map(d=>d.umap_x); ys = DATA.map(d=>d.umap_y);
    axhint.textContent = 'UMAP structural embedding'; }
  else { xs = DATA.map(d=>Math.log(d.justtcg||d.true_value_usd)); ys = DATA.map(d=>Math.log(d.true_value_usd));
    logAxis=true; axhint.textContent = 'x: JustTCG (log)   ·   y: true value (log)'; }
  const xmin=Math.min(...xs), xmax=Math.max(...xs), ymin=Math.min(...ys), ymax=Math.max(...ys);
  const sx = v => PAD + (v-xmin)/(xmax-xmin) * (W-2*PAD);
  const sy = v => H-PAD - (v-ymin)/(ymax-ymin) * (H-2*PAD);
  pts = DATA.map((d,i)=>({d, x:sx(xs[i]), y:sy(ys[i]), r:rOf(d)}));
  pts._diag = logAxis ? {sx, sy, xmin, xmax, ymin, ymax} : null;
  draw();
}
function draw(){
  ctx2.clearRect(0,0,W,H);
  // diagonal for the naive view
  if(pts._diag){ const g=pts._diag; ctx2.strokeStyle=cssVar('--line-2'); ctx2.lineWidth=1;
    ctx2.setLineDash([5,4]);
    const lo=Math.max(g.xmin,g.ymin), hi=Math.min(g.xmax,g.ymax);
    ctx2.beginPath(); ctx2.moveTo(g.sx(lo),g.sy(lo)); ctx2.lineTo(g.sx(hi),g.sy(hi)); ctx2.stroke();
    ctx2.setLineDash([]); }
  for(const p of pts){ if(p.d===hovered||p.d===selected) continue; dot(p, .9); }
  for(const p of pts){ if(p.d===hovered||p.d===selected) dot(p, 1, true); }
}
function dot(p, alpha, ring){
  ctx2.globalAlpha = alpha; ctx2.beginPath();
  ctx2.arc(p.x, p.y, ring ? p.r+1.5 : p.r, 0, 7); ctx2.fillStyle = colorFor(p.d.delta_char);
  ctx2.fill();
  ctx2.globalAlpha = 1;
  ctx2.lineWidth = ring ? 2 : .6; ctx2.strokeStyle = ring ? cssVar('--ink') : cssVar('--panel');
  ctx2.stroke();
}
cv.addEventListener('mousemove', e=>{
  const rect = cv.getBoundingClientRect(), mx=e.clientX-rect.left, my=e.clientY-rect.top;
  let best=null, bd=1e9;
  for(const p of pts){ const dd=(p.x-mx)**2+(p.y-my)**2; if(dd<bd && dd<Math.max(p.r*p.r,80)){bd=dd;best=p;} }
  hovered = best ? best.d : null;
  if(best){ tip.style.opacity=1; tip.style.left=best.x+'px'; tip.style.top=best.y+'px';
    tip.textContent = `${best.d.name} · ${fmt(best.d.true_value_usd)} · ${pct(best.d.mispricing_pct)}`;
    showDetail(best.d); }
  else { tip.style.opacity=0; if(selected) showDetail(selected); }
  draw();
});
cv.addEventListener('mouseleave', ()=>{ hovered=null; tip.style.opacity=0;
  showDetail(selected); draw(); });
cv.addEventListener('click', ()=>{ selected = hovered; });

// ---- detail panel ----
function showDetail(d){
  const el = document.getElementById('detail');
  if(!d){ el.innerHTML = `<p class="empty">Hover a card to inspect its reconciled true value against
    the JustTCG and eBay-median estimates, and its mispricing versus fundamentals.</p>`; return; }
  const over = d.mispricing_pct >= 0;
  const pol = over ? cssVar('--pole-hi') : cssVar('--pole-lo');
  const vals = [["True value", d.true_value_usd, colorFor(d.delta_char)],
                ["JustTCG", d.justtcg, cssVar('--muted')],
                ["eBay median", d.ebay_raw_median, cssVar('--muted')],
                ["Fair value", d.fair_char_usd, cssVar('--accent')]];
  const mx = Math.max(...vals.map(v=>v[1]||0));
  el.innerHTML = `
    <div class="rare">${d.rarity} · ${d.set_name}</div>
    <h2>${d.name}</h2><div class="ver">${d.version||''}</div>
    <span class="pill" style="background:${pol}22;color:${pol}">
      ${over?'Overpriced':'Underpriced'} ${pct(d.mispricing_pct)} vs fundamentals</span>
    <div class="bars">${vals.map(([l,v,c])=>`
      <div class="barrow"><span class="lbl">${l}</span>
        <span class="track"><span class="fill" style="width:${v?Math.max(3,100*v/mx):0}%;background:${c}"></span></span>
        <span class="amt">${fmt(v)}</span></div>`).join('')}</div>`;
}

// ---- boards ----
function board(id, arr){
  document.getElementById(id).innerHTML = arr.map(d=>`
    <div class="row" data-name="${d.name}" data-version="${d.version||''}">
      <span class="nm">${d.name} <small>${d.version||''}</small></span>
      <span class="mp" style="color:${colorFor(d.delta_char)}">${pct(d.mispricing_pct)}</span></div>`).join('');
  document.querySelectorAll(`#${id} .row`).forEach(r=>r.addEventListener('click',()=>{
    selected = DATA.find(d=>d.name===r.dataset.name && (d.version||'')===r.dataset.version);
    hovered = selected; showDetail(selected); draw(); }));
}
const sorted = [...DATA].sort((a,b)=>a.mispricing_pct-b.mispricing_pct);
board('under', sorted.slice(0,6));
board('over', sorted.slice(-6).reverse());

// ---- tiles ----
document.getElementById('tiles').innerHTML = [
  ["Cards priced", CTX.n_cards],
  ["eBay ask inflation", CTX.ask_inflation + "×"],
  ["Fair-value fit  (OOF R²)", CTX.oof_r2],
  ["PSA 10 premium", CTX.psa10_mult + "×"],
].map(([k,v])=>`<div class="tile"><div class="k">${k}</div><div class="v">${v}</div></div>`).join('');

// ---- view toggle ----
function setView(v){ view=v;
  document.getElementById('v-latent').setAttribute('aria-pressed', v==='latent');
  document.getElementById('v-naive').setAttribute('aria-pressed', v==='naive');
  layout(); }
document.getElementById('v-latent').onclick=()=>setView('latent');
document.getElementById('v-naive').onclick=()=>setView('naive');

new ResizeObserver(layout).observe(cv);
matchMedia('(prefers-color-scheme: dark)').addEventListener('change', draw);
const mo = new MutationObserver(draw);
mo.observe(document.documentElement, {attributes:true, attributeFilter:['data-theme']});
showDetail(null); layout();
</script>
"""

out = (HTML
       .replace("__DATA__", json.dumps(data))
       .replace("__CTX__", json.dumps(ctx)))
(HERE / "latent_dashboard.html").write_text(out)
print(f"wrote latent_dashboard.html ({len(out):,} bytes, {ctx})")
