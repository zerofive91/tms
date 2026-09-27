/* ═══ 네비게이토 암송 Festival · 오프라인 지원 ═══════════════════════
   이 파일이 하는 일은 하나입니다 — 앱 파일을 폰에 담아 두어
   인터넷이 없을 때도 앱이 열리게 합니다.

     ① 앱 화면(index.html)  : 인터넷 먼저, 느리거나 끊기면 저장본
        → 새 index.html 을 올리면 다음에 열 때 바로 반영됩니다.
     ② 붙박이 파일(아이콘·글꼴·supabase 스크립트) : 저장본 먼저
     ③ 기록 서버(supabase)  : 절대 저장하지 않습니다. 늘 서버로 갑니다.
        → 오프라인에서 한 채점이 서버에 올라간 것처럼 보이는 일은 없습니다.

   캐시 이름 뒤 숫자(v1)는 붙박이 파일 목록이 바뀔 때만 올리면 됩니다.
   앱 화면은 ① 때문에 숫자를 올리지 않아도 늘 최신이 나옵니다.        */

var CACHE   = "navfest-v2";   /* v2: manifest 에 바로가기를 넣었습니다 */
var PAGE_KEY = "./index.html";       /* 화면은 늘 이 이름으로 한 벌만 담습니다 */
var WAIT    = 2500;                  /* 이만큼 기다려 보고 응답이 없으면 저장본 */

/* 처음부터 담아 둘 것 — 하나쯤 실패해도 설치는 됩니다 */
var CORE  = ["./", "./index.html"];
var EXTRA = [
  "./manifest.json",
  "./icon-192.png",
  "./icon-512.png",
  "https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2.115.0/dist/umd/supabase.js",
  "https://fonts.googleapis.com/css2?family=Gowun+Batang:wght@400;700&family=IBM+Plex+Sans+KR:wght@400;500;600;700&display=swap"
];

self.addEventListener("install", function(e){
  e.waitUntil(
    caches.open(CACHE).then(function(c){
      return c.addAll(CORE).then(function(){
        return Promise.all(EXTRA.map(function(u){
          return c.add(u).catch(function(){});
        }));
      });
    }).then(function(){ return self.skipWaiting(); })
  );
});

self.addEventListener("activate", function(e){
  e.waitUntil(
    caches.keys().then(function(keys){
      return Promise.all(keys.map(function(k){
        return (k===CACHE) ? null : caches.delete(k);
      }));
    }).then(function(){ return self.clients.claim(); })
  );
});

/* 기록 서버로 가는 길은 손대지 않습니다 */
function isServer(url){
  return url.hostname.indexOf("supabase.co")>=0 ||
         url.pathname.indexOf("/rest/v1/")===0 ||
         url.pathname.indexOf("/auth/v1/")===0;
}
function isPage(req){
  if(req.mode==="navigate") return true;
  var a=req.headers.get("accept")||"";
  return a.indexOf("text/html")>=0;
}

self.addEventListener("fetch", function(e){
  var req=e.request;
  if(req.method!=="GET") return;                 /* 보내는 것은 늘 서버로 */
  var url;
  try{ url=new URL(req.url); }catch(err){ return; }
  if(url.protocol!=="http:" && url.protocol!=="https:") return;
  if(isServer(url)) return;

  e.respondWith(isPage(req) ? netFirst(req) : cacheFirst(req));
});

/* ① 인터넷 먼저 — 끊기거나 느리면 담아 둔 화면 */
function netFirst(req){
  return new Promise(function(resolve){
    var settled=false;
    function done(r){ if(!settled && r){ settled=true; resolve(r); } }

    var timer=setTimeout(function(){
      caches.match(PAGE_KEY).then(done);
    }, WAIT);

    fetch(req).then(function(res){
      clearTimeout(timer);
      if(res && res.ok && res.status===200){
        var copy=res.clone();
        caches.open(CACHE).then(function(c){ c.put(PAGE_KEY, copy); });
      }
      done(res);
    }).catch(function(){
      clearTimeout(timer);
      caches.match(PAGE_KEY).then(function(hit){
        done(hit || new Response(
          "<!doctype html><meta charset=utf-8><body style=\"font:16px/1.7 sans-serif;padding:40px;text-align:center\">"+
          "<p>인터넷이 없어 앱을 열지 못했습니다.<br>연결한 뒤 한 번만 열어 두면 다음부터는 오프라인에서도 열립니다.</p>",
          {status:200, headers:{"Content-Type":"text/html; charset=utf-8"}}));
      });
    });
  });
}

/* ② 담아 둔 것 먼저 — 없으면 받아서 담아 둡니다 */
function cacheFirst(req){
  return caches.match(req).then(function(hit){
    if(hit) return hit;
    return fetch(req).then(function(res){
      if(res && (res.ok || res.type==="opaque")){
        var copy=res.clone();
        caches.open(CACHE).then(function(c){ c.put(req, copy); });
      }
      return res;
    }).catch(function(){
      return new Response("", {status:504, statusText:"offline"});
    });
  });
}
