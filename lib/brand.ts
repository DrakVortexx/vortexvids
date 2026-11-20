/**
 * The vortexvids marks, in one place so the header, the favicon, the press kit
 * and the maintenance page all draw the same thing.
 *
 * The mark is a purple spiral vortex design.
 * The Snips mark (short vertical videos) is a smaller vortex spiral.
 * Both are our own drawings: no play button, no red rectangle.
 */

/** Both marks are drawn on a 24 by 24 grid. */
export const MARK_VIEWBOX = "0 0 24 24";

/** The main vortex spiral, filled with the brand purple. */
export const MARK_BLOB =
  "M12 2C6.5 2 2 6.5 2 12s4.5 10 10 10 10-4.5 10-10S17.5 2 12 2zm0 2c4.4 0 8 3.6 8 8s-3.6 8-8 8-8-3.6-8-8 3.6-8 8-8zm0 3c-2.8 0-5 2.2-5 5s2.2 5 5 5 5-2.2 5-5-2.2-5-5-5zm0 2c1.7 0 3 1.3 3 3s-1.3 3-3 3-3-1.3-3-3 1.3-3 3-3z";

/** The inner spiral lines, stroked in white. */
export const MARK_WAVE = "M12 8c-2.2 0-4 1.8-4 4s1.8 4 4 4 4-1.8 4-4-1.8-4-4-4zm0 2c1.1 0 2 .9 2 2s-.9 2-2 2-2-.9-2-2 .9-2 2-2z";

/** The Snips vortex. */
export const SNIPS_DROP = "M12 2C6.5 2 2 6.5 2 12s4.5 10 10 10 10-4.5 10-10S17.5 2 12 2zm0 3c-3.9 0-7 3.1-7 7s3.1 7 7 7 7-3.1 7-7-3.1-7-7-7zm0 2c2.8 0 5 2.2 5 5s-2.2 5-5 5-5-2.2-5-5 2.2-5 5-5z";

/** The wave inside the Snips vortex. */
export const SNIPS_WAVE = "M12 8c-2.2 0-4 1.8-4 4s1.8 4 4 4 4-1.8 4-4-1.8-4-4-4zm0 2c1.1 0 2 .9 2 2s-.9 2-2 2-2-.9-2-2 .9-2 2-2z";

/** Brand colors, also set as --mark and --logo-word in app/globals.css. */
export const BRAND = {
  mark: "#7c3aed",
  markDark: "#8b5cf6",
  word: "#6d28d9",
  wordDark: "#a78bfa",
} as const;

/** The mark as a standalone SVG string (press kit, favicon, maintenance page). */
export function markSvg(size = 24, color: string = BRAND.mark): string {
  return (
    `<svg xmlns="http://www.w3.org/2000/svg" width="${size}" height="${size}" viewBox="${MARK_VIEWBOX}">` +
    `<path d="${MARK_BLOB}" fill="${color}"/>` +
    `<path d="${MARK_WAVE}" fill="none" stroke="#fff" stroke-width="1.5" stroke-linecap="round"/>` +
    `</svg>`
  );
}

/** The mark and the two tone wordmark ("vortex" in purple, "vids" in near black). */
export function logoSvg(): string {
  return (
    `<svg xmlns="http://www.w3.org/2000/svg" width="560" height="120" viewBox="0 0 140 30">` +
    `<g transform="translate(1 2) scale(1.08)"><path d="${MARK_BLOB}" fill="${BRAND.mark}"/>` +
    `<path d="${MARK_WAVE}" fill="none" stroke="#fff" stroke-width="1.5" stroke-linecap="round"/></g>` +
    `<text x="30" y="21" font-family="Roboto, Arial, sans-serif" font-size="20" font-weight="700" letter-spacing="-0.9">` +
    `<tspan fill="${BRAND.word}">vortex</tspan><tspan fill="#030303">vids</tspan></text>` +
    `</svg>`
  );
}
