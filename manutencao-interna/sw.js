import {get,sync} from './core.js';
const BASE=new URL('./',import.meta.url), PREFIX='mi-app-'+BASE.pathname, CACHE=PREFIX+'-1.0.0';
const ASSETS=['./','index.html','style.css','app.js','core.js','config.js','excel.js','manifest.webmanifest','icon.svg','icon-192.png','icon-512.png'];
self.addEventListener('install',e=>e.waitUntil(caches.open(CACHE).then(c=>c.addAll(ASSETS.map(p=>new URL(p,BASE).href)))));
self.addEventListener('activate',e=>e.waitUntil((async()=>{for(const k of await caches.keys())if(k.startsWith(PREFIX+'-')&&k!==CACHE)await caches.delete(k);await self.clients.claim()})()));
self.addEventListener('fetch',e=>{const u=new URL(e.request.url);if(e.request.method!=='GET'||u.origin!==BASE.origin||!u.pathname.startsWith(BASE.pathname))return;const allowed=new Set(ASSETS.map(p=>new URL(p,BASE).pathname));if(!allowed.has(u.pathname)&&e.request.mode!=='navigate')return;e.respondWith((async()=>{const c=await caches.open(CACHE);const cached=await c.match(e.request,{ignoreSearch:true});if(cached)return cached;try{return await fetch(e.request)}catch(err){if(e.request.mode==='navigate')return c.match(new URL('index.html',BASE));throw err}})());});
self.addEventListener('sync',e=>{if(e.tag==='mi-send')e.waitUntil((async()=>{const owner=await get('active');if(owner)await sync(owner);for(const client of await self.clients.matchAll())client.postMessage({type:'synced'})})());});
// A fila permanece no IndexedDB se o navegador não oferecer sincronização em segundo plano.
