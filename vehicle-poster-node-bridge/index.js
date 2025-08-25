// index.js
import "dotenv/config";
import fs from "fs";
import path from "path";
import express from "express";
import cors from "cors";
import puppeteer from "puppeteer-extra";
import StealthPlugin from "puppeteer-extra-plugin-stealth";
import inquirer from "inquirer";
import { fileURLToPath } from "url";

import { titleFromParts, defaultDescription, parseMiles } from "./utils/formatter.js";
import { downloadImages, ensureDir } from "./utils/imageDownloader.js";
import { normalizeColor } from "./utils/colorMap.js";      // maps Slate -> Gray, etc.
import { normalizeColors } from "./utils/normalize.js";     // flattens extension keys

puppeteer.use(StealthPlugin());

const __filename = fileURLToPath(import.meta.url);
const __dirname  = path.dirname(__filename);

const {
  FACEBOOK_EMAIL,
  FACEBOOK_PASSWORD,
  USER_DATA_DIR = path.join(__dirname, ".chrome-profile"),
  CHROME_EXECUTABLE,
  USER_AGENT = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
  PORT = "3233",                                 // 👈 default to 3233
  FB_LOGIN_MAX_WAIT_MS = 10 * 60 * 1000,
  FB_LOGIN_POLL_MS     = 1500,
  FB_MARKETPLACE_MAX_WAIT_MS = 120000,
  DEBUG_SHOTS_DIR = "",
  FORCE_VEHICLE_TYPE = "Car/van",
  WAIT_FOR_ENTER = "1"
} = process.env;

// ------------------------------- utils -------------------------------
const sleep = (ms) => new Promise(r => setTimeout(r, ms));
const dbg = async (page, name) => {
  if (!DEBUG_SHOTS_DIR) return;
  try {
    await ensureDir(DEBUG_SHOTS_DIR);
    const file = path.join(DEBUG_SHOTS_DIR, `${Date.now()}_${name}.png`);
    await page.screenshot({ path: file, fullPage: false });
    console.log(file);
  } catch {}
};
const norm = (s) => String(s ?? "").toLowerCase().replace(/\s+/g, " ").trim();
const uniq = (arr) => [...new Set(arr.filter(Boolean).map(s => String(s).trim()))];

// Locale-aware candidate builders
function colorCandidates(raw){
  const s = String(raw || "");
  const base = normalizeColor(s); // our normalized label (e.g., “Gray”)
  const cands = [s, base];

  // grey family synonyms
  if (/slate|graphite|charcoal|gunmetal|grey|gray/i.test(s) || /gray/i.test(base)) {
    cands.push("Grey","Gray","Slate");
  }
  // common colours — ensure we try the exact normalized word too
  const common = ["Black","White","Silver","Blue","Red","Brown","Beige","Green","Gold","Yellow","Orange","Purple"];
  if (common.includes(base)) cands.push(base);

  return uniq(cands);
}
function fuelCandidates(v){
  // infer from description/engine; then add locale synonyms
  const text = `${v.engine||""} ${v.description||""}`.toLowerCase();
  let inferred = "Gasoline";
  if (/electric|ev|kwh|kilowatt/.test(text)) inferred = "Electric";
  else if (/hybrid|hev|plug-?in|phev/.test(text)) inferred = "Hybrid";
  else if (/diesel|tdi|duramax|cummins/.test(text)) inferred = "Diesel";

  const c = [inferred];
  if (/gas/i.test(inferred) || inferred === "Gasoline") c.push("Petrol","Gas","Gasoline");
  if (inferred === "Diesel")   c.push("Diesel");
  if (inferred === "Hybrid")   c.push("Hybrid");
  if (inferred === "Electric") c.push("Electric");
  return uniq(c);
}
function inferBodyStyle(v){
  const m = `${v.make||""} ${v.model||""} ${v.trim||""}`.toLowerCase();
  if (/truck|pickup|f-?150|silverado|ram|tundra|sierra|tacoma/.test(m)) return "Truck";
  if (/van|minivan|transit|sienna|odyssey|caravan|pacifica|sprinter|promaster/.test(m)) return "Van";
  if (/coupe|mustang|challenger|camaro|brz|86|supra/.test(m)) return "Coupe";
  if (/convertible|roadster|spider|spyder|cabrio/.test(m)) return "Convertible";
  if (/hatch|golf|fit|yaris|versa|impreza hatch/.test(m)) return "Hatchback";
  if (/wagon|outback|allroad/.test(m)) return "Wagon";
  if (/suv|trailblazer|equinox|tahoe|suburban|escape|rav4|cr-?v|pilot|highlander|explorer|blazer|cx-|nx|rx|gv|x[3-7]|gl|telluride|seltos|palisa/i.test(m)) return "SUV";
  return "Sedan";
}
function inferTransmission(v){
  const t = `${v.transmission||""}`.toLowerCase();
  if (/manual|mt/.test(t)) return "Manual transmission";
  if (/cvt/.test(t)) return "CVT";
  return "Automatic transmission";
}
function conditionLabel(miles){
  const n = parseMiles(miles) ?? 0;
  return n>0 && n<30000 ? "Used – Like New" : "Used – Good";
}

// ---------------------- puppeteer: browser & login -------------------
let browser;
async function getBrowser(){
  if (browser) return browser;
  await ensureDir(USER_DATA_DIR);
  browser = await puppeteer.launch({
    headless: false,
    executablePath: CHROME_EXECUTABLE || undefined,
    args: [
      `--user-data-dir=${USER_DATA_DIR}`,
      "--no-sandbox",
      "--disable-setuid-sandbox",
      "--disable-blink-features=AutomationControlled",
      "--lang=en-US,en"
    ]
  });
  return browser;
}

async function ensureFacebookReady(page){
  const maxWait = Number(FB_LOGIN_MAX_WAIT_MS) || (10*60*1000);
  const poll    = Number(FB_LOGIN_POLL_MS) || 1500;

  console.log("Opening Facebook…");
  await page.goto("https://www.facebook.com/", { waitUntil: "domcontentloaded" });

  if (await page.$('input[name="email"]')) {
    if (FACEBOOK_EMAIL && FACEBOOK_PASSWORD) {
      console.log("Filling credentials…");
      await page.type('input[name="email"]', FACEBOOK_EMAIL, {delay:20});
      await page.type('input[name="pass"]',  FACEBOOK_PASSWORD, {delay:20});
      await Promise.all([
        page.click('button[name="login"]'),
        page.waitForNavigation({waitUntil:"domcontentloaded", timeout:60000}).catch(()=>{})
      ]);
    } else {
      console.log("On login page. Please sign in manually.");
    }
  }

  const start = Date.now();
  let lastUrl = "";
  while (Date.now() - start < maxWait) {
    const url = page.url();
    if (url !== lastUrl) { lastUrl = url; console.log("FB at", url); }

    const isCheckpoint = /facebook\.com\/.*(checkpoint|two_factor|login\/checkpoint|device-based|save-device)/i.test(url);
    if (isCheckpoint) console.log("Login verification detected — complete it in the browser. I’ll wait.");

    const cookies = await page.cookies().catch(()=>[]);
    const hasSession = cookies.some(c => c.name === "c_user" && c.value);
    const isLoggedInUI = await page.evaluate(() => {
      return !!document.querySelector('a[aria-label="Account"], [aria-label="Your profile"], [data-click="profile_icon"]');
    }).catch(()=>false);

    if (hasSession && isLoggedInUI && !isCheckpoint) {
      console.log("Facebook session ready.");
      return true;
    }
    await sleep(poll);
  }
  throw new Error("Timed out waiting for Facebook login/verification.");
}

// ---------------------- page helpers (fb form) -----------------------
async function clickByText(page, selectors, pattern, waitAfter=600){
  const sel = Array.isArray(selectors) ? selectors.join(",") : String(selectors);
  const re  = pattern instanceof RegExp ? pattern : new RegExp(pattern, "i");
  const handles = await page.$$(sel);
  for (const h of handles) {
    const t = await page.evaluate(el => (el.innerText || el.textContent || "").trim(), h);
    if (re.test(t || "")) {
      await h.click().catch(()=>{});
      await sleep(waitAfter);
      return true;
    }
  }
  return false;
}

async function ensureMarketplaceLanding(page){
  const maxWait = Number(FB_MARKETPLACE_MAX_WAIT_MS) || 120000;
  const start = Date.now();
  while (Date.now() - start < maxWait) {
    if (!/facebook\.com\/marketplace\/.*create/i.test(page.url())) {
      await page.goto("https://www.facebook.com/marketplace/create/vehicle", { waitUntil:"domcontentloaded" }).catch(()=>{});
      await sleep(900);
    }
    const hasStep1 = await page.evaluate(()=>{
      const txt = el=>(el?.innerText||el?.textContent||"").toLowerCase();
      return !!Array.from(document.querySelectorAll("div,label,span"))
        .find(el=>/vehicle type|about this vehicle|year\b/.test(txt(el)));
    }).catch(()=>false);
    if (hasStep1) return true;

    await clickByText(page, ['div[role="button"]','button','div','a[role="link"]'],
      /(Vehicle for sale|Vehicle|Create listing|Create Listing|Get started|Get Started|Continue|Next)/);
    await sleep(700);
  }
  throw new Error("Marketplace first step did not load in time.");
}

async function selectComboByLabel(page, labelRegex, value){
  if (value === undefined || value === null || value === "") return false;
  const re = labelRegex instanceof RegExp ? labelRegex : new RegExp(labelRegex, "i");

  const combos = await page.$$('[role="combobox"], div[role="combobox"], label[role="combobox"]');
  for (const h of combos) {
    const isMatch = await page.evaluate((el, reSrc)=>{
      const re = new RegExp(reSrc, "i");
      const self = (el.innerText || el.textContent || "").trim();
      const near = (el.closest("label")?.innerText || el.parentElement?.innerText || "").trim();
      return re.test(self) || re.test(near);
    }, h, re.source);
    if (!isMatch) continue;

    await h.click().catch(()=>{});
    await sleep(200);

    await page.waitForSelector('[role="listbox"], [role="menu"], [role="dialog"]', { timeout: 3000 }).catch(()=>{});
    const options = await page.$$('div[role="listbox"] [role="option"], [role="menu"] [role="menuitem"], [role="listbox"] span');

    const target = norm(value);
    let clicked = false;

    for (const o of options) {
      const t = await page.evaluate(el => (el.innerText||el.textContent||"").trim(), o);
      if (norm(t) === target) { await o.click().catch(()=>{}); clicked = true; break; }
    }

    if (!clicked) {
      const searchSel = [
        'div[role="listbox"] input[aria-label="Search"]:not([aria-label*="Facebook"])',
        'div[role="dialog"]  input[aria-label="Search"]:not([aria-label*="Facebook"])',
        'div[role="listbox"] input[type="search"]:not([aria-label*="Facebook"])',
        'div[role="dialog"]  input[type="search"]:not([aria-label*="Facebook"])'
      ].join(',');
      const search = await page.$(searchSel);
      if (search) {
        await search.focus().catch(()=>{});
        await page.evaluate(el => { el.value=""; }, search).catch(()=>{});
        await page.type(searchSel, String(value), {delay:12}).catch(()=>{});
        await page.keyboard.press("Enter").catch(()=>{});
      } else {
        await page.keyboard.type(String(value), {delay:12}).catch(()=>{});
        await page.keyboard.press("Enter").catch(()=>{});
      }
      clicked = true;
    }

    // Guard: if FB navigated away (search results), go back
    if (!/facebook\.com\/marketplace\/.*create/i.test(page.url())) {
      await page.goBack({waitUntil:"domcontentloaded"}).catch(()=>{});
      await sleep(600);
    }
    return true;
  }
  return false;
}
async function selectComboFromList(page, labelRegex, values){
  for (const v of values) {
    if (!v) continue;
    const ok = await selectComboByLabel(page, labelRegex, v);
    if (ok) return true;
  }
  return false;
}

async function setEditable(page, handle, value){
  await handle.focus().catch(()=>{});
  await page.evaluate((el, val)=>{
    const ce = el && el.getAttribute && el.getAttribute("contenteditable")==="true";
    if (ce) {
      const sel = window.getSelection(); const r = document.createRange();
      el.focus(); r.selectNodeContents(el); sel.removeAllRanges(); sel.addRange(r);
      document.execCommand("insertText", false, String(val));
      el.dispatchEvent(new InputEvent("input",{bubbles:true}));
      el.dispatchEvent(new Event("change",{bubbles:true}));
      return;
    }
    if (el && ("value" in el)) {
      const proto = el.tagName.toLowerCase()==="textarea" ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
      const setVal = Object.getOwnPropertyDescriptor(proto,"value").set;
      setVal.call(el, String(val));
      el.dispatchEvent(new InputEvent("input",{bubbles:true}));
      el.dispatchEvent(new Event("change",{bubbles:true}));
    }
  }, handle, value);
}
async function fillByLabel(page, labels, value, pressEnter=false){
  if (value==null || value==="") return false;
  const labelSet = (Array.isArray(labels)?labels:[labels]).map(s=>s.toLowerCase());
  const candidates = await page.$$('input, textarea, [role="textbox"], [contenteditable="true"]');
  for (const h of candidates) {
    const blob = await page.evaluate(el=>{
      const txt = n => (n?.innerText||n?.textContent||"").toLowerCase();
      const id  = el.id || "";
      const aria= (el.getAttribute?.("aria-label")||"").toLowerCase();
      const ph  = (el.getAttribute?.("placeholder")||"").toLowerCase();
      const labelledby = (el.getAttribute?.("aria-labelledby")||"").split(/\s+/).map(i=>document.getElementById(i)).map(txt).join(" ");
      const labFor = id ? txt(document.querySelector(`label[for="${id}"]`)) : "";
      const parentLab = txt(el.closest("label"));
      const near = txt(el.parentElement);
      return [aria, ph, labelledby, labFor, parentLab, near].join(" ");
    }, h);
    if (labelSet.some(k=>blob.includes(k))) {
      await page.evaluate(el=>el.scrollIntoView({behavior:"instant", block:"center"}), h).catch(()=>{});
      await setEditable(page, h, value);
      if (pressEnter) await page.keyboard.press("Enter").catch(()=>{});
      await sleep(120);
      return true;
    }
  }
  return false;
}
async function setCheckboxByLabel(page, labelPattern, checked=true){
  const re = labelPattern instanceof RegExp ? labelPattern : new RegExp(labelPattern, "i");
  const nodes = await page.$$('label, div, span');
  for (const n of nodes) {
    const t = await page.evaluate(el => (el.innerText||el.textContent||"").trim(), n);
    if (!re.test(t)) continue;
    const box = await page.evaluateHandle(el=>{
      let c = el.querySelector('input[type="checkbox"]');
      if (c) return c;
      c = el.closest("label")?.querySelector('input[type="checkbox"]');
      if (c) return c;
      return el.parentElement?.querySelector('input[type="checkbox"]');
    }, n);
    if (!box) continue;
    const isChecked = await page.evaluate(el=>el.checked, box).catch(()=>false);
    if (Boolean(isChecked) !== Boolean(checked)) {
      await page.evaluate(el=>el.click(), box).catch(()=>{});
      await sleep(150);
    }
    return true;
  }
  return false;
}
async function clickNextWhenEnabled(page){
  for (let i=0;i<14;i++){
    const btns = await page.$$('div[role="button"], button');
    for (const b of btns) {
      const lab = await page.evaluate(el=>{
        const t=(el.innerText||el.textContent||"").trim();
        const dis = el.getAttribute("aria-disabled")==="true" || el.hasAttribute("disabled");
        return JSON.stringify({t,dis});
      }, b);
      const {t,dis} = JSON.parse(lab||'{"t":""}');
      if (/^next$/i.test(t) && !dis){
        await b.click().catch(()=>{});
        await sleep(1000);
        return true;
      }
    }
    await sleep(800);
  }
  return false;
}
async function waitForEnter(message = "Close any popups, then press Enter to autofill"){
  if (String(WAIT_FOR_ENTER) !== "1") return;
  console.log(`\n  ${message}`);
  await inquirer.prompt([{ type: "input", name: "go", message: "Press Enter to continue" }]);
}

// ------------------------------ main fill ----------------------------
async function openFacebookAndFill(vehicle, imagePaths){
  const b = await getBrowser();
  const page = await b.newPage();
  await page.setUserAgent(USER_AGENT);
  await page.setExtraHTTPHeaders({ "accept-language":"en-US,en;q=0.9" });
  await page.setViewport({ width:1280, height:900, deviceScaleFactor:1 });

  await ensureFacebookReady(page);

  console.log("Opening Marketplace vehicle form");
  await page.goto("https://www.facebook.com/marketplace/create/vehicle", { waitUntil:"domcontentloaded" });
  await ensureMarketplaceLanding(page);

  await waitForEnter("On the 'Create vehicle' page. Close any popups, then press Enter to begin.");
  await dbg(page, "step1-loaded");

  // Combos: Vehicle type, Year, Make
  await selectComboByLabel(page, /vehicle type/, FORCE_VEHICLE_TYPE);
  await selectComboByLabel(page, /^year\b/i,  vehicle.year);
  await selectComboByLabel(page, /^make\b/i,  vehicle.make);

  // Text fields: Model, Mileage (exact), Price
  await fillByLabel(page, ["model"],  vehicle.model);
  const exactMiles = parseMiles(vehicle.mileage) ?? vehicle.mileage;
  await fillByLabel(page, ["mileage","odometer"], exactMiles);
  await fillByLabel(page, ["price"],  vehicle.price);

  // Appearance & details
  await selectComboByLabel(page, /body style|bodytype/, inferBodyStyle(vehicle));

  // Colours with synonyms (Grey/Gray/Slate etc.)
  const interiorNorm = normalizeColor(vehicle.interiorColor || "");
  await selectComboFromList(page, /exterior colou?r/, colorCandidates(vehicle.exteriorColor))
    || await fillByLabel(page, ["exterior colour","exterior color","exterior"], normalizeColor(vehicle.exteriorColor||""));
  await selectComboByLabel(page, /interior colou?r/, interiorNorm)
    || await fillByLabel(page, ["interior colour","interior color","interior"], interiorNorm);

  await setCheckboxByLabel(page, /clean title/, true);
  await selectComboByLabel(page, /vehicle condition|condition/, conditionLabel(exactMiles));

  // Fuel type with Petrol/Gas/Gasoline tolerance
  await selectComboFromList(page, /fuel type|fuel/, fuelCandidates(vehicle));

  await selectComboByLabel(page, /transmission/, inferTransmission(vehicle));

  await clickNextWhenEnabled(page);
  await sleep(900);
  await waitForEnter("Step 2 loaded. Press Enter to autofill remaining fields and upload photos.");
  await dbg(page, "step2-loaded");

  await fillByLabel(page, ["listing title","title"], titleFromParts(vehicle));
  const desc = (vehicle.description || defaultDescription(vehicle)).slice(0,9700);
  await fillByLabel(page, ["description","details","about"], desc);

  // Photos
  try{
    const fileInputs = await page.$$('input[type="file"]');
    if (fileInputs.length && (imagePaths?.length)) {
      for (const fi of fileInputs) { await fi.uploadFile(...imagePaths).catch(()=>{}); await sleep(400); }
    } else if (imagePaths?.length) {
      const clicked = await clickByText(page, ['div[role="button"]','button','div'], /(Add Photos?|Photos)/i, 400);
      if (clicked) {
        const chooser = await page.waitForFileChooser({ timeout: 4000 }).catch(()=>null);
        if (chooser) await chooser.accept(imagePaths);
      }
    }
  }catch{}

  await dbg(page, "after-fill");
  console.log("\nAutofill complete. Review and click Post.");
}

// ------------------------------ server -------------------------------
let busy=false;
async function handleCapture(payload){
  if(busy) return { ok:false, error:"busy" };
  busy=true;
  try{
    // Normalize aliases coming from extension
    payload = normalizeColors(payload || {});

    await fs.promises.writeFile(path.join(__dirname,"data","vehicle.json"), JSON.stringify(payload,null,2));
    const images = await downloadImages(payload.images||[], path.join(__dirname,"images"));

    console.log("\nVehicle:");
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
    console.error("Bridge error:", e);
    return { ok:false, error:String(e.message||e) };
  }finally{ busy=false; }
}

const app = express();
app.use(cors());
app.use(express.json({limit:"2mb"}));
app.get("/ping", (req,res)=>res.json({ok:true}));
app.post("/capture", async (req,res)=> res.json(await handleCapture(req.body||{})));

app.listen(Number(PORT)||3233, ()=> {
  console.log(`\nNode bridge on http://127.0.0.1:${PORT||3233}\n`);
});
