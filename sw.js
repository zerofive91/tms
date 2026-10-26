/* ═══ 네비게이토 말씀의 손 · 오프라인 지원 ═══════════════════════
   이 파일이 하는 일은 하나입니다 — 앱 파일을 폰에 담아 두어
   인터넷이 없을 때도 앱이 열리게 합니다.

     ① 앱 화면(index.html) · 전도지(bridge/index.html) : 인터넷 먼저, 느리거나 끊기면 저장본
        → 새 index.html 을 올리면 다음에 열 때 바로 반영됩니다.
        화면마다 따로 담습니다(전도지를 연 뒤에 앱이 전도지로 열리는 일이 없게).
     ② 붙박이 파일(아이콘·글꼴·supabase 스크립트) : 저장본 먼저
        성경 본문(bible/b01.json … 책마다 한 파일) · 관주 · 인물 · 지명 · 지명 설명 · 지도 · 테마 지도 · 책 소개 ·
        원어(data/orig · data/lex) · 성경 사전(data/dict) · 도량형(data/units.json) · 전도지 그림(bridge/img/…)도
        이 방식 — 한 번 받은 것은 인터넷 없이 열립니다. 이 파일들은 주소 뒤 ?v=숫자 로 판을 가르므로,
        내용을 바꿔 올릴 때는 index.html 에서 그 숫자(BIB_VER · GUIDE_VER · PLI_VER · ORIG_VER · LEX_VER · DICT_VER · UNIT_VER 등)를 올립니다.
        원어 · 사전은 크기가 커서(약 27MB) 본 책 · 본 낱말만 조금씩 담깁니다.
        → 전도지 그림을 같은 이름으로 바꿔 올릴 때는 아래 CACHE 숫자를 올려 주세요.
     ③ 기록 서버(supabase)  : 절대 저장하지 않습니다. 늘 서버로 갑니다.
        → 오프라인에서 한 채점이 서버에 올라간 것처럼 보이는 일은 없습니다.

   담는 곳은 둘로 나눕니다(v11).
     CACHE(앱 셸)  — 화면 · 아이콘 · 글꼴 · 스크립트. 붙박이 파일 목록이 바뀔 때만 숫자를 올립니다.
     DATA(자료)    — 성경 본문 · data/ · 전도지 그림. 숫자를 올려도 지우지 않으므로
                     앱 셸을 바꿔 올려도 받아 둔 성경 · 자료가 그대로 남습니다.
                     같은 파일의 새 판(?v=)을 받으면 옛 판은 그때 지웁니다.
   앱 화면은 ① 때문에 숫자를 올리지 않아도 늘 최신이 나옵니다.        */

var CACHE   = "navfest-shell-v4"; /* v4: 앱 셸과 자료를 나눔(v3까지는 한 곳에 담았음) */
var DATA    = "navfest-data-v1";  /* 자료 — 이 이름은 바꾸지 않습니다 */
var OLD     = ["navfest-v3"];     /* 한 곳에 담던 옛 캐시 — 자료만 DATA로 한 번 옮기고 지웁니다 */
var PAGE_KEY = "./index.html";       /* 앱 화면은 늘 이 이름으로 한 벌만 담습니다 */
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

/* 자료 파일인가 — 성경 본문 · data/ · 전도지 그림 */
function isData(url){
  return /\/(bible|data)\//.test(url.pathname) || /\/bridge\/img\//.test(url.pathname);
}
/* 옛 캐시에 받아 둔 자료는 새 자료 캐시로 옮깁니다(다시 받지 않도록) */
function moveOld(name){
  return caches.open(name).then(function(oc){
    return oc.keys().then(function(reqs){
      return caches.open(DATA).then(function(dc){
        return Promise.all(reqs.map(function(r){
          var u; try{ u=new URL(r.url); }catch(err){ return null; }
          if(!isData(u)) return null;
          return oc.match(r).then(function(res){ return res ? dc.put(r,res) : null; }).catch(function(){});
        }));
      });
    });
  }).catch(function(){});
}
self.addEventListener("activate", function(e){
  e.waitUntil(
    caches.keys().then(function(keys){
      var olds=keys.filter(function(k){ return OLD.indexOf(k)>=0; });
      return Promise.all(olds.map(moveOld)).then(function(){
        return Promise.all(keys.map(function(k){
          return (k===CACHE || k===DATA) ? null : caches.delete(k);
        }));
      });
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

  e.respondWith(isPage(req) ? netFirst(req) : cacheFirst(req, isData(url)));
});

/* 화면을 담는 이름 — 주소 뒤 ?… 는 떼고, 폴더 주소(…/)는 …/index.html 로 */
function pageKey(req){
  try{
    var u=new URL(req.url);
    var p=u.pathname; if(p.charAt(p.length-1)==="/") p+="index.html";
    return u.origin+p;
  }catch(e){ return PAGE_KEY; }
}

/* ① 인터넷 먼저 — 끊기거나 느리면 담아 둔 화면 */
function netFirst(req){
  var key=pageKey(req);
  return new Promise(function(resolve){
    var settled=false;
    function done(r){ if(!settled && r){ settled=true; resolve(r); } }

    var timer=setTimeout(function(){
      caches.match(key).then(done);
    }, WAIT);

    fetch(req).then(function(res){
      clearTimeout(timer);
      if(res && res.ok && res.status===200){
        var copy=res.clone();
        caches.open(CACHE).then(function(c){ c.put(key, copy); });
      }
      done(res);
    }).catch(function(){
      clearTimeout(timer);
      caches.match(key).then(function(hit){
        done(hit || new Response(
          "<!doctype html><meta charset=utf-8><body style=\"font:16px/1.7 sans-serif;padding:40px;text-align:center\">"+
          "<p>인터넷이 없어 앱을 열지 못했습니다.<br>연결한 뒤 한 번만 열어 두면 다음부터는 오프라인에서도 열립니다.</p>",
          {status:200, headers:{"Content-Type":"text/html; charset=utf-8"}}));
      });
    });
  });
}

/* ② 담아 둔 것 먼저 — 없으면 받아서 담아 둡니다 */
function cacheFirst(req, data){
  return caches.match(req).then(function(hit){
    if(hit) return hit;
    return fetch(req).then(function(res){
      if(res && (res.ok || res.type==="opaque")){
        var copy=res.clone();
        caches.open(data ? DATA : CACHE).then(function(c){
          /* 자료는 같은 파일의 옛 판(?v=)을 지우고 담습니다 */
          return (data ? c.delete(req, {ignoreSearch:true}) : Promise.resolve()).then(function(){ return c.put(req, copy); });
        });
      }
      return res;
    }).catch(function(){
      return new Response("", {status:504, statusText:"offline"});
    });
  });
}
