import {CONFIG} from './config.js';
export const EMPTY={orders:[],equipment:[],plans:[],costs:[],events:[],erp:[],notifications:[]};
const DBNAME='mi-offline-'+new URL('.',import.meta.url).pathname+'-'+new URL(CONFIG.url).hostname;
let opening;
export function database(){return opening ||= new Promise((resolve,reject)=>{const q=indexedDB.open(DBNAME,1);q.onupgradeneeded=()=>{q.result.createObjectStore('kv');q.result.createObjectStore('queue',{keyPath:'id'});};q.onsuccess=()=>resolve(q.result);q.onerror=()=>reject(q.error);});}
export async function tx(stores,mode,fn){const db=await database();return new Promise((resolve,reject)=>{const t=db.transaction(stores,mode);let result;try{result=fn(t)}catch(e){t.abort();reject(e);return;}t.oncomplete=()=>resolve(typeof result==='function'?result():result);t.onerror=()=>reject(t.error);t.onabort=()=>reject(t.error||Error('Gravação local interrompida'));});}
export async function get(key){let result;await tx(['kv'],'readonly',t=>{const r=t.objectStore('kv').get(key);r.onsuccess=()=>result=r.result;});return result;}
export const put=(key,value)=>tx(['kv'],'readwrite',t=>{t.objectStore('kv').put(value,key)});
export async function queueFor(owner){let result=[];await tx(['queue'],'readonly',t=>{const r=t.objectStore('queue').getAll();r.onsuccess=()=>result=r.result.filter(x=>x.owner===owner).sort((a,b)=>a.seq-b.seq)});return result;}
export async function enqueue(owner,kind,data){const id=crypto.randomUUID();await tx(['kv','queue'],'readwrite',t=>{const kv=t.objectStore('kv'),q=t.objectStore('queue'),r=kv.get('sequence');r.onsuccess=()=>{const seq=(r.result||0)+1;kv.put(seq,'sequence');q.add({id,owner,seq,kind,data,created:new Date().toISOString(),status:'pending',error:''});};});return id;}
export async function reviseOperation(id,data){await tx(['queue'],'readwrite',t=>{const s=t.objectStore('queue'),q=s.get(id);q.onsuccess=()=>{if(!q.result){t.abort();return;}s.put({...q.result,data,status:'pending',error:''})}});}
export async function discard(id){await tx(['queue'],'readwrite',t=>{t.objectStore('queue').delete(id)});}
export async function saveSnapshot(owner,snapshot,receipt){await tx(['kv','queue'],'readwrite',t=>{const kv=t.objectStore('kv'),q=kv.get('snapshot:'+owner);q.onsuccess=()=>{if(!q.result||Number(snapshot.revision)>=Number(q.result.revision))kv.put({...snapshot,last_sync:new Date().toISOString()},'snapshot:'+owner);};if(receipt)t.objectStore('queue').delete(receipt);});}
class RemoteError extends Error{constructor(message,status){super(message);this.status=status}}
async function http(path,body,token){const r=await fetch(CONFIG.url+path,{method:'POST',headers:{'Content-Type':'application/json',apikey:CONFIG.key,...(token?{Authorization:'Bearer '+token}:{})},body:JSON.stringify(body),signal:AbortSignal.timeout(18000)});let j;try{j=await r.json()}catch{throw new RemoteError('Resposta inválida do servidor',r.status)}if(!r.ok)throw new RemoteError(j.message||j.msg||j.error_description||j.error||'Falha de acesso',r.status);return j;}
export async function login(email,password){const session=await http('/auth/v1/token?grant_type=password',{email,password});session.expires_at=Date.now()+session.expires_in*1000;const snapshot=await http('/rest/v1/rpc/mi_snapshot',{},session.access_token);await saveSnapshot(session.user.id,snapshot);await put('session:'+session.user.id,session);await put('active',session.user.id);return session.user.id;}
export async function logout(){const owner=await get('active');if(owner)await put('session:'+owner,null);await put('active',null);}
async function sessionFor(owner){let s=await get('session:'+owner);if(!s)throw new RemoteError('Entre novamente para enviar seus registros pendentes.',401);if(Date.now()>=s.expires_at-60000){const next=await http('/auth/v1/token?grant_type=refresh_token',{refresh_token:s.refresh_token});s={...next,expires_at:Date.now()+next.expires_in*1000};await put('session:'+owner,s);}return s;}
async function markError(op,error){await tx(['queue'],'readwrite',t=>{const store=t.objectStore('queue'),q=store.get(op.id);q.onsuccess=()=>{if(q.result)store.put({...q.result,status:'blocked',error})}});}
async function synchronize(owner){if(!owner)return {ok:false};let s=await sessionFor(owner);const queue=await queueFor(owner);
 for(const op of queue){if(op.status==='blocked')break;
  try{const snap=await http('/rest/v1/rpc/mi_apply',{operation_id:op.id,payload:{kind:op.kind,data:op.data}},s.access_token);await saveSnapshot(owner,snap,op.id)}
  catch(e){if(e.status===401||e.status===403)throw e;if(e.status>=400&&e.status<500){await markError(op,e.message);break;}throw e;}
 }
 const snap=await http('/rest/v1/rpc/mi_snapshot',{},s.access_token);await saveSnapshot(owner,snap);return {ok:true,pending:(await queueFor(owner)).length};
}
let running;
export function sync(owner){if(running)return running;running=(async()=>{if(globalThis.navigator?.locks)return navigator.locks.request(DBNAME+'-sync',()=>synchronize(owner));return synchronize(owner)})().finally(()=>running=null);return running;}
export const localDate=()=>new Intl.DateTimeFormat('en-CA',{timeZone:'America/Sao_Paulo',year:'numeric',month:'2-digit',day:'2-digit'}).format(new Date());
export function project(snapshot,operations){const data=structuredClone(snapshot?.data||EMPTY),members=snapshot?.members||[];const name=members.find(x=>x.id===snapshot?.me?.user_id)?.name||'Solicitante';
 for(const op of operations){if(op.status==='blocked')continue;const p=op.data;
  if(op.kind==='open'&&!data.orders.some(x=>x.id===p.id)){data.orders.push({id:p.id,code:'PENDENTE · '+p.id.slice(0,8),created:p.recorded_at,recorded_at:p.recorded_at,creator:op.owner,original:{...p,requester:name},responsible:p.responsible,status:'Aberta',actual_type:'',actual_service:'',due:p.due,conclusion:'',revision:1,plan_id:p.plan_id||'',pending:true});}
  if(op.kind==='update'){const o=data.orders.find(x=>x.id===p.id);if(o)Object.assign(o,{...p,revision:o.revision+1,pending:true});}
  if(op.kind==='cost'&&!data.costs.some(x=>x.id===p.id))data.costs.push({...p,cents:Math.round(Number(p.price)*100),total_cents:Math.round(Number(p.quantity)*Math.round(Number(p.price)*100)),created:op.created,month:localDate().slice(0,7),actor:name,pending:true});
  if(op.kind==='equipment'&&!data.equipment.some(x=>x.id===p.id))data.equipment.push({...p,pending:true});
  if(op.kind==='plan'&&!data.plans.some(x=>x.id===p.id))data.plans.push({...p,active:true,pending:true});
  if(op.kind==='plan_active'){const x=data.plans.find(x=>x.id===p.id);if(x)x.active=p.active;}
  if(op.kind==='ack'){const x=data.notifications.find(x=>x.id===p.id);if(x)x.seen=true;}
 }
 return data;
}
export async function backup(owner){return {format:'MI-PWA-1',exported:new Date().toISOString(),owner,snapshot:await get('snapshot:'+owner),pending:await queueFor(owner)};}
export async function restorePending(owner,pack){if(pack.format!=='MI-PWA-1'||pack.owner!==owner||!Array.isArray(pack.pending))throw Error('Este backup pertence a outra conta ou tem formato inválido.');const allowed=['open','update','cost','equipment','plan','plan_active','ack','erp','erp_reopen','member'];for(const op of pack.pending){if(op.owner!==owner||!allowed.includes(op.kind)||!op.data||!/^[0-9a-f-]{36}$/i.test(op.id))throw Error('Operação inválida no backup.');}
 await tx(['kv','queue'],'readwrite',t=>{const kv=t.objectStore('kv'),q=t.objectStore('queue'),r=kv.get('sequence');r.onsuccess=()=>{let seq=r.result||0;for(const op of pack.pending){const found=q.get(op.id);found.onsuccess=()=>{if(!found.result){q.put({...op,seq:++seq});kv.put(seq,'sequence')}}}}});return pack.pending.length;}
