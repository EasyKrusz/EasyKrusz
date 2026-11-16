// Minimalny service worker - potrzebny, żeby aplikację dało się zainstalować
// i żeby pojawiła się w menu "Udostępnij" na Androidzie. Bez cache'owania API.
self.addEventListener("install", () => self.skipWaiting());
self.addEventListener("activate", (e) => e.waitUntil(self.clients.claim()));
self.addEventListener("fetch", () => {});
