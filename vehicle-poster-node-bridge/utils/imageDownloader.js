import fs from "fs";
import path from "path";
import { pipeline } from "stream";
import { promisify } from "util";
const streamPipeline = promisify(pipeline);

export async function ensureDir(dir){ await fs.promises.mkdir(dir, { recursive: true }); }

function pickExt(url, contentType){
  const m = url.split("?")[0].match(/\.(jpe?g|png|webp|gif|bmp)$/i);
  if (m) return "."+m[1].toLowerCase();
  if (/webp/i.test(contentType||"")) return ".webp";
  if (/png/i.test(contentType||"")) return ".png";
  return ".jpg";
}

export async function downloadImages(urls=[], outDir){
  await ensureDir(outDir);
  const saved = [];
  let i = 1;
  for (const url of urls){
    try{
      const res = await fetch(url, { redirect:"follow" });
      if (!res.ok || !res.body) continue;
      const ext = pickExt(url, res.headers.get("content-type")||"");
      const file = path.join(outDir, String(i).padStart(2,"0")+ext);
      await streamPipeline(res.body, fs.createWriteStream(file));
      saved.push(file);
      i++;
    }catch(e){ /* ignore single image errors */ }
  }
  return saved;
}
