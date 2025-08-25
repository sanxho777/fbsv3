# setup_duo_year_mileage_fix.ps1
# Rebuilds:
#   vehicle-poster-node-bridge (Node server)
#   vehicle-poster-extension   (overlay)
# Fixes: Year, Price, Mileage robustness

$root = (Get-Location).Path
$nodeDir = Join-Path $root "vehicle-poster-node-bridge"
$extDir  = Join-Path $root "vehicle-poster-extension"

Remove-Item $nodeDir,$extDir -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path $nodeDir | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $nodeDir "utils"), (Join-Path $nodeDir "images"), (Join-Path $nodeDir "data") | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $extDir "content"), (Join-Path $extDir "assets") | Out-Null

function Write-U8($path,$content){ [IO.File]::WriteAllText($path,$content,(New-Object System.Text.UTF8Encoding($false))) }

# -------- Node bridge --------
Write-U8 (Join-Path $nodeDir ".env.example") @'
FACEBOOK_EMAIL=
FACEBOOK_PASSWORD=
USER_DATA_DIR=./.chrome-profile
CHROME_EXECUTABLE=
USER_AGENT=Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36
PORT=5566
'@

Write-U8 (Join-Path $nodeDir "package.json") @'
{
  "name": "vehicle-poster-node-bridge",
  "version": "1.0.3",
  "type": "module",
  "scripts": { "start": "node index.js" },
  "dependencies": {
    "cors": "^2.8.5",
    "dotenv": "^16.4.5",
    "express": "^4.19.2",
    "inquirer": "^9.3.7",
    "node-fetch": "^3.3.2",
    "puppeteer": "^24.9.0",
    "puppeteer-extra": "^3.3.6",
    "puppeteer-extra-plugin-stealth": "^2.11.1"
  }
}
'@

Write-U8 (Join-Path $nodeDir "utils\formatter.js") @'
export function roundedMileage(n){ if(n==null) return null; return Math.floor(Number(n)/1000)*1000; }
export function computeCondition(mi){ return (mi && Number(mi)<30000) ? "Used – Like New" : "Used – Good"; }
export function titleFromParts({year,make,model,trim}){ return [year,make,model,trim].filter(Boolean).join(" "); }
export function formatUSD(n){ return Number(n||0).toLocaleString("en-US",{style:"currency",currency:"USD",maximumFractionDigits:0}); }
export function defaultDescription(v){
  const priceStr = v.price?` at ${formatUSD(v.price)}`:"";
  const milesStr = v.mileage?` with ${Number(v.mileage).toLocaleString()} miles`:"";
  return `${v.year||""} ${v.make||""} ${v.model||""} ${v.trim||""}${milesStr}${priceStr}.

Available now at Capitol Chevrolet San Jose — schedule your test drive today!`;
}
'@

Write-U8 (Join-Path $nodeDir "utils\imageDownloader.js") @'
import fs from "fs";
import path from "path";
import fetch from "node-fetch";
export async function ensureDir(dir){ await fs.promises.mkdir(dir,{recursive:true}); }
export async function downloadImages(urls=[], outDir="./images"){
  await ensureDir(outDir);
  const saved=[]; let i=1;
  for(const u of urls){
    try{
      const res = await fetch(u, { headers: { "User-Agent":"Mozilla/5.0" }});
      if(!res.ok) continue;
      const extGuess = u.split("?")[0].split(".").pop().toLowerCase();
      const ext = ["jpg","jpeg","png","webp"].includes(extGuess)?extGuess:"jpg";
      const file = path.join(outDir, `photo_${String(i).padStart(2,"0")}.${ext}`);
      await fs.promises.writeFile(file, Buffer.from(await res.arrayBuffer()));
      saved.push(file); i++;
    }catch{}
  }
  return saved;
}
'@

Write-U8 (Join-Path $nodeDir "index.js") @'
import "dotenv/config";
import fs from "fs";
import path from "path";
import express from "express";
import cors from "cors";
import puppeteer from "puppeteer-extra";
import StealthPlugin from "puppeteer-extra-plugin-stealth";
import inquirer from "inquirer";
import { fileURLToPath } from "url";
import { titleFromParts, roundedMileage, computeCondition, defaultDescription } from "./utils/formatter.js";
import { downloadImages, ensureDir } from "./utils/imageDownloader.js";

puppeteer.use(StealthPlugin());

const __filename = fileURLToPath(import.meta.url);
const __dirname  = path.dirname(__filename);

const {
  FACEBOOK_EMAIL,
  FACEBOOK_PASSWORD,
  USER_DATA_DIR = path.join(__dirname,".chrome-profile"),
  CHROME_EXECUTABLE,
  USER_AGENT = process.env.USER_AGENT || "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
  PORT = 5566
} = process.env;

const sleep = (ms)=>new Promise(r=>setTimeout(r,ms));

let browser;
async function getBrowser(){
  if (browser) return browser;
  await ensureDir(USER_DATA_DIR);
  browser = await puppeteer.launch({
    headless:false,
    executablePath: CHROME_EXECUTABLE || undefined,
    args:[
      `--user-data-dir=${USER_DATA_DIR}`,
      "--no-sandbox","--disable-setuid-sandbox",
      "--disable-blink-features=AutomationControlled","--lang=en-US,en"
    ]
  });
  return browser;
}

async function openFacebookAndFill(vehicle, imagePaths){
  const b = await getBrowser();
  const page = await b.newPage();
  await page.setUserAgent(USER_AGENT);
  await page.setExtraHTTPHeaders({ "accept-language":"en-US,en;q=0.9" });
  await page.setViewport({ width:1280, height:900, deviceScaleFactor:1 });

  // Login if needed
  await page.goto("https://www.facebook.com/", { waitUntil:"networkidle2" });
  if (await page.$('input[name="email"]')) {
    if (!FACEBOOK_EMAIL || !FACEBOOK_PASSWORD) {
      console.log("⚠️ Login required. Log in in the window, then press Enter here.");
      await new Promise(res=>{ process.stdin.resume(); process.stdin.once("data",()=>{ process.stdin.pause(); res();}); });
    } else {
      await page.type('input[name="email"]', FACEBOOK_EMAIL, {delay:20});
      await page.type('input[name="pass"]',  FACEBOOK_PASSWORD, {delay:20});
      await Promise.all([
        page.click('button[name="login"]'),
        page.waitForNavigation({waitUntil:"networkidle2", timeout:60000}).catch(()=>{})
      ]);
    }
  }

  await page.goto("https://www.facebook.com/marketplace/create/vehicle", { waitUntil:"networkidle2" });

  // Helpers
  const typeIf = async (sel, val)=>{
    if(val==null || val==="") return;
    const el = await page.$(sel);
    if(!el) return;
    await page.$eval(sel, e=>e.value="");
    await page.type(sel, String(val));
    await page.keyboard.press("Enter").catch(()=>{});
  };

  // Year first (if FB offers dropdown)
  try { await typeIf('input[aria-label="Year"], [role="combobox"][aria-label="Year"]', vehicle.year); } catch {}

  // Title
  const title = titleFromParts(vehicle);
  await page.waitForSelector('input[aria-label="Title"], textarea[aria-label="Title"]', {timeout:20000});
  await typeIf('input[aria-label="Title"], textarea[aria-label="Title"]', title);

  // Price & mileage
  await typeIf('input[aria-label="Price"]', vehicle.price);
  await typeIf('input[aria-label="Mileage"], input[aria-label="Odometer"]', roundedMileage(vehicle.mileage));

  // Condition
  try{
    const label = (vehicle.mileage && Number(vehicle.mileage)<30000) ? "Used – Like New" : "Used – Good";
    const h = await page.$x(`//span[normalize-space()="${label}"]//ancestor::label | //div[normalize-space()="${label}"]`);
    if(h?.[0]) await h[0].click();
  }catch{}

  // Other fields
  await typeIf('input[aria-label="Make"]', vehicle.make);
  await typeIf('input[aria-label="Model"]', vehicle.model);
  await typeIf('input[aria-label="Trim"]', vehicle.trim);
  await typeIf('input[aria-label="Exterior color"]', vehicle.exteriorColor);
  await typeIf('input[aria-label="Interior color"]', vehicle.interiorColor);
  await typeIf('input[aria-label="Transmission"]', vehicle.transmission);
  await typeIf('input[aria-label="Engine"]', vehicle.engine);
  await typeIf('input[aria-label="Drivetrain"]', vehicle.drivetrain);
  await typeIf('input[aria-label="VIN"]', vehicle.vin);

  // Description
  const desc = (vehicle.description || defaultDescription(vehicle)).slice(0,9700);
  if (await page.$('textarea[aria-label="Description"]')) {
    await page.$eval('textarea[aria-label="Description"]', e=>e.value="");
    await page.type('textarea[aria-label="Description"]', desc);
  }

  // Photos
  const fileChooser = page.waitForFileChooser().catch(()=>null);
  const btn = await page.$x('//div[contains(.,"Add Photos") or contains(.,"Add Photo") or contains(.,"Photos")]');
  if(btn?.[0]) await btn[0].click().catch(()=>{});
  const chooser = await fileChooser;
  if(chooser && imagePaths.length) await chooser.accept(imagePaths);
  else {
    const input = await page.$('input[type="file"]');
    if(input && imagePaths.length) await input.uploadFile(...imagePaths);
  }

  console.log("\\n⏸ Autofill complete. Review and click Post.");
}

let busy=false;
async function handleCapture(payload){
  if(busy) return { ok:false, error:"busy" };
  busy=true;
  try{
    await fs.promises.writeFile(path.join(__dirname,"data","vehicle.json"), JSON.stringify(payload,null,2));
    const images = await downloadImages(payload.images||[], path.join(__dirname,"images"));
    console.log("\\n🚗 Vehicle:");
    console.table({
      Year: payload.year, Make: payload.make, Model: payload.model, Trim: payload.trim,
      Price: payload.price, Mileage: payload.mileage, VIN: payload.vin,
      Exterior: payload.exteriorColor, Interior: payload.interiorColor,
      Transmission: payload.transmission, Engine: payload.engine, Drivetrain: payload.drivetrain,
      Images: images.length
    });
    const { proceed } = await inquirer.prompt([{ type:"confirm", name:"proceed", message:"Open Facebook and autofill?", default:true }]);
    if(!proceed) return { ok:true, skipped:true };
    await openFacebookAndFill(payload, images);
    return { ok:true };
  }catch(e){
    console.error("Error:", e);
    return { ok:false, error:String(e.message||e) };
  }finally{ busy=false; }
}

const app = express();
app.use(cors());
app.use(express.json({limit:"2mb"}));
app.get("/ping", (req,res)=>res.json({ok:true}));
app.post("/capture", async (req,res)=> res.json(await handleCapture(req.body||{})));
app.listen(Number(process.env.PORT)||5566, ()=> console.log(`\\n🛰️ Node bridge on http://127.0.0.1:${process.env.PORT||5566}\\n`));
'@

Write-U8 (Join-Path $nodeDir "data\vehicle.json") "{}`n"

# -------- Extension (fixed Year/Price/Mileage) --------
Write-U8 (Join-Path $extDir "manifest.json") @'
{
  "manifest_version": 3,
  "name": "Vehicle Poster Overlay (to Node Bridge)",
  "version": "1.0.2",
  "description": "Overlay on AutoTrader/Cars.com that sends vehicle data to a local Node bridge for FB autofill.",
  "permissions": ["storage", "downloads", "activeTab", "scripting"],
  "host_permissions": [
    "*://*.autotrader.com/*",
    "*://*.cars.com/*",
    "http://127.0.0.1/*",
    "http://localhost/*"
  ],
  "content_scripts": [
    {
      "matches": ["*://*.autotrader.com/*", "*://*.cars.com/*"],
      "js": ["content/capture.js"],
      "css": ["content/overlay.css"],
      "run_at": "document_idle"
    }
  ],
  "icons": { "16":"assets/icon16.png","48":"assets/icon48.png","128":"assets/icon128.png" }
}
'@

Write-U8 (Join-Path $extDir "content\overlay.css") @'
#vp-root{position:fixed;right:16px;bottom:16px;z-index:2147483647;font-family:system-ui,-apple-system,Segoe UI,Roboto,Arial,sans-serif}
#vp-pill{background:#111827;color:#fff;border:none;padding:10px 14px;border-radius:999px;box-shadow:0 10px 22px rgba(0,0,0,.25);cursor:pointer;font-weight:700}
#vp-panel{position:fixed;right:16px;bottom:64px;width:380px;max-height:70vh;overflow:auto;background:#fff;border-radius:14px;padding:12px;box-shadow:0 16px 40px rgba(0,0,0,.25);display:none}
#vp-panel.open{display:block}
#vp-panel h2{margin:0 0 8px;font-size:16px}
#vp-panel .vp-row{display:grid;grid-template-columns:120px 1fr;gap:6px;font-size:12px;padding:4px 0;border-bottom:1px solid #f0f0f0}
#vp-panel .vp-row b{color:#374151}
#vp-panel .vp-actions{display:flex;gap:8px;margin-top:10px}
#vp-panel .vp-actions button{flex:1;padding:8px 10px;border-radius:10px;border:1px solid #e5e7eb;background:#f9fafb;cursor:pointer;font-weight:600}
#vp-panel .vp-actions button.primary{background:#2563eb;color:#fff;border-color:#1d4ed8}
#vp-status{font-size:11px;color:#6b7280;margin-top:6px}
'@

Write-U8 (Join-Path $extDir "content\capture.js") @'
(function(){
  const BRIDGE = "http://127.0.0.1:5566";
  // --- UI ---
  const root=document.createElement("div");
  root.id="vp-root";
  root.innerHTML=`
    <button id="vp-pill" title="Vehicle Poster">Capture Vehicle</button>
    <div id="vp-panel">
      <h2>Vehicle Preview</h2>
      <div id="vp-content"></div>
      <div class="vp-actions">
        <button id="vp-copy">Copy JSON</button>
        <button id="vp-images">Download Images</button>
        <button id="vp-send" class="primary">Send to Node</button>
      </div>
      <div id="vp-status">Checking Node bridge…</div>
    </div>`;
  document.documentElement.appendChild(root);
  const $=s=>root.querySelector(s);
  const btn=$("#vp-pill"), panel=$("#vp-panel"), content=$("#vp-content");
  const copyBtn=$("#vp-copy"), imgBtn=$("#vp-images"), sendBtn=$("#vp-send"), status=$("#vp-status");

  // --- helpers ---
  const wait=(ms)=>new Promise(r=>setTimeout(r,ms));
  const clean=s=>(s||"").replace(/\s+/g," ").trim();
  const text=el=>clean(el?.textContent||"");
  const num =raw=>{ if(raw==null) return null; const n=String(raw).replace(/[^\d]/g,""); return n? Number(n):null; };
  const formatUSD=n=>{ try{return Number(n).toLocaleString("en-US",{style:"currency",currency:"USD",maximumFractionDigits:0})}catch{return n} };
  const meta=name=>{ const m=document.querySelector(`meta[name="${name}"], meta[property="${name}"]`); return m?.content?.trim()||null; };

  const normYear = (s)=>{
    const m = String(s||"").match(/\b(19|20)\d{2}\b/);
    if(!m) return null;
    const y = Number(m[0]); return (y>=1981 && y<=2035)? y : null;
  };

  const parseYMMT = (t)=>{
    if(!t) return {};
    t = clean(t.replace(/\|.*$/,"")); // drop "| Cars.com" etc.
    // allow "New 2026 Chevrolet Trailblazer LT ..."
    const m = t.match(/(?:^|\s)(?:New|Used)?\s*((?:19|20)\d{2})\s+([A-Za-z][A-Za-z\-]+)\s+([A-Za-z0-9][A-Za-z0-9\-]+)(?:\s+(.+))?/i);
    if(!m) return { year: normYear(t) };
    let trim = clean(m[4]||"");
    // remove marketing tails from trim
    trim = trim.replace(/\b(For Sale|with|at|priced?).*$/i,"")
               .replace(/\$\d[\d,]*/g,"")
               .replace(/\|.*$/,"")
               .replace(/\s{2,}/g," ")
               .trim();
    if(!trim) trim = null;
    return { year:Number(m[1]), make:m[2], model:m[3], trim };
  };

  // label-based getter
  function getByLabel(labels){
    labels = Array.isArray(labels)? labels : [labels];
    const labRe = new RegExp("^\\s*(?:"+labels.map(l=>l.replace(/[.*+?^${}()|[\]\\]/g,"\\$&")).join("|")+")\\s*$","i");
    // dt/dd
    for(const dt of document.querySelectorAll("dt,[role=term]")){
      if(labRe.test(text(dt))){
        const dd = dt.nextElementSibling?.matches?.("dd,[role=definition]")? dt.nextElementSibling : dt.parentElement?.querySelector("dd,[role=definition]");
        const v = clean(text(dd)); if(v) return v;
      }
    }
    // generic two-column
    for(const el of document.querySelectorAll("div,span,p,th,td,label")){
      if(!labRe.test(text(el))) continue;
      const sib = el.nextElementSibling && clean(text(el.nextElementSibling)) ? clean(text(el.nextElementSibling)) : null;
      if(sib) return sib;
      const row = el.closest("tr,li,div");
      if(row){
        const cand = Array.from(row.querySelectorAll("div,span,td")).map(text).find(v=>v && !labRe.test(v));
        if(cand) return cand;
      }
    }
    return null;
  }

  // price candidates (prefer labeled; ignore MSRP/finance; clamp range; choose sale price)
  function collectPriceCandidates(){
    const badCtx = /(\/mo|per month|monthly|apr|down|payment|doc fee|destination|mpg|mi\/kwh|range)/i;
    const goodSel = [
      "[data-testid*='price' i]","[data-qa*='price' i]",
      "[id*='price' i]","[class*='price' i]",
      ".vehicle-price",".listing-price",".price-section .primary-price"
    ].join(",");
    const out=[];
    for(const el of document.querySelectorAll(goodSel)){
      const t = text(el); if(!t || badCtx.test(t)) continue;
      const isMSRP = /msrp/i.test(t);
      const matches = t.match(/\$?\s?(\d{1,3}(?:,\d{3})+|\d{4,8})/g)||[];
      for(const s of matches){
        const n = Number(String(s).replace(/[^\d]/g,""));
        if(n>=5000 && n<=200000) out.push({n, msrp:isMSRP, source:"labeled"});
      }
    }
    // page fallback
    const page = document.body.innerText;
    (page.match(/\$?\s?(\d{1,3}(?:,\d{3})+|\d{4,8})/g)||[]).forEach(s=>{
      const n = Number(String(s).replace(/[^\d]/g,""));
      if(n>=5000 && n<=200000) out.push({n, msrp:false, source:"page"});
    });
    return out;
  }
  const findPriceSmart = (jsonLdPrice)=>{
    if(jsonLdPrice && jsonLdPrice>=5000 && jsonLdPrice<=200000) return jsonLdPrice;
    const c = collectPriceCandidates();
    if(!c.length) return null;
    const labeled = c.filter(x=>x.source==="labeled");
    const nonMsrp = labeled.filter(x=>!x.msrp).map(x=>x.n);
    if(nonMsrp.length) return Math.min(...nonMsrp);
    if(labeled.length)  return Math.min(...labeled.map(x=>x.n));
    return Math.min(...c.map(x=>x.n));
  };

  // mileage candidates (prefer labeled; allow "mi." ; exclude mpg/range)
  function collectMileageCandidates(){
    const badCtx = /(mpg|mi\/kwh|kwh|range|electric range|epa)/i;
    const sel = [
      "[data-testid*='mileage' i]","[data-qa*='mileage' i]",
      "[id*='mileage' i]","[class*='mileage' i]",
      "[data-testid*='odometer' i]","[id*='odometer' i]","[class*='odometer' i]"
    ].join(",");
    const out = [];
    for(const el of document.querySelectorAll(sel)){
      const t = text(el); if(!t || badCtx.test(t)) continue;
      const m = t.match(/(\d[\d,\.]{0,9})\s*(?:mi|miles)\.?\b/i) || t.match(/^\s*(\d[\d,\.]{0,9})\s*$/i);
      if(m){ const n = Number(String(m[1]).replace(/[^\d]/g,"")); if(n>=0 && n<=500000) out.push(n); }
    }
    // page fallback
    const page = document.body.innerText;
    (page.match(/\b(\d[\d,\.]{0,9})\s*(?:mi|miles)\.?\b/gi)||[])
      .filter(s=>!badCtx.test(s))
      .forEach(s=>{
        const m = s.match(/(\d[\d,\.]{0,9})/);
        if(m){ const n = Number(String(m[1]).replace(/[^\d]/g,"")); if(n>=0 && n<=500000) out.push(n); }
      });
    return out;
  }
  const findMileageSmart = (jsonLdMiles)=>{
    if((jsonLdMiles??null)!=null) return Number(jsonLdMiles);
    const c = collectMileageCandidates();
    if(!c.length) return null;
    // prefer the smallest labeled odometer for new cars (e.g., 3 mi) — but guard against 0 showing up wrongly
    return Math.max(...c); // use max; in practice odometer is the largest "mi" figure on page
  };

  function bestFromSrcset(ss){
    try{
      const parts = (ss||"").split(",").map(s=>s.trim()).map(p=>{const [u,w]=p.split(/\s+/);return{url:u,w:Number((w||"").replace(/\D/g,""))||0};}).sort((a,b)=>b.w-a.w);
      return parts[0]?.url || null;
    }catch{return null;}
  }
  function collectImages(){
    const set=new Set();
    for(const img of document.querySelectorAll("img")){
      const u = bestFromSrcset(img.getAttribute("srcset")) || img.currentSrc || img.src;
      if(u && /(autotrader|cars\.com|dealer|images|cdn|cloudfront|akamaized|car|photo)/i.test(u)) set.add(u);
    }
    for(const el of document.querySelectorAll("[data-src],[data-lazy],[data-original]")){
      const u = el.getAttribute("data-src") || el.getAttribute("data-lazy") || el.getAttribute("data-original");
      if(u && /^https?:/i.test(u)) set.add(u);
    }
    return Array.from(set).slice(0,30);
  }
  async function expandAndScroll(){
    Array.from(document.querySelectorAll("button,a,div[role='button']")).filter(el=>/show more|see more|view details|expand|full details|specs/i.test(el.innerText||"")).forEach(el=>{ try{ el.click(); }catch{} });
    for(let y=0;y<Math.min(6000, document.body.scrollHeight+500); y+=800){ window.scrollTo({top:y,behavior:"instant"}); await wait(120); }
    window.scrollTo({top:0,behavior:"instant"}); await wait(60);
  }

  function scrapeVehicle(){
    const v={};
    // JSON-LD Vehicle & Product
    const lds = Array.from(document.querySelectorAll('script[type="application/ld+json"]')).map(s=>{try{return JSON.parse(s.textContent)}catch{return null}}).filter(Boolean);
    const node = lds.find(x=>x && (x["@type"]==="Vehicle" || (Array.isArray(x["@type"]) && x["@type"].includes("Vehicle"))));
    const prod = lds.find(x=>x && (x["@type"]==="Product" || (Array.isArray(x["@type"]) && x["@type"].includes("Product"))));
    if(node){
      v.year  = normYear(node.modelDate || node.productionDate || node.vehicleModelDate) || null;
      v.make  = node.brand && (node.brand.name || node.brand) || null;
      v.model = node.model || null;
      v.trim  = node.trim || null;
      if(node.mileageFromOdometer?.value) v.mileage = num(node.mileageFromOdometer.value);
      v.vin   = node.vin || null;
      v.exteriorColor = node.color || null;
      v.transmission  = node.vehicleTransmission || null;
      v.description   = node.description || null;
      if(node.image) v.images = Array.isArray(node.image)? node.image : [node.image];
    }
    if(prod){
      if(!v.year) v.year = normYear(prod.releaseDate) || normYear(prod.name) || null;
      if(!v.images && prod.image){ const arr = Array.isArray(prod.image)? prod.image:[prod.image]; v.images = (v.images||[]).concat(arr); }
    }

    // VIN fallback
    if(!v.vin){ const m = document.body.innerText.match(/\b([A-HJ-NPR-Z0-9]{17})\b/); if(m) v.vin = m[1]; }

    // Title/meta fallback
    const t = meta("og:title") || meta("twitter:title") || document.title || text(document.querySelector("h1,h2"));
    const fromTitle = parseYMMT(t) || {};
    v.year  = v.year  || fromTitle.year  || normYear(text(document.querySelector("h1,h2"))) || null;
    v.make  = v.make  || fromTitle.make  || null;
    v.model = v.model || fromTitle.model || null;
    v.trim  = v.trim  || fromTitle.trim  || null;

    // Labeled year
    const yLab = normYear(getByLabel(["Model Year","Year"]));
    v.year = v.year || yLab || null;

    // Price & mileage
    const jsonLdPrice = num(node?.offers?.price) || num(prod?.offers?.price) || null;
    v.price   = findPriceSmart(jsonLdPrice);
    v.mileage = (v.mileage ?? findMileageSmart(null));

    // Other specs
    v.exteriorColor = v.exteriorColor || getByLabel(["Exterior Color","Exterior color","Exterior"]);
    v.interiorColor = v.interiorColor || getByLabel(["Interior Color","Interior color","Interior"]);
    v.transmission  = v.transmission  || getByLabel(["Transmission"]);
    v.engine        = v.engine        || getByLabel(["Engine"]);
    v.drivetrain    = v.drivetrain    || getByLabel(["Drivetrain","Drive Type","Drive type"]);

    // Description fallback
    if(!v.description){
      const long = Array.from(document.querySelectorAll("p,div")).map(text).filter(x=>x.length>180).sort((a,b)=>b.length-a.length)[0];
      if(long) v.description = long;
    }

    // Images
    const imgs = collectImages();
    v.images = Array.from(new Set((v.images||[]).concat(imgs)));

    return v;
  }

  async function captureFlow(){
    status.textContent="Preparing page…";
    await expandAndScroll();
    const v = scrapeVehicle();

    content.innerHTML="";
    const rows=[
      ["Year", v.year],["Make", v.make],["Model", v.model],["Trim", v.trim],
      ["Price", v.price!=null?formatUSD(v.price):""],
      ["Mileage", v.mileage!=null? Number(v.mileage).toLocaleString():""],
      ["VIN", v.vin],["Exterior", v.exteriorColor],["Interior", v.interiorColor],
      ["Transmission", v.transmission],["Engine", v.engine],["Drivetrain", v.drivetrain],
      ["Images", (v.images||[]).length]
    ];
    for(const [k,val] of rows){
      const r=document.createElement("div"); r.className="vp-row"; r.innerHTML=`<b>${k}</b><div>${val??""}</div>`; content.appendChild(r);
    }
    if(v.description){
      const r=document.createElement("div"); r.className="vp-row"; r.style.gridTemplateColumns="1fr";
      r.innerHTML=`<div><b>Description</b><div style="margin-top:4px;white-space:pre-wrap;">${v.description.replace(/[&<>"']/g,m=>({"&":"&amp;","<":"&lt;",">":"&gt;","\"":"&quot;","'":"&#039;"}[m]))}</div></div>`;
      content.appendChild(r);
    }
    window.__vp_vehicle=v;
    status.textContent="Ready ✅";
  }

  async function ping(){ try{ const r=await fetch(BRIDGE+"/ping",{cache:"no-store"}); const j=await r.json(); status.textContent=j?.ok?"Bridge connected ✅":"Bridge not responding"; return !!j?.ok; }catch{ status.textContent="Bridge not running ❌ — start Node project"; return false; } }
  ping();

  btn.addEventListener("click", async ()=>{ panel.classList.toggle("open"); if(panel.classList.contains("open")) await captureFlow(); });
  $("#vp-copy").addEventListener("click", async ()=>{ try{ await navigator.clipboard.writeText(JSON.stringify(window.__vp_vehicle||{},null,2)); copyBtn.textContent="Copied ✅"; setTimeout(()=>copyBtn.textContent="Copy JSON",1200);}catch(e){alert("Copy failed: "+e.message)}});
  $("#vp-images").addEventListener("click", ()=>{ const urls=(window.__vp_vehicle?.images||[]).slice(0,30); if(!urls.length) return alert("No image URLs found."); urls.forEach((u,i)=>{ try{ chrome.downloads.download({ url:u, filename:`vehicle_photos/photo_${String(i+1).padStart(2,"0")}.jpg`, saveAs:false }); }catch{ window.open(u,"_blank"); } }); });
  $("#vp-send").addEventListener("click", async ()=>{ if(!await ping()) return alert("Node bridge not running."); try{ const r=await fetch(BRIDGE+"/capture",{method:"POST", headers:{ "Content-Type":"application/json" }, body: JSON.stringify(window.__vp_vehicle||{})}); const j=await r.json(); if(j.ok){ sendBtn.textContent="Sent ✅"; setTimeout(()=>sendBtn.textContent="Send to Node",1200);} else alert("Bridge error: "+(j.error||"unknown")); }catch(e){ alert("Failed to contact bridge: "+e.message); } });
})();
'@

# tiny placeholder icons
$png = [Convert]::FromBase64String("iVBORw0KGgoAAAANSUhEUgAAAA4AAAAOCAYAAAAfSC3RAAAAHElEQVQoka3MsQkAIBAEwZr9/1g1m2JwJqg3k4mHMe1Qv3cT7bW3fQAAAABJRU5ErkJggg==")
[IO.File]::WriteAllBytes((Join-Path $extDir "assets\icon16.png"), $png)
[IO.File]::WriteAllBytes((Join-Path $extDir "assets\icon48.png"), $png)
[IO.File]::WriteAllBytes((Join-Path $extDir "assets\icon128.png"), $png)

Write-Host "`n✅ Created:" -ForegroundColor Green
Write-Host "  $nodeDir"
Write-Host "  $extDir"
Write-Host "`nNext steps:" -ForegroundColor Yellow
Write-Host "  1) cd .\vehicle-poster-node-bridge"
Write-Host "     $env:PUPPETEER_SKIP_DOWNLOAD = 'true'"
Write-Host "     npm i --no-audit --no-fund"
Write-Host "     copy .env.example .env   # fill FACEBOOK_EMAIL/PASSWORD or log in manually"
Write-Host "     npm start                # http://127.0.0.1:5566"
Write-Host ""
Write-Host "  2) Chrome → chrome://extensions → Developer mode → Load unpacked → select vehicle-poster-extension"
Write-Host "     Hard refresh the vehicle page (Ctrl+Shift+R)."
Write-Host "     Click Capture Vehicle → Send to Node. The console preview should show a 4-digit Year and real Mileage."
