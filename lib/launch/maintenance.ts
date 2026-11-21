// Maintenance mode (feature 15). proxy.ts answers every page with this one
// static page (status 503) while the maintenance flag is on, except for
// admins, and every API route with { error: "maintenance" }. No database, no
// React: it works even when the rest of the site does not. No imports, so the mark
// below is a copy of lib/brand.ts (tests/brand.test.mjs keeps them in step).

/** Paths that still work during maintenance, so an admin can sign in and check the site. */
export function maintenanceOpen(path: string): boolean {
  return (
    path === "/login" ||
    path === "/signup" ||
    path.startsWith("/auth/") ||
    path === "/robots.txt" ||
    path === "/api/health" ||
    path === "/api/version"
  );
}

/** How long browsers and crawlers are asked to wait before trying again, in seconds. */
export const RETRY_AFTER_S = 600;

/** How long proxy.ts keeps the maintenance flag before reading it again, in milliseconds. */
export const FLAG_TTL_MS = 15_000;

function escapeHtml(s: string): string {
  return s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");
}

/** The whole page: the logo, one line, one grey line, the 2019 look in light or dark like the rest of the site. */
export function maintenanceHtml(siteName = "vortexvids"): string {
  const name = escapeHtml(siteName);
  return `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="robots" content="noindex">
<title>Back soon | ${name}</title>
<script>try{if(localStorage.getItem("sloptube-theme")==="dark")document.documentElement.className="dark"}catch(e){}</script>
<style>
:root{--page:#faf5ff;--text:#1e0a2e;--text-2:#6b4a8c;--word:#6d28d9;--card:#ffffff;--line:#e9d5ff}
.dark{--word:#a78bfa;--page:#1a0b2e;--text:#f3e8ff;--text-2:#c4b5fd;--card:#2b1b3d;--line:#4a2966}
*{box-sizing:border-box}
html,body{margin:0;height:100%;background:var(--page);color:var(--text);font-family:Roboto,Arial,sans-serif}
main{min-height:100%;display:flex;flex-direction:column;align-items:center;justify-content:center;padding:24px;text-align:center}
.logo{display:flex;align-items:center;gap:4px;margin-bottom:32px}
.logo span{font-size:24px;font-weight:700;letter-spacing:-1px;color:var(--word)}
.card{max-width:480px;background:var(--card);border:1px solid var(--line);border-radius:2px;padding:32px 24px}
h1{margin:0;font-size:20px;font-weight:400;line-height:28px}
p{margin:8px 0 0;font-size:14px;line-height:20px;color:var(--text-2)}
</style>
</head>
<body>
<main data-error-state="maintenance">
<div class="logo" aria-label="${name}"><svg viewBox="0 0 24 24" width="28" height="28" aria-hidden="true"><path d="M12 2C6.5 2 2 6.5 2 12s4.5 10 10 10 10-4.5 10-10S17.5 2 12 2zm0 2c4.4 0 8 3.6 8 8s-3.6 8-8 8-8-3.6-8-8 3.6-8 8-8zm0 3c-2.8 0-5 2.2-5 5s2.2 5 5 5 5-2.2 5-5-2.2-5-5-5zm0 2c1.7 0 3 1.3 3 3s-1.3 3-3 3-3-1.3-3-3 1.3-3 3-3z" fill="#7c3aed"/><path d="M12 8c-2.2 0-4 1.8-4 4s1.8 4 4 4 4-1.8 4-4-1.8-4-4-4zm0 2c1.1 0 2 .9 2 2s-.9 2-2 2-2-.9-2-2 .9-2 2-2z" fill="none" stroke="#fff" stroke-width="1.5" stroke-linecap="round"/></svg><span>${name}</span></div>
<div class="card">
<h1>We're doing some maintenance.</h1>
<p>${name} will be back in a few minutes. Thanks for your patience.</p>
</div>
</main>
</body>
</html>
`;
}
