/* 옛 주소의 서비스 워커를 끝내는 파일 — 옛 앱 캐시를 지우고 스스로 물러납니다 */
self.addEventListener("install",function(){ self.skipWaiting(); });
self.addEventListener("activate",function(e){
  e.waitUntil(caches.keys().then(function(ks){ return Promise.all(ks.map(function(k){ return caches.delete(k); })); })
    .then(function(){ return self.registration.unregister(); })
    .then(function(){ return self.clients.matchAll(); })
    .then(function(cs){ cs.forEach(function(c){ c.navigate(c.url); }); }));
});
