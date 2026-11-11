// Service worker — за инсталиране като приложение и за показване на последната версия без интернет.
// Винаги първо от мрежата (новите версии идват веднага); кешът е само резерва, ако няма връзка.
// Заявките към базата (supabase.co) не минават оттук — те са към друг адрес.
const CACHE = "zayavki-shell-v1";
const SHELL = ["./", "./index.html", "./manifest.json", "./icon.png", "./pravila.html"];

self.addEventListener("install", e => {
  e.waitUntil(caches.open(CACHE).then(c => c.addAll(SHELL)).catch(() => {}));
  self.skipWaiting();
});

self.addEventListener("activate", e => {
  e.waitUntil(caches.keys().then(ks => Promise.all(ks.filter(k => k !== CACHE).map(k => caches.delete(k)))).then(() => self.clients.claim()));
});

self.addEventListener("fetch", e => {
  const req = e.request, url = new URL(req.url);
  if (req.method !== "GET" || url.origin !== self.location.origin) return; // базата и външните адреси — без намеса
  e.respondWith(
    fetch(req).then(res => {
      if (res.ok && (req.mode === "navigate" || SHELL.some(p => url.pathname.endsWith(p.replace("./", "/"))))) {
        const copy = res.clone(); caches.open(CACHE).then(c => c.put(req.mode === "navigate" ? "./index.html" : req, copy));
      }
      return res;
    }).catch(() => caches.match(req.mode === "navigate" ? "./index.html" : req).then(r => r || caches.match("./index.html")))
  );
});
