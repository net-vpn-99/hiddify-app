// Renders the OneRay / 光速 Android launcher + notification icons with no native deps.
//   node tool/gen_icons.js
// Geometry + colors are the frozen brand master (VPN repo: ui/one-ray/brand/final/
// oneray-mark.svg — circle r=112 @ (128,128), upper-right negative-space light slit).
// Writes the full mipmap set, adaptive foreground + monochrome, and the notification
// status-bar icon. No flutter_launcher_icons.
const fs = require("fs");
const zlib = require("zlib");
const path = require("path");

const RES = "android/app/src/main/res";
const GRAPHITE = [0x24, 0x25, 0x20];
const IVORY = [0xf3, 0xf1, 0xeb];
const WHITE = [0xff, 0xff, 0xff];
const SS = 4;

// Light-slit wedge from oneray-mark.svg, normalised to the r=112 master circle at
// (128,128). scaleBeam() keeps it proportional when the mark circle is resized.
const beam0 = [
  [196.9541, 39.7428],
  [103.0267, 146.328],
  [114.3067, 157.672],
  [220.8522, 65.3704],
].map(([x, y]) => [(x - 128) / 112, (y - 128) / 112]);
const scaleBeam = (r) => beam0.map(([x, y]) => [128 + x * r, 128 + y * r]);

function roundRectContains(x, y, w, h, r) {
  if (x < 0 || y < 0 || x > w || y > h) return false;
  const cx = Math.min(Math.max(x, r), w - r);
  const cy = Math.min(Math.max(y, r), h - r);
  if (x >= r && x <= w - r) return true;
  if (y >= r && y <= h - r) return true;
  return Math.hypot(x - cx, y - cy) <= r;
}
const dist = (x, y, cx, cy) => Math.hypot(x - cx, y - cy);
function polyContains(x, y, pts) {
  let inside = false;
  for (let i = 0, j = pts.length - 1; i < pts.length; j = i++) {
    const [xi, yi] = pts[i], [xj, yj] = pts[j];
    if (yi > y !== yj > y && x < ((xj - xi) * (y - yi)) / (yj - yi) + xi) inside = !inside;
  }
  return inside;
}

// mode:
//   "legacy" graphite rounded-square badge + ivory mark
//   "round"  graphite disc + ivory mark
//   "fg"     ivory mark only, transparent (adaptive foreground, safe zone)
//   "mono"   white mark only, transparent (Android 13 themed icon)
//   "notify" white mark only, transparent (status-bar small icon)
function render(size, mode) {
  const N = size * SS;
  const px = Buffer.alloc(N * N * 4, 0);
  // mark circle radius in the 256 master grid
  const markR =
    mode === "fg" || mode === "mono" ? 76 : mode === "notify" ? 92 : mode === "splash" ? 96 : mode === "splash12" ? 46 : 98;
  const beam = scaleBeam(markR);
  const markColor = mode === "mono" || mode === "notify" ? WHITE : IVORY;
  for (let py = 0; py < N; py++) {
    for (let pxi = 0; pxi < N; pxi++) {
      const x = (pxi / N) * 256, y = (py / N) * 256;
      let c = [0, 0, 0, 0];
      const inMark = dist(x, y, 128, 128) <= markR && !polyContains(x, y, beam);
      if (mode === "legacy") {
        if (roundRectContains(x, y, 256, 256, 56)) c = [...GRAPHITE, 255];
        if (inMark) c = [...markColor, 255];
      } else if (mode === "round") {
        if (dist(x, y, 128, 128) <= 128) c = [...GRAPHITE, 255];
        if (inMark) c = [...markColor, 255];
      } else {
        if (inMark) c = [...markColor, 255];
      }
      const o = (py * N + pxi) * 4;
      px[o] = c[0]; px[o + 1] = c[1]; px[o + 2] = c[2]; px[o + 3] = c[3];
    }
  }
  // box downscale
  const out = Buffer.alloc(size * size * 4);
  for (let y = 0; y < size; y++)
    for (let x = 0; x < size; x++) {
      let r = 0, g = 0, b = 0, a = 0;
      for (let dy = 0; dy < SS; dy++)
        for (let dx = 0; dx < SS; dx++) {
          const o = ((y * SS + dy) * N + (x * SS + dx)) * 4;
          const pa = px[o + 3];
          r += px[o] * pa; g += px[o + 1] * pa; b += px[o + 2] * pa; a += pa;
        }
      const oo = (y * size + x) * 4;
      out[oo] = a ? Math.round(r / a) : 0;
      out[oo + 1] = a ? Math.round(g / a) : 0;
      out[oo + 2] = a ? Math.round(b / a) : 0;
      out[oo + 3] = Math.round(a / (SS * SS));
    }
  return out;
}

let CRC;
function crc32(buf) {
  if (!CRC) {
    CRC = [];
    for (let n = 0; n < 256; n++) {
      let c = n;
      for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
      CRC[n] = c >>> 0;
    }
  }
  let c = 0xffffffff;
  for (let i = 0; i < buf.length; i++) c = CRC[(c ^ buf[i]) & 0xff] ^ (c >>> 8);
  return (c ^ 0xffffffff) >>> 0;
}
function writePng(file, rgba, w, h) {
  const ck = (t, d) => {
    const l = Buffer.alloc(4); l.writeUInt32BE(d.length);
    const td = Buffer.concat([Buffer.from(t), d]);
    const c = Buffer.alloc(4); c.writeUInt32BE(crc32(td));
    return Buffer.concat([l, td, c]);
  };
  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(w, 0); ihdr.writeUInt32BE(h, 4); ihdr[8] = 8; ihdr[9] = 6;
  const raw = Buffer.alloc(h * (w * 4 + 1));
  for (let y = 0; y < h; y++) rgba.copy(raw, y * (w * 4 + 1) + 1, y * w * 4, (y + 1) * w * 4);
  const png = Buffer.concat([
    Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]),
    ck("IHDR", ihdr), ck("IDAT", zlib.deflateSync(raw, { level: 9 })), ck("IEND", Buffer.alloc(0)),
  ]);
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, png);
  console.log(" ", file);
}

const LEGACY = { mdpi: 48, hdpi: 72, xhdpi: 96, xxhdpi: 144, xxxhdpi: 192 };
const FG = { mdpi: 108, hdpi: 162, xhdpi: 216, xxhdpi: 324, xxxhdpi: 432 };
const NOTIFY = { mdpi: 24, hdpi: 36, xhdpi: 48, xxhdpi: 72, xxxhdpi: 96 };

for (const [d, s] of Object.entries(LEGACY)) {
  writePng(`${RES}/mipmap-${d}/ic_launcher.png`, render(s, "legacy"), s, s);
  writePng(`${RES}/mipmap-${d}/ic_launcher_round.png`, render(s, "round"), s, s);
}
for (const [d, s] of Object.entries(FG)) {
  writePng(`${RES}/mipmap-${d}/ic_launcher_foreground.png`, render(s, "fg"), s, s);
  writePng(`${RES}/mipmap-${d}/ic_launcher_monochrome.png`, render(s, "mono"), s, s);
}
for (const [d, s] of Object.entries(NOTIFY)) {
  writePng(`${RES}/drawable-${d}/ic_stat_logo.png`, render(s, "notify"), s, s);
}
// Play Store / generic 512
fs.mkdirSync("assets/icon", { recursive: true });
writePng("assets/icon/icon-512.png", render(512, "legacy"), 512, 512);

// flutter_native_splash sources (bg color set in pubspec.yaml -> #242520)
writePng("assets/images/source/ic_launcher_splash.png", render(768, "splash"), 768, 768);
writePng("assets/images/source/ic_launcher_foreground.png", render(960, "splash12"), 960, 960);

// adaptive-icon xml (+ monochrome for Android 13 themed icons) + background color
const adaptive = `<?xml version="1.0" encoding="utf-8"?>
<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">
    <background android:drawable="@color/ic_launcher_background"/>
    <foreground android:drawable="@mipmap/ic_launcher_foreground"/>
    <monochrome android:drawable="@mipmap/ic_launcher_monochrome"/>
</adaptive-icon>
`;
fs.mkdirSync(`${RES}/mipmap-anydpi-v26`, { recursive: true });
fs.writeFileSync(`${RES}/mipmap-anydpi-v26/ic_launcher.xml`, adaptive);
fs.writeFileSync(`${RES}/mipmap-anydpi-v26/ic_launcher_round.xml`, adaptive);
fs.writeFileSync(
  `${RES}/values/ic_launcher_background.xml`,
  `<?xml version="1.0" encoding="utf-8"?>
<resources>
    <color name="ic_launcher_background">#242520</color>
</resources>
`,
);
console.log("done");
