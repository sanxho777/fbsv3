export function normalizeColor(raw) {
  if (raw == null) return null;
  const s = String(raw).toLowerCase();

  const rules = [
    [/^(jet\s*)?black|ebony|onyx|midnight\s*black/, "Black"],
    [/slate|graphite|charcoal|gunmetal|dark\s*grey|dark\s*gray/, "Gray"],
    [/silver|aluminum|argent/, "Silver"],
    [/white|ivory|pearl|alabaster|snow/, "White"],
    [/blue|navy|indigo|cobalt|azure|teal|aqua/, "Blue"],
    [/red|maroon|burgundy|crimson/, "Red"],
    [/brown|bronze|mocha|cocoa|coffee|chocolate/, "Brown"],
    [/beige|tan|sand|cream|khaki|linen/, "Beige"],
    [/green|emerald|olive|forest/, "Green"],
    [/gold|champagne/, "Gold"],
    [/yellow|lemon|sulfur/, "Yellow"],
    [/orange|copper|tangerine/, "Orange"],
    [/purple|plum|violet|amethyst/, "Purple"]
  ];

  for (const [re, label] of rules) {
    if (re.test(s)) return label;
  }
  // Title-case fallback
  return String(raw).replace(/\w\S*/g, w => w[0].toUpperCase() + w.slice(1).toLowerCase());
}
