// The browser version of FaceOrb: same library, same actions as the menu bar and review window.
// Self-contained (no CDN, no external requests) so it works offline and leaks nothing.
enum WebAppPage {
    static let html = #"""
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>FaceOrb</title>
<style>
:root{
  --bg:#f6f6f8;--panel:#fff;--ink:#1d1d1f;--muted:#6e6e73;--line:#e3e3e8;--chip:#f0f0f4;
  --accent:#3a5bd9;--mine:#1f9d55;--review:#d97a12;--others:#8e8e93;--danger:#d93a3a;
  --tile:#ebebf0;--shadow:0 1px 2px #0000000d,0 2px 8px #0000000f;--radius:12px;
  color-scheme:light;
}
@media (prefers-color-scheme:dark){:root{
  --bg:#141416;--panel:#1d1d20;--ink:#f2f2f5;--muted:#9a9aa2;--line:#2e2e33;--chip:#26262b;
  --accent:#7d97ff;--mine:#3ecf7a;--review:#f0a040;--others:#8e8e93;--danger:#ff6b6b;
  --tile:#2a2a2f;--shadow:0 1px 2px #0006,0 4px 14px #0004;color-scheme:dark}}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--ink);font:14px/1.45 -apple-system,BlinkMacSystemFont,"SF Pro Text",system-ui,sans-serif}
button,input{font:inherit;color:inherit}
button{cursor:pointer;border:1px solid var(--line);background:var(--panel);border-radius:8px;padding:6px 12px}
button:hover{border-color:var(--muted)}
button.primary{background:var(--accent);border-color:var(--accent);color:#fff}
button.danger{color:var(--danger)}
button.link{border:0;background:none;color:var(--accent);padding:4px 0}
button:disabled{opacity:.45;cursor:default}
select{border:1px solid var(--line);background:var(--panel);border-radius:8px;padding:5px 8px}
#savePanel{width:min(420px,calc(100vw - 32px))}
#savePanel label.row{justify-content:space-between;flex-wrap:nowrap}
#savePanel select,#savePanel input[type=text]{flex:0 1 250px;width:250px;min-width:0;max-width:100%}
input[type=text]{border:1px solid var(--line);background:var(--panel);border-radius:8px;padding:6px 10px;min-width:0}
header{display:flex;flex-wrap:wrap;gap:16px;align-items:center;padding:16px;background:var(--panel);border-bottom:1px solid var(--line)}
.brand{display:flex;gap:14px;align-items:center;flex:1 1 320px;min-width:0}
.orb{width:52px;height:52px;flex:none;border-radius:50%;position:relative;overflow:hidden;
  box-shadow:0 2px 6px #0005,inset 0 1px 0 #fffc,inset 0 -1px 1px #0005}
/* Chrome reflections that turn (slowly, faster while busy), under fixed shading and a highlight. */
.orb::before{content:"";position:absolute;inset:0;border-radius:50%;
  background:conic-gradient(#f5f5f5,#808080,#dbdbdb,#525252,#ebebeb,#8c8c8c,#f5f5f5);animation:spin 8s linear infinite}
.orb::after{content:"";position:absolute;inset:0;border-radius:50%;
  background:radial-gradient(circle at 32% 28%,#fffffff2,#fff0 22%),radial-gradient(circle,#c7c7c7f2,#c7c7c700 50%),radial-gradient(circle at 35% 30%,#0000,#00000026 60%,#0000008c 100%)}
.orb.busy{box-shadow:0 2px 6px #0005,0 0 14px var(--accent),inset 0 1px 0 #fffc}
.orb.busy::before{animation-duration:1.5s}
@media (prefers-reduced-motion:reduce){.orb::before{animation:none}}
@keyframes spin{to{transform:rotate(360deg)}}
.brand h1{font-size:17px;margin:0}
.status{color:var(--muted);white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.bar{height:4px;background:var(--chip);border-radius:2px;margin-top:6px;overflow:hidden}
.bar>i{display:block;height:100%;background:var(--accent);width:0;transition:width .3s}
.import{display:flex;gap:8px;flex:1 1 360px;flex-wrap:wrap;align-items:center}
.import input{flex:1 1 200px}
nav{display:flex;gap:4px;padding:10px 16px 0;border-bottom:1px solid var(--line);background:var(--panel);overflow-x:auto}
.topbar{position:sticky;top:0;z-index:5}
nav button{border:0;border-bottom:2px solid transparent;border-radius:0;background:none;padding:8px 12px;white-space:nowrap;color:var(--muted)}
nav button.on{color:var(--ink);border-bottom-color:var(--accent);font-weight:600}
nav .n{display:inline-block;min-width:22px;padding:0 6px;margin-left:6px;border-radius:10px;background:var(--chip);font-size:12px;font-variant-numeric:tabular-nums}
nav .spacer{flex:1}
main{padding:16px 16px 60px}
.toolbar{display:flex;align-items:baseline;gap:12px;flex-wrap:wrap;margin-bottom:12px}
.toolbar h2{margin:0;font-size:20px}
.hint{color:var(--muted)}
kbd{font:12px ui-monospace,monospace;border:1px solid var(--line);border-bottom-width:2px;border-radius:4px;padding:0 5px;background:var(--panel)}
button.primary kbd{color:var(--ink)}
.grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(160px,1fr));gap:14px}
.card{position:relative;border-radius:var(--radius);overflow:hidden;background:var(--tile);aspect-ratio:1/1;border:1px solid var(--line);box-shadow:var(--shadow);outline:3px solid transparent;outline-offset:-3px;transition:transform .15s ease,box-shadow .15s ease}
.card:hover{transform:translateY(-2px);box-shadow:0 8px 22px #0002}
.card.b-mine{box-shadow:inset 0 -3px 0 var(--mine),var(--shadow)}
.card.b-review{box-shadow:inset 0 -3px 0 var(--review),var(--shadow)}
.card.b-others{box-shadow:inset 0 -3px 0 var(--others),var(--shadow)}
.card.sel{outline-color:var(--accent)}
.card.sel::after{content:"✓";position:absolute;top:8px;right:8px;width:22px;height:22px;border-radius:50%;background:var(--accent);color:#fff;font:700 13px/22px -apple-system,system-ui,sans-serif;text-align:center;box-shadow:0 1px 4px #0006}
.multi .card.sel .acts{display:none}
.bulk{position:fixed;left:50%;bottom:16px;transform:translateX(-50%);z-index:20;display:flex;align-items:center;gap:10px;flex-wrap:wrap;justify-content:center;max-width:calc(100vw - 32px);box-sizing:border-box;padding:10px 14px;border-radius:14px;background:var(--panel);border:1px solid var(--line);box-shadow:0 10px 30px #0003}
.bulk b{font-variant-numeric:tabular-nums}
.bulk .yes,.bulk .no{color:#fff;border:0}
.bulk .link{border:0;background:none;color:var(--accent);padding:6px 4px}
.card img{width:100%;height:100%;object-fit:cover;display:block;background:var(--tile)}
.card.v-approved .badge{background:var(--mine)}
.card.v-rejected .badge{background:var(--danger)}
.card .meta{position:absolute;left:8px;right:8px;bottom:8px;display:flex;align-items:center;gap:6px;min-width:0}
.badge{font-size:12px;font-weight:600;color:#fff;background:#000a;border-radius:10px;padding:2px 8px;min-width:0;max-width:100%;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.card .acts{margin-left:auto;display:none;gap:6px;flex:none}
.card:hover .acts,.card.sel .acts{display:flex}
.round{width:30px;height:30px;border-radius:50%;padding:0;border:0;color:#fff;font-size:15px;line-height:30px;text-align:center;box-shadow:0 1px 4px #0006}
.yes{background:var(--mine)}.no{background:var(--danger)}.undo{background:#555}
.empty{text-align:center;color:var(--muted);padding:80px 20px}
.empty b{display:block;color:var(--ink);font-size:17px;margin-bottom:6px}
.people{display:grid;grid-template-columns:repeat(auto-fill,minmax(120px,1fr));gap:18px}
.person{border:0;background:none;padding:0;text-align:center}
.face{width:104px;height:104px;border-radius:50%;overflow:hidden;position:relative;margin:0 auto 6px;background:var(--chip);outline:4px solid transparent}
.person.picked .face{outline-color:var(--accent)}
.face img{position:absolute;max-width:none}
.inset{position:absolute;top:8px;right:8px;width:60px;height:60px;border-radius:50%;overflow:hidden;border:2px solid #fff;box-shadow:0 2px 8px #0008;background:var(--tile);z-index:1}
.inset img{position:absolute;max-width:none;width:auto;height:auto;object-fit:fill}
.panel{background:var(--panel);border:1px solid var(--line);border-radius:12px;padding:16px 18px;margin-bottom:16px;max-width:640px}
.panel h3{margin:0 0 10px;font-size:15px}
.stats{display:grid;grid-template-columns:repeat(auto-fill,minmax(130px,1fr));gap:10px;margin-bottom:10px}
.stat{background:var(--chip);border-radius:8px;padding:8px 10px}.stat b{display:block;font-size:18px;font-variant-numeric:tabular-nums}
.row{display:flex;gap:10px;flex-wrap:wrap;align-items:center;margin:8px 0}
.small{font-size:12px;color:var(--muted)}
.cutoffs{position:absolute;right:16px;top:calc(100% + 8px);width:min(320px,calc(100vw - 32px));max-height:calc(100vh - 160px);overflow-y:auto;box-sizing:border-box;z-index:10;box-shadow:0 8px 30px #0003}
.cutoffs .x{position:absolute;top:8px;right:8px;width:26px;height:26px;padding:0;border:0;border-radius:50%;background:var(--chip);color:var(--muted);font-size:16px;line-height:26px}
.cutoffs h3,.cutoffs>div:first-of-type{padding-right:30px}
.cutoffs input{width:100%}
.lb{position:fixed;inset:0;background:#0b0b0cf0;display:flex;flex-direction:column;z-index:20}
.lb .top{display:flex;gap:8px;align-items:center;padding:10px 16px;color:#fff}
.lb .top button{color:var(--ink)}.lb .top button.primary{color:#fff}
.lb .top .name{flex:1;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.lb .stage{flex:1;display:flex;align-items:center;justify-content:center;padding:0 16px 8px;min-height:0}
.lb .frame{position:relative;max-width:100%;max-height:100%}
.lb .frame img{display:block;max-width:calc(100vw - 136px);max-height:calc(100vh - 120px);max-height:calc(100dvh - 120px);object-fit:contain;border-radius:8px;box-shadow:0 10px 40px #000a}
.box{position:absolute;border:1.5px solid #fffb;border-radius:4px;cursor:pointer}
.box.best{border:3px solid #ffd60a}
.box:hover{background:#ffffff22}
.lb .nav{position:absolute;top:50%;transform:translateY(-50%);width:44px;height:44px;border-radius:50%;border:0;padding:0;background:#fff2;color:#fff;font-size:26px;line-height:44px;z-index:1}
.lb .nav:hover:not(:disabled){background:#fff4}.lb .nav:disabled{opacity:.25}
.lb .prev{left:12px}.lb .next{right:12px}
.lb .stage{position:relative}
.lb .top .count{color:#aaa;font-variant-numeric:tabular-nums;white-space:nowrap}
.lb .top .x{width:34px;height:34px;padding:0;border-radius:50%;font-size:20px;line-height:34px}
.lb .foot{color:#ccc;text-align:center;font-size:12px;padding:0 16px 10px}
@media (max-width:560px){.toolbar h2{font-size:18px}.panel{padding:14px}.people{gap:14px}}
.toast{position:fixed;left:50%;bottom:18px;transform:translateX(-50%);background:var(--panel);border:1px solid var(--line);border-radius:20px;padding:8px 16px;box-shadow:0 6px 24px #0003;z-index:30}
.err{color:var(--review)}
[hidden]{display:none!important}
</style>
</head>
<body>
<header>
  <div class="brand">
    <div class="orb" id="orb" aria-hidden="true"></div>
    <div style="min-width:0;flex:1">
      <h1>FaceOrb</h1>
      <div class="status" id="status">Loading…</div>
      <div class="bar" id="bar" hidden><i></i></div>
    </div>
    <button id="stop" hidden>Stop</button>
  </div>
  <form class="import" id="importForm">
    <input type="text" id="link" placeholder="Paste an album or photo link" autocomplete="off">
    <button class="primary" id="importBtn">Import</button>
    <button type="button" class="link" id="folderBtn">or scan a folder on this Mac…</button>
  </form>
  <form class="import" id="folderForm" hidden>
    <input type="text" id="folder" placeholder="/Users/you/Pictures/Party" autocomplete="off">
    <button class="primary">Scan folder</button>
    <button type="button" class="link" id="folderCancel">Cancel</button>
  </form>
</header>
<div class="topbar">
<nav id="nav">
  <button data-tab="review">Needs review<span class="n" id="n-review">0</span></button>
  <button data-tab="mine">My photos<span class="n" id="n-mine">0</span></button>
  <button data-tab="others">Everyone else<span class="n" id="n-others">0</span></button>
  <button data-tab="people">Who you are</button>
  <button data-tab="privacy">Privacy &amp; data</button>
  <span class="spacer"></span>
  <button id="cutBtn">Cutoffs</button>
  <button id="saveBtn">Save my photos</button>
</nav>
<div class="panel cutoffs" id="savePanel" hidden>
  <button type="button" class="x" aria-label="Close" title="Close (Esc)">×</button>
  <h3>Save my photos</h3>
  <label class="row">Photos <select id="exScope"><option value="mine">My photos</option><option value="mineAndReview">My photos + Needs review</option></select></label>
  <label class="row">Format <select id="exFormat"><option value="original">Original (as downloaded)</option><option value="jpeg">JPEG</option><option value="heic">HEIC (smaller, Apple devices)</option><option value="png">PNG (lossless, large)</option><option value="tiff">TIFF (lossless, very large)</option></select></label>
  <label class="row" id="exQRow">Quality <input type="range" id="exQuality" min="50" max="100" value="90"> <span id="exQVal">90%</span></label>
  <label class="row">Size <select id="exSize"><option value="0">Full size</option><option value="4096">4096 px</option><option value="2048">2048 px (good for sharing)</option><option value="1080">1080 px (social)</option></select></label>
  <label class="row">Names <select id="exNaming"><option value="original">Keep original names</option><option value="numbered">Number them (Album-001…)</option></select></label>
  <label class="row">Folder <input type="text" id="exFolder" value="~/Pictures" style="flex:1"></label>
  <label class="row">New folder <input type="text" id="exSub" value="FaceOrb - My photos" style="flex:1"></label>
  <p class="small" id="exFree"></p>
  <div class="row"><button class="primary" id="exGo">Save</button><button id="csvBtn">Download list (CSV)</button><button class="link danger" id="exUndo">Delete last saved copies</button></div>
</div>
<div class="panel cutoffs" id="cutoffs" hidden>
  <button type="button" class="x" aria-label="Close" title="Close (Esc)">×</button>
  <div id="autoLbl"></div><input type="range" id="auto" min="30" max="90" step="1">
  <div id="revLbl" style="margin-top:10px"></div><input type="range" id="rev" min="15" max="90" step="1">
  <p class="small">Scores are how closely a face matches yours. 50% is a confident match for this model.</p>
</div>
</div>
<main id="main"></main>
<div class="lb" id="lb" hidden>
  <div class="top"><span class="name" id="lbName"></span><span class="count" id="lbCount"></span>
    <button id="lbNo">Not me <kbd>R</kbd></button><button class="primary" id="lbYes">That's me <kbd>A</kbd></button>
    <button class="x" id="lbClose" title="Close (Esc)" aria-label="Close">×</button></div>
  <div class="stage"><button class="nav prev" id="lbPrev" title="Previous (←)" aria-label="Previous photo">‹</button>
    <div class="frame" id="lbFrame"><img id="lbImg" alt=""></div>
    <button class="nav next" id="lbNext" title="Next (→)" aria-label="Next photo">›</button></div>
  <div class="foot">Yellow is the face FaceOrb thinks is you. Click a different face if it picked the wrong one. <kbd>←</kbd> <kbd>→</kbd> to browse, <kbd>Esc</kbd> to close.</div>
</div>
<div class="toast" id="toast" hidden></div>
<script>
"use strict";
const $ = s => document.querySelector(s);
const TITLES = {review:"Needs review", mine:"My photos", others:"Everyone else"};
// sel: the photo keys act from (and Shift-click ranges start at); picked: every selected photo.
let picked = new Set();
let S = null, raw = "", tab = "review", sel = null, people = null, lbId = null, toastTimer = 0;

async function api(path, body) {
  const opts = body === undefined ? {} : {method:"POST", headers:{"X-FaceOrb":"1","Content-Type":"application/json"},
    body: body instanceof Blob ? body : JSON.stringify(body)};
  const r = await fetch(path, opts);
  if (r.status === 403) { location.reload(); throw new Error("locked"); }
  const ct = r.headers.get("Content-Type") || "";
  const data = ct.includes("json") ? await r.json() : await r.text();
  if (body !== undefined && data && data.message) toast(data.message, !data.ok);
  return data;
}
function toast(msg, isErr) {
  const t = $("#toast"); t.textContent = msg; t.className = "toast" + (isErr ? " err" : ""); t.hidden = false;
  clearTimeout(toastTimer); toastTimer = setTimeout(() => t.hidden = true, 3500);
}
const esc = s => String(s).replace(/[&<>"']/g, c => ({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;","'":"&#39;"}[c]));
const pct = s => s < 0 ? "no face" : Math.round(Math.max(0, s) * 100) + "%";
const img = (id, px) => "/img?id=" + encodeURIComponent(id) + "&px=" + px;
// Before enrolment every photo tab shows the people picker instead.
const shown = () => (!S.enrolled && S.stats.photos && !["privacy","people"].includes(tab)) ? "people" : tab;
const inTab = () => S ? S.photos.filter(p => p.bucket === tab) : [];

async function refresh(force) {
  const text = JSON.stringify(await api("/api/state"));
  if (!force && text === raw) return;
  const peopleStale = S && (S.stats.faces !== JSON.parse(text).stats.faces);
  raw = text; S = JSON.parse(text);
  if (peopleStale) people = null;
  render();
}

function render() {
  $("#orb").classList.toggle("busy", S.busy);
  const n = S.stats.photos;
  $("#status").innerHTML = S.busy ? esc(S.activity)
    : S.error ? '<span class="err">' + esc(S.error) + "</span>"
    : !n ? "Paste an album link or scan a folder to start."
    : !S.enrolled ? n + " photos scanned. Show FaceOrb who you are."
    : (S.counts.review || 0) ? (S.counts.review) + " photos need a quick yes or no."
    : "All sorted. " + (S.counts.mine || 0) + " photos of you.";
  $("#bar").hidden = S.fraction == null; $("#bar i").style.width = ((S.fraction || 0) * 100) + "%";
  $("#stop").hidden = !S.busy; $("#importBtn").disabled = S.busy;
  for (const b of ["review","mine","others"]) $("#n-" + b).textContent = S.counts[b] || 0;
  document.querySelectorAll("nav [data-tab]").forEach(b => b.classList.toggle("on", b.dataset.tab === shown()));
  $("#saveBtn").disabled = !(S.counts.mine);
  if (S.freeDisk != null) {
    const gb = S.freeDisk / 1e9;
    $("#exFree").innerHTML = (gb < 2 ? '<span class="err">' : "<span>") + gb.toFixed(1) + " GB free on this Mac" +
      (gb < 2 ? ". That's too little: files may fail to save or delete until you free space.</span>" : ".</span>");
  }
  const st = S.settings;
  $("#auto").value = Math.round(st.autoThreshold * 100); $("#rev").value = Math.round(st.reviewThreshold * 100);
  $("#rev").max = $("#auto").value;
  $("#autoLbl").textContent = "Auto-file as mine at " + $("#auto").value + "% or more";
  $("#revLbl").textContent = "Ask me between " + $("#rev").value + "% and " + $("#auto").value + "%";
  if (shown() === "people") return renderPeople();
  if (tab === "privacy") return renderPrivacy();
  renderGrid();
}

function renderGrid() {
  const items = inTab();
  if (!items.some(p => p.id === sel)) sel = items.length ? items[0].id : null;
  const ids = new Set(items.map(p => p.id));
  picked = new Set([...picked].filter(id => ids.has(id)));
  if (!picked.size && sel) picked.add(sel);
  const head = '<div class="toolbar"><h2>' + TITLES[tab] + '</h2><span class="hint">' + items.length + "</span>" +
    (tab === "review" && items.length ? '<span class="hint"><kbd>A</kbd> that\'s me · <kbd>R</kbd> not me · <kbd>U</kbd> undo · <kbd>Space</kbd> full size · <kbd>⌘</kbd>/<kbd>⇧</kbd>-click to pick several</span>' : "") + "</div>";
  if (!items.length) {
    renderBulk();
    const msg = {review:["Nothing to review","Every photo is filed. Lower the review cutoff to double-check more."],
      mine:["No photos of you yet","Import an album and pick yourself to get started."],
      others:["No other photos","Photos without you will show up here."]}[tab];
    $("#main").innerHTML = head + '<div class="empty"><b>' + msg[0] + "</b>" + msg[1] + "</div>";
    return;
  }
  $("#main").innerHTML = head + '<div class="grid">' + items.map(p => {
    const acts = p.verdict ? '<button class="round undo" data-act="undo" title="Undo (U)">↶</button>'
      : (tab !== "others" ? '<button class="round no" data-act="rejected" title="Not me (R)">✕</button>' : "") +
        (tab !== "mine" ? '<button class="round yes" data-act="approved" title="That\'s me (A)">✓</button>' : "");
    const badge = p.verdict === "approved" ? "✓ You" : p.verdict === "rejected" ? "✕ Not you" : pct(p.score);
    return '<div class="card b-' + tab + (p.verdict ? " v-" + p.verdict : "") + (picked.has(p.id) ? " sel" : "") + '" data-id="' + esc(p.id) + '" title="' + esc(p.name) + '">' +
      '<img loading="lazy" decoding="async" src="' + img(p.id, 400) + '" alt="">' +
      (p.bestBox && p.score >= 0 && tab !== "others" ? '<div class="inset" title="The face FaceOrb matched"><img loading="lazy" decoding="async" data-d="64" data-box=\'' + JSON.stringify(p.bestBox) + '\' src="' + img(p.id, 1600) + '" alt=""></div>' : "") +
      '<div class="meta"><span class="badge">' + badge + '</span><span class="acts">' + acts + "</span></div></div>";
  }).join("") + "</div>";
  document.querySelectorAll(".inset img").forEach(im => im.complete ? cropFace(im) : im.addEventListener("load", () => cropFace(im)));
  renderBulk();
}

// Multi-select: marks the picked cards and shows the bulk bar when more than one is picked.
function syncPicked() {
  document.querySelectorAll(".card").forEach(c => c.classList.toggle("sel", picked.has(c.dataset.id)));
  renderBulk();
}
function renderBulk() {
  let bar = $("#bulk");
  const show = picked.size > 1 && !["people","privacy"].includes(tab);
  document.body.classList.toggle("multi", show);
  if (!show) { if (bar) bar.remove(); return; }
  if (!bar) { bar = document.createElement("div"); bar.id = "bulk"; bar.className = "bulk"; document.body.appendChild(bar); }
  const anyDecided = S && S.photos.some(p => picked.has(p.id) && p.verdict);
  bar.innerHTML = "<b>" + picked.size + " selected</b>" +
    '<button class="link" data-bulk="clear" title="Keep one selected (Esc)">Deselect</button>' +
    (anyDecided ? '<button data-bulk="undo" title="Undo (U)">↶ Undo</button>' : "") +
    '<button class="no" data-bulk="rejected" title="Not me (R)">✕ Not me</button>' +
    '<button class="yes" data-bulk="approved" title="That\'s me (A)">✓ That\'s me</button>';
}
document.addEventListener("click", e => {
  const b = e.target.closest("[data-bulk]"); if (!b) return;
  const a = b.dataset.bulk;
  if (a === "clear") { picked = new Set(sel ? [sel] : []); syncPicked(); }
  else if (a === "undo") undoMany();
  else decideMany(a);
});
async function decideMany(verdict) {
  const order = inTab().map(p => p.id), chosen = order.filter(id => picked.has(id));
  if (!chosen.length) return;
  if (chosen.length === 1) return decide(chosen[0], verdict);
  const last = order.indexOf(chosen[chosen.length - 1]);
  await api("/api/decide-many", {photoIDs: chosen, verdict});
  await refresh(true);
  const left = new Set(inTab().map(p => p.id));
  sel = order.slice(last + 1).find(x => left.has(x)) || [...left].pop() || null;
  picked = new Set(sel ? [sel] : []);
  if (tab !== "people" && tab !== "privacy") renderGrid();
  scrollToSel();
}
async function undoMany() {
  const chosen = [...picked];
  if (chosen.length === 1) return undo(chosen[0]);
  await api("/api/undo-many", {photoIDs: chosen});
  refresh(true);
}

async function renderPeople() {
  const head = '<div class="toolbar"><h2>Which one is you?</h2></div>' +
    '<p class="hint" style="max-width:640px">FaceOrb grouped the faces it found into people. Click yours, or add 3 to 5 selfies instead. Only a 128-number face signature is kept, never the selfie.</p>' +
    '<div class="row"><label><button type="button" id="selfieBtn">Add selfies…</button></label>' +
    '<input type="file" id="selfies" accept="image/*" multiple hidden>' +
    (S.enrolled ? '<button class="danger" id="startOver">Start over</button>' : "") + "</div>" +
    (S.stats.pending ? '<p class="hint">Still scanning ' + S.stats.pending + " photos. More people will appear.</p>" : "");
  if (!people) { $("#main").innerHTML = head + '<p class="hint">Grouping faces…</p>'; people = await api("/api/people"); }
  if (shown() !== "people") return;
  $("#main").innerHTML = head + (people.length ? '<div class="people">' + people.map(p =>
    '<button class="person' + (p.picked ? " picked" : "") + '" data-person="' + esc(p.id) + '"><div class="face"><img loading="lazy" decoding="async" data-box=\'' +
    JSON.stringify(p.box) + '\' src="' + img(p.photoID, 900) + '" alt=""></div><span class="small">In ' + p.photoCount + " photos</span></button>"
  ).join("") + "</div>" : '<div class="empty"><b>No people yet</b>Import an album first.</div>');
  document.querySelectorAll(".face img").forEach(im => im.complete ? cropFace(im) : im.addEventListener("load", () => cropFace(im)));
  $("#selfieBtn").onclick = () => $("#selfies").click();
  $("#selfies").onchange = async e => {
    for (const f of e.target.files) await api("/api/selfie", f);
    await refresh(true);
  };
  if ($("#startOver")) $("#startOver").onclick = async () => { await api("/api/forget-me", {}); people = null; refresh(true); };
}

// Show just the face: scale the photo so the padded face box fills the circle.
function cropFace(im) {
  const b = JSON.parse(im.dataset.box), W = im.naturalWidth, H = im.naturalHeight, D = +(im.dataset.d || 104);
  const side = Math.max(b.width * W, b.height * H) * 1.7, k = D / side;
  im.style.width = W * k + "px"; im.style.height = H * k + "px";
  im.style.left = -((b.x + b.width / 2) * W - side / 2) * k + "px";
  im.style.top = -((b.y + b.height / 2) * H - side / 2) * k + "px";
}

function renderPrivacy() {
  const s = S.stats;
  $("#main").innerHTML =
    '<div class="panel"><h3>What FaceOrb keeps</h3><div class="stats">' +
    [["Photos",s.photos],["Faces found",s.faces],["Face signatures",s.signatures],["Your reference faces",s.references]]
      .map(([k,v]) => '<div class="stat"><b>' + v + "</b>" + k + "</div>").join("") + "</div>" +
    '<p class="small">Face detection (Apple Vision) and recognition (SFace) run on this Mac. This page is served only to this Mac (127.0.0.1) and needs the key from the menu bar. Nothing is uploaded.</p></div>' +
    '<div class="panel"><h3>Other people\'s faces</h3><label class="row"><input type="checkbox" id="autoForget"' +
    (S.settings.forgetBystandersAutomatically ? " checked" : "") + "> Forget other people's faces after each scan</label>" +
    '<div class="row"><button id="forgetOthers"' + (S.enrolled ? "" : " disabled") + ">Forget other people's faces now</button></div>" +
    '<p class="small">Keeps signatures only for faces that might be you.</p></div>' +
    '<div class="panel"><h3>Reset</h3><div class="row"><button id="forgetMe">Forget my face and decisions</button></div>' +
    '<div class="row" id="clearRow"><button id="clearAsk"' + (s.photos && !S.busy ? "" : " disabled") + '>Clear all photos and start over…</button></div>' +
    '<div class="row" id="delRow"><button class="danger" id="delAsk">Delete all FaceOrb data…</button></div></div>';
  $("#autoForget").onchange = e => api("/api/autoforget", {on: e.target.checked}).then(() => refresh());
  $("#forgetOthers").onclick = () => api("/api/forget-others", {}).then(() => refresh());
  $("#forgetMe").onclick = () => api("/api/forget-me", {}).then(() => { people = null; refresh(); });
  $("#clearAsk").onclick = () => {
    $("#clearRow").innerHTML = "<span>Remove all " + s.photos + " photos, their faces and decisions? FaceOrb keeps your face.</span>" +
      '<button id="clearNo">Cancel</button><button class="danger" id="clearYes">Clear photos</button>';
    $("#clearNo").onclick = renderPrivacy;
    $("#clearYes").onclick = () => api("/api/clear-photos", {confirm: true, keepMe: true}).then(() => { people = null; refresh(true); });
  };
  $("#delAsk").onclick = () => {
    $("#delRow").innerHTML = "<span>Delete every photo copy, face signature and decision?</span>" +
      '<button id="delNo">Cancel</button><button class="danger" id="delYes">Delete</button>';
    $("#delNo").onclick = renderPrivacy;
    $("#delYes").onclick = () => api("/api/delete-all", {confirm: true}).then(() => { people = null; refresh(true); });
  };
}

async function decide(id, verdict, faceID) {
  const order = inTab().map(p => p.id), i = order.indexOf(id);
  await api("/api/decide", {photoID: id, verdict, faceID: faceID || null});
  await refresh(true);
  const left = new Set(inTab().map(p => p.id));
  sel = order.slice(i + 1).find(x => left.has(x)) || [...left].pop() || null;
  picked = new Set(sel ? [sel] : []);
  if (tab !== "people" && tab !== "privacy") renderGrid();
  scrollToSel();
  // In the full-size view, move on to the next photo instead of closing.
  if (lbId === id) { if (sel) openLightbox(sel); else closeLightbox(); }
}
// One decision at a time from the full-size view, so fast key presses can't skip photos.
let lbBusy = false;
async function lbDecide(verdict, faceID) {
  if (!lbId || lbBusy) return;
  lbBusy = true;
  try { await decide(lbId, verdict, faceID); } finally { lbBusy = false; }
}
async function undo(id) { await api("/api/undo", {photoID: id}); refresh(true); }
function scrollToSel() { const el = sel && document.querySelector('.card[data-id="' + CSS.escape(sel) + '"]'); if (el) el.scrollIntoView({block:"nearest"}); }

async function openLightbox(id) {
  const p = S.photos.find(x => x.id === id); if (!p) return;
  lbId = id;
  const items = inTab().map(x => x.id), i = items.indexOf(id);
  $("#lbName").textContent = p.name + " · " + pct(p.score);
  $("#lbCount").textContent = i >= 0 ? (i + 1) + " of " + items.length : "";
  $("#lbPrev").disabled = i <= 0; $("#lbNext").disabled = i < 0 || i >= items.length - 1;
  $("#lbImg").src = img(id, 1600);
  $("#lbFrame").querySelectorAll(".box").forEach(b => b.remove());
  $("#lb").hidden = false;
  const faces = await api("/api/photo?id=" + encodeURIComponent(id));
  if (lbId !== id) return;   // moved on while the faces loaded
  for (const f of faces) {
    const d = document.createElement("div");
    d.className = "box" + (f.id === p.bestFace ? " best" : ""); d.title = "This is me";
    Object.assign(d.style, {left: f.box.x * 100 + "%", top: f.box.y * 100 + "%", width: f.box.width * 100 + "%", height: f.box.height * 100 + "%"});
    d.onclick = () => lbDecide("approved", f.id);
    $("#lbFrame").appendChild(d);
  }
}
function closeLightbox() { $("#lb").hidden = true; lbId = null; scrollToSel(); }
// Browse the current tab; the grid behind follows, so closing lands on the last photo viewed.
function lbStep(d) {
  const items = inTab().map(x => x.id), i = items.indexOf(lbId), next = items[i + d];
  if (i < 0 || !next) return;
  sel = next; picked = new Set([next]); syncPicked();
  openLightbox(next);
}

// Events
$("#nav").addEventListener("click", e => {
  const b = e.target.closest("[data-tab]"); if (!b) return;
  tab = b.dataset.tab; sel = null; picked = new Set(); render(); scrollTo(0, 0);
});
$("#main").addEventListener("click", e => {
  const act = e.target.closest("[data-act]"), card = e.target.closest(".card"), person = e.target.closest("[data-person]");
  if (person) { api("/api/enroll", {clusterID: person.dataset.person}).then(() => { people = null; tab = "review"; refresh(true); }); return; }
  if (!card) return;
  const id = card.dataset.id;
  if (act) { act.dataset.act === "undo" ? undo(id) : decide(id, act.dataset.act); return; }
  if (e.metaKey || e.ctrlKey) { picked.has(id) ? picked.delete(id) : picked.add(id); sel = id; }
  else if (e.shiftKey && sel) {
    const order = inTab().map(p => p.id), i = order.indexOf(sel), j = order.indexOf(id);
    if (i >= 0 && j >= 0) order.slice(Math.min(i, j), Math.max(i, j) + 1).forEach(x => picked.add(x));
  } else { sel = id; picked = new Set([id]); }
  syncPicked();
});
// Shift-click shouldn't select page text.
$("#main").addEventListener("mousedown", e => { if (e.shiftKey && e.target.closest(".card")) e.preventDefault(); });
$("#main").addEventListener("dblclick", e => { const c = e.target.closest(".card"); if (c) openLightbox(c.dataset.id); });
$("#lbYes").onclick = () => lbDecide("approved");
$("#lbNo").onclick = () => lbDecide("rejected");
$("#lbClose").onclick = closeLightbox;
$("#lbPrev").onclick = () => lbStep(-1);
$("#lbNext").onclick = () => lbStep(1);
$("#lb").addEventListener("click", e => { if (e.target.classList.contains("stage")) closeLightbox(); });
document.addEventListener("keydown", e => {
  if (e.key === "Escape" && !lbId && closePanels()) { e.preventDefault(); return; }
  if (e.target.tagName === "INPUT") return;
  const k = e.key.toLowerCase();
  if ((e.metaKey || e.ctrlKey) && k === "a" && !lbId && !["people","privacy"].includes(tab)) {
    e.preventDefault(); picked = new Set(inTab().map(p => p.id)); syncPicked(); return;
  }
  if (e.metaKey || e.ctrlKey || e.altKey) return;
  if (lbId) {
    if (k === "escape" || k === " ") { e.preventDefault(); closeLightbox(); }
    else if (k === "arrowright" || k === "arrowleft") { e.preventDefault(); lbStep(k === "arrowright" ? 1 : -1); }
    else if (k === "a" || k === "y") $("#lbYes").click();
    else if (k === "r" || k === "n") $("#lbNo").click();
    return;
  }
  if (!sel || ["people","privacy"].includes(tab)) return;
  const items = inTab().map(p => p.id), i = items.indexOf(sel);
  if (k === "escape" && picked.size > 1) { picked = new Set([sel]); syncPicked(); }
  else if (k === "a" || k === "y") decideMany("approved");
  else if (k === "r" || k === "n") decideMany("rejected");
  else if (k === "u") undoMany();
  else if (k === " " || k === "enter") { e.preventDefault(); openLightbox(sel); }
  else if (k === "arrowright" || k === "arrowleft") {
    e.preventDefault(); sel = items[Math.min(Math.max(i + (k === "arrowright" ? 1 : -1), 0), items.length - 1)]; picked = new Set([sel]); renderGrid(); scrollToSel();
  }
});
$("#importForm").onsubmit = async e => {
  e.preventDefault(); const link = $("#link").value.trim(); if (!link) return;
  await api("/api/import", {link}); $("#link").value = ""; refresh(true);
};
$("#folderBtn").onclick = () => { $("#importForm").hidden = true; $("#folderForm").hidden = false; $("#folder").focus(); };
$("#folderCancel").onclick = () => { $("#importForm").hidden = false; $("#folderForm").hidden = true; };
$("#folderForm").onsubmit = async e => {
  e.preventDefault(); const path = $("#folder").value.trim(); if (!path) return;
  await api("/api/import-folder", {path}); $("#folderCancel").click(); refresh(true);
};
$("#stop").onclick = () => api("/api/cancel", {}).then(() => refresh());
$("#csvBtn").onclick = () => { location.href = "/export.csv"; };
// The Cutoffs and Save panels drop down under the tab bar; the tab button, ×, Esc or a click elsewhere closes them.
function closePanels() {
  const open = !$("#cutoffs").hidden || !$("#savePanel").hidden;
  $("#cutoffs").hidden = $("#savePanel").hidden = true;
  return open;
}
function togglePanel(id) { const show = $(id).hidden; closePanels(); $(id).hidden = !show; }
for (const x of document.querySelectorAll(".cutoffs .x")) x.onclick = closePanels;
document.addEventListener("mousedown", e => {
  if (!e.target.closest(".cutoffs, #cutBtn, #saveBtn")) closePanels();
});
$("#saveBtn").onclick = () => togglePanel("#savePanel");
const lossy = () => ["jpeg","heic"].includes($("#exFormat").value);
$("#exFormat").onchange = () => { $("#exQRow").hidden = !lossy(); };
$("#exQuality").oninput = () => { $("#exQVal").textContent = $("#exQuality").value + "%"; };
$("#exQRow").hidden = true;
$("#exGo").onclick = async () => {
  const options = {format: $("#exFormat").value, quality: $("#exQuality").value / 100, scope: $("#exScope").value,
    naming: $("#exNaming").value, subfolder: $("#exSub").value, maxPixel: +$("#exSize").value || 0};
  await api("/api/export", {folder: $("#exFolder").value.trim(), options});
  $("#savePanel").hidden = true; refresh(true);
};
$("#exUndo").onclick = () => api("/api/delete-last-export", {}).then(() => refresh());
$("#cutBtn").onclick = () => togglePanel("#cutoffs");
let cutTimer = 0;
for (const id of ["#auto", "#rev"]) $(id).oninput = () => {
  $("#autoLbl").textContent = "Auto-file as mine at " + $("#auto").value + "% or more";
  $("#revLbl").textContent = "Ask me between " + Math.min($("#rev").value, $("#auto").value) + "% and " + $("#auto").value + "%";
  clearTimeout(cutTimer);
  cutTimer = setTimeout(() => api("/api/thresholds", {auto: $("#auto").value / 100, review: Math.min($("#rev").value, $("#auto").value) / 100}).then(() => refresh()), 250);
};

// Stay in sync with the menu bar app (decisions made there show up here).
(async function loop() {
  try { await refresh(); } catch (e) {}
  setTimeout(loop, S && S.busy ? 1200 : 4000);
})();
</script>
</body>
</html>
"""#
}
