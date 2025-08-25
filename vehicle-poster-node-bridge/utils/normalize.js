export function normalizeColors(obj = {}) {
  const pick = (...xs) => xs.find(x => typeof x === 'string' && x.trim()) || null;
  const exterior = pick(obj.exterior, obj.exteriorColor, obj.Exterior, obj.extColor, obj.color_exterior);
  const interior = pick(obj.interior, obj.interiorColor, obj.Interior, obj.intColor, obj.color_interior);

  if (exterior) {
    obj.exterior = obj.exteriorColor = obj.Exterior = obj.extColor = obj.color_exterior = exterior;
  }
  if (interior) {
    obj.interior = obj.interiorColor = obj.Interior = obj.intColor = obj.color_interior = interior;
  }

  // also normalize inside common wrappers if present
  for (const k of ['preview','vehicle','data','form']) {
    if (obj[k] && typeof obj[k] === 'object') normalizeColors(obj[k]);
  }
  return obj;
}
