import fs from 'node:fs'
import path from 'node:path'
import { execFileSync } from 'node:child_process'
import { createRequire } from 'node:module'
const require=createRequire(import.meta.url)
function loadTS(){
  try{return require('typescript')}catch{}
  const env={...process.env}; delete env.npm_config_prefix; delete env.NPM_CONFIG_PREFIX
  try{const root=execFileSync('npm',['root','-g'],{encoding:'utf8',env}).trim(); return require(path.join(root,'typescript'))}catch{}
  const tsc=fs.realpathSync(execFileSync('sh',['-lc','command -v tsc'],{encoding:'utf8'}).trim()); return require(path.dirname(path.dirname(tsc)))
}
const ts=loadTS(); const out=path.resolve('.phase9-browser'); fs.rmSync(out,{recursive:true,force:true}); fs.mkdirSync(out,{recursive:true})
const source=fs.readFileSync('src/lib/syncEngine.ts','utf8')
let js=ts.transpileModule(source,{compilerOptions:{target:ts.ScriptTarget.ES2020,module:ts.ModuleKind.ESNext}}).outputText
js=js.replace('from "localforage"','from "./localforage.js"')
  .replace('from "./supabase"','from "./supabase.js"')
  .replace('from "./documents"','from "./documents.js"')
  .replace('from "./offlineStore"','from "./offlineStore.js"')
  .replace('from "./durableStorage"','from "./durableStorage.js"')
fs.writeFileSync(path.join(out,'syncEngine.js'),js)
fs.writeFileSync(path.join(out,'localforage.js'),String.raw`
const DB='FieldOneHarness', STORE='kv';
function db(){return new Promise((ok,fail)=>{const r=indexedDB.open(DB,1);r.onupgradeneeded=()=>{if(!r.result.objectStoreNames.contains(STORE))r.result.createObjectStore(STORE)};r.onsuccess=()=>ok(r.result);r.onerror=()=>fail(r.error)})}
async function tx(mode,fn){const d=await db();try{return await new Promise((ok,fail)=>{const t=d.transaction(STORE,mode),s=t.objectStore(STORE);let value;try{value=fn(s,t)}catch(e){fail(e);return}t.oncomplete=()=>ok(value);t.onerror=()=>fail(t.error);t.onabort=()=>fail(t.error)})}finally{d.close()}}
function createInstance(opts){const prefix=(opts?.storeName||'default')+':';return {async getItem(k){const d=await db();try{return await new Promise((ok,fail)=>{const t=d.transaction(STORE,'readonly'),r=t.objectStore(STORE).get(prefix+k);r.onsuccess=()=>ok(r.result??null);r.onerror=()=>fail(r.error)})}finally{d.close()}},async setItem(k,v){await tx('readwrite',s=>s.put(v,prefix+k));return v},async removeItem(k){await tx('readwrite',s=>s.delete(prefix+k))},async iterate(cb){const d=await db();try{await new Promise((ok,fail)=>{const t=d.transaction(STORE,'readonly'),r=t.objectStore(STORE).openCursor();r.onsuccess=()=>{const c=r.result;if(!c)return ok();const key=String(c.key);if(key.startsWith(prefix))cb(c.value,key.slice(prefix.length));c.continue()};r.onerror=()=>fail(r.error)})}finally{d.close()}}}}
export default {createInstance};
`)
fs.writeFileSync(path.join(out,'durableStorage.js'),`export const storageGet=(s,k)=>s.getItem(k); export const storageSet=(s,k,v)=>s.setItem(k,v); export const storageRemove=(s,k)=>s.removeItem(k); export async function storageIterate(s,cb){return s.iterate(cb)};`)
fs.writeFileSync(path.join(out,'offlineStore.js'),`export async function replaceWorkflowCommandReference(){} export async function setLastConfirmedAt(){}`)
fs.writeFileSync(path.join(out,'supabase.js'),`export const supabase={rpc:async()=>({data:null,error:null})};`)
fs.writeFileSync(path.join(out,'documents.js'),`
export async function reportUnknownInventoryScan(input){const r=await fetch('/rpc?id='+encodeURIComponent(input.clientEventId));return r.json()}
export async function getDocumentCommandResult(){return null}
export async function createSalesOrderBackorder(){return {}}
export async function decideCountVariance(){return {}}
export async function dispatchSalesOrder(){return {success:true,outcome:'accepted'}}
export async function fetchCountSessionDocument(){return null}
export async function fetchSalesOrderDocument(){return null}
export async function fetchTransferDocument(){return null}
export async function finalizeCountSession(){return {success:true,outcome:'accepted'}}
export async function receiveTransferDocument(){return {success:true,outcome:'accepted'}}
export async function recordCountObservation(){return {}}
export async function recordSalesOrderPickLine(){return {}}
export async function recordTransferReceiptLine(){return {}}
export async function resolveTransferReceiptException(){return {success:true,outcome:'accepted'}}
export async function shipTransferDocument(){return {success:true,outcome:'accepted'}}
`)
fs.writeFileSync(path.join(out,'index.html'),`<!doctype html><meta charset="utf-8"><script type="module">import * as api from './syncEngine.js'; window.api=api; window.ready=true;</script>`)
console.log(out)
