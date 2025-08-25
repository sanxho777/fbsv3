export const parseMiles = (input) => {
  const s = String(input ?? "");
  const nearMi = s.match(/(\d{1,3}(?:,\d{3})+|\d{2,6})\s*(?:mi\.?|miles?)/i);
  if (nearMi) return parseInt(nearMi[1].replace(/,/g,""),10);
  const m = s.match(/(\d{1,3}(?:,\d{3})+|\d{2,6})/);
  return m ? parseInt(m[1].replace(/,/g,""),10) : null;
};
export const roundedMileage = (val) => {
  const n = typeof val === "number" ? val : parseMiles(val);
  if (!Number.isFinite(n)) return "";  // leave blank if unknown
  return String(Math.floor(n/1000)*1000);
};
export const titleFromParts = (v) => {
  const bits = [v.year, v.make, v.model, v.trim].filter(Boolean);
  return bits.join(" ").trim().slice(0,100);
};
export const defaultDescription = (v) => {
  const title = titleFromParts(v);
  const lines = [
    `${title}`,
    v.mileage ? `Mileage: ${typeof v.mileage==="number"?v.mileage.toLocaleString():v.mileage}` : null,
    v.drivetrain ? `Drivetrain: ${v.drivetrain}` : null,
    v.engine ? `Engine: ${v.engine}` : null,
    v.transmission ? `Transmission: ${v.transmission}` : null,
    v.exteriorColor ? `Exterior: ${v.exteriorColor}` : null,
    v.interiorColor ? `Interior: ${v.interiorColor}` : null,
    "",
    "Available now at Capitol Chevrolet — schedule your test drive today!"
  ].filter(Boolean);
  return lines.join("\\n");
};
