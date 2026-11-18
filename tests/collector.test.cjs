'use strict';
const {test}=require('node:test');const assert=require('node:assert/strict');const fs=require('node:fs');const path=require('node:path');
const {Collector,usage,periodFromQuota,flattenProcesses,normalizedWindows,summarizeCommand,weekdayStart}=require('../src/collector.cjs');
const root=require('./fixture-root.cjs');fs.mkdirSync(root,{recursive:true});
function fixture(){const dir=fs.mkdtempSync(path.join(root,'case-'));const home=path.join(dir,'source');fs.mkdirSync(path.join(home,'sessions'),{recursive:true});return {dir,home,c:new Collector({home,dataDir:path.join(dir,'cache')})};}
const t=Date.parse('2026-11-11T08:00:00Z');
function meta(id,extra={}){return {timestamp:new Date(t).toISOString(),type:'session_meta',payload:{id,timestamp:new Date(t).toISOString(),...extra}};}
function record(id,response,total,offset=1000){return {timestamp:new Date(t+offset).toISOString(),type:'token_usage_record',payload:{thread_id:id,response_id:response,usage:{input_tokens:total-10,output_tokens:10,total_tokens:total}}};}
function count(total,offset=2000,last=total){return {timestamp:new Date(t+offset).toISOString(),type:'event_msg',payload:{type:'token_count',info:{total_token_usage:{input_tokens:total-10,output_tokens:10,total_tokens:total},last_token_usage:{input_tokens:last-10,output_tokens:10,total_tokens:last}}}};}
test('cached and reasoning are subsets, not extra tokens',()=>assert.deepEqual(usage({input_tokens:100,cached_input_tokens:80,output_tokens:30,reasoning_output_tokens:20,total_tokens:130}),{input:100,cached:80,output:30,reasoning:20,total:130}));
test('response records and cumulative notifications are not counted twice',async()=>{const {home,c}=fixture();const f=path.join(home,'sessions','a.jsonl');fs.writeFileSync(f,[meta('a'),record('a','r1',110),count(110),count(110,3000),record('a','r2',210,4000),count(320,5000)].map(JSON.stringify).join('\n')+'\n');await c.scan();assert.equal(c.snapshot(t+7000).sessions[0].recorded,320);await c.scan();assert.equal(c.snapshot(t+7000).sessions[0].recorded,320);c.close();});
test('legacy counters use deltas; reset uses the last request only',async()=>{const {home,c}=fixture();const f=path.join(home,'sessions','a.jsonl');fs.writeFileSync(f,[meta('a'),count(100,1000),count(150,2000),count(150,3000),count(40,4000,20)].map(JSON.stringify).join('\n')+'\n');await c.scan();assert.equal(c.snapshot(t+5000).sessions[0].recorded,170);c.close();});
test('fork inheritance is excluded and parent relation preserved',async()=>{const {home,c}=fixture();const f=path.join(home,'sessions','b.jsonl');fs.writeFileSync(f,[meta('b',{forked_from_id:'a'}),record('a','r1',100),record('b','r2',120)].map(JSON.stringify).join('\n')+'\n');await c.scan();assert.equal(c.snapshot(t+5000).sessions[0].recorded,120);assert.equal(c.snapshot().edges[0].kind,'fork');c.close();});
test('UTF-8 partial last line waits for newline, survives restart',async()=>{const {home,dir,c}=fixture();const f=path.join(home,'sessions','a.jsonl');const line=JSON.stringify(record('a','r1',100));fs.writeFileSync(f,JSON.stringify(meta('a',{cwd:'中文目录'}))+'\n'+line.slice(0,50));await c.scan();assert.equal(c.snapshot().sessions[0].recorded,0);c.close();fs.appendFileSync(f,line.slice(50)+'\n');const next=new Collector({home,dataDir:path.join(dir,'cache')});await next.scan();assert.equal(next.snapshot().sessions[0].recorded,100);assert.equal(next.snapshot().sessions[0].cwd,'中文目录');next.close();});
test('replaced file can be replayed without duplicating response IDs',async()=>{const {home,c}=fixture();const f=path.join(home,'sessions','a.jsonl');const text=[meta('a'),record('a','r1',100)].map(JSON.stringify).join('\n')+'\n';fs.writeFileSync(f,text);await c.scan();fs.writeFileSync(f,text+JSON.stringify(record('a','r1',100))+'\n');await c.scan();assert.equal(c.snapshot().sessions[0].recorded,100);c.close();});
test('weekly primary/secondary windows use duration, not slot name',()=>{const windows=normalizedWindows({limit_id:'codex',primary:{used_percent:23,window_minutes:300,resets_at:12},secondary:{used_percent:60,window_minutes:10080,resets_at:42}});assert.equal(windows.find(w=>w.window_minutes===10080).used_percent,60);});
test('expired quotas disable allocation and switch to Shanghai calendar week',()=>{const q={reset_at:(t-1000)/1000};assert.equal(periodFromQuota(q,t).kind,'calendar');assert.equal(new Date(weekdayStart(t)).toISOString(),'2026-11-08T16:00:00.000Z');});
test('one quota snapshot gives weighted cycle shares while calibration waits for measured changes', async () => {
  const {home, c}=fixture();
  const quota={timestamp:new Date(t+3000).toISOString(),type:'event_msg',payload:{type:'token_count',
    rate_limits:{limit_id:'codex',primary:{window_minutes:10080,used_percent:60,resets_at:(t+86400000)/1000}}}};
  try {
    for (const [id, model] of [['a','gpt-6.2-sol'],['b','gpt-6.2-astra']]) {
      const reply = record(id,id,1000000,2000);
      reply.payload.usage = { input_tokens: 800000, cached_input_tokens: 600000, output_tokens: 200000, total_tokens: 1000000 };
      reply.payload.turn_id = 'turn';
      rollout(home,id,[meta(id, { creator_account_id:'one' }), modelContext(model, 'turn', 1000), reply, quota]);
    }
    await c.scan();
    const s=c.snapshot(t+10000);
    assert.equal(s.week_total,2000000);
    assert.equal(s.sessions.find(r=>r.id==='a').local_weighted_share,20);
    assert.equal(s.sessions.find(r=>r.id==='b').local_weighted_share,80);
    const sol = s.combinations.find(g=>g.model==='gpt-6.2-sol');
    const astra = s.combinations.find(g=>g.model==='gpt-6.2-astra');
    assert.deepEqual([sol.local_weighted_share, astra.local_weighted_share], [20, 80]);
    assert.deepEqual(sol.cycle_share, { used: 20, total: 12, basis: 'weighted' });
    assert.deepEqual(astra.cycle_share, { used: 80, total: 48, basis: 'weighted' });
    assert.ok(s.combinations.every(g=>g.quota_estimate===null));
    assert.deepEqual([sol.credit_reference_rate, astra.credit_reference_rate], [61.5, 246]);
    assert.ok(s.sessions.every(r=>r.quota_estimate===null));
    const beforeQuota = c.snapshot(t + 2500).combinations.find(g=>g.model==='gpt-6.2-sol');
    assert.deepEqual(beforeQuota.cycle_share, { used: 20, total: null, basis: 'weighted' });
  } finally { c.close(); }
});
test('process attribution requires explicit thread flags, never internal execution IDs',()=>{const id='01a1c9e7-ba41-7f52-943a-176e6128b544';const rows=[{pid:1,ppid:0,name:'codex.exe',created:'2026-11-11T00:00:00Z',command:''},{pid:2,ppid:1,name:'node.exe',created:'2026-11-11T00:01:00Z',command:'node --thread-id '+id},{pid:3,ppid:2,name:'tool.exe',created:'2026-11-11T00:02:00Z',command:''},{pid:4,ppid:1,name:'other.exe',command:'echo '+id}];const out=flattenProcesses(rows,new Set([id]),99);assert.equal(out.find(p=>p.pid===3).association,'ancestor');assert.equal(out.find(p=>p.pid===4).thread_id,null);assert.ok(out.every(p=>!('command'in p)));});
test('command summaries discard arguments and secrets',()=>{assert.equal(summarizeCommand('node app.js --token sk-example'),'node');assert.equal(summarizeCommand('"C:\\Tools\\node.exe" secret'),'node.exe');});
test('a copied parent session_meta cannot steal child response ownership',async()=>{const {home,c}=fixture();const child='01a1c9e7-ba41-7f52-943a-176e6128b544';const f=path.join(home,'sessions','rollout-'+child+'.jsonl');c.sessions.set(child,{id:child,title:'child',created:t+3000,rollout_path:f,thread_source:'subagent'});fs.writeFileSync(f,[meta('parent'),record('parent','old',100,1000),count(100,2000),record(child,'new',200,4000),count(200,5000)].map(JSON.stringify).join('\n')+'\n');await c.scan();const s=c.snapshot(t+6000);assert.equal(s.sessions.find(r=>r.id===child).recorded,200);assert.ok(s.edges.some(e=>e.child_id===child&&e.parent_id==='parent'));assert.equal(s.sessions.length,1);c.close();});

function rollout(home, name, events) {
  fs.writeFileSync(path.join(home, 'sessions', name + '.jsonl'), events.map(JSON.stringify).join('\n') + '\n');
}
function modelContext(model, turn_id, offset) {
  return { timestamp: new Date(t + offset).toISOString(), type: 'turn_context',
    payload: { turn_id, model, effort: 'max', service_tier: 'default' } };
}

test('a guardian starting counter copied from history contributes no own tokens or second charge', async () => {
  const {home, c}=fixture();
  try {
    const reply = record('guardian', 'new-response', 110, 3000);
    reply.payload.thread_token_usage = { input_tokens: 1090, output_tokens: 20, total_tokens: 1110 };
    c.sessions.set('guardian', { id: 'guardian', metadata_tokens: 1110 });
    rollout(home, 'parent', [meta('parent'), record('parent', 'parent-response', 1000, 1000)]);
    rollout(home, 'guardian', [
      meta('guardian', { thread_source: 'guardian_review', parent_thread_id: 'parent' }),
      count(1000, 2000), reply
    ]);
    await c.scan();
    const s = c.snapshot(t + 6000);
    assert.equal(s.sessions.find(row => row.id === 'guardian').recorded, 110);
    assert.equal(s.sessions.find(row => row.id === 'guardian').total, 110);
    assert.equal(s.lifetime_total, 1110);
    assert.ok(s.edges.some(edge => edge.kind === 'guardian' && edge.parent_id === 'parent' && edge.child_id === 'guardian'));
  } finally { c.close(); }
});

test('notification before a matching response and stale notifications after it are counted once across restart', async () => {
  const {home, dir, c}=fixture();
  const f = path.join(home, 'sessions', 'mixed.jsonl');
  rollout(home, 'mixed', [meta('mixed'), count(100, 1000)]);
  try {
    await c.scan();
    assert.equal(c.snapshot().lifetime_total, 100);
  } finally { c.close(); }
  const first = record('mixed', 'modern-one', 100, 2000);
  const second = record('mixed', 'modern-two', 100, 3000);
  first.payload.thread_token_usage = first.payload.usage;
  second.payload.thread_token_usage = { input_tokens: 180, output_tokens: 20, total_tokens: 200 };
  const last = count(200, 5000);
  last.payload.info.total_token_usage = second.payload.thread_token_usage;
  fs.appendFileSync(f, [first, second, count(100, 4000), last].map(JSON.stringify).join('\n') + '\n');
  const next = new Collector({home, dataDir: path.join(dir,'cache')});
  try {
    await next.scan();
    const rows = next.db.prepare('SELECT kind,total FROM usage ORDER BY at_ms').all();
    assert.deepEqual(rows.map(r => [r.kind, r.total]), [['response', 100], ['response', 100]]);
    assert.equal(next.snapshot().lifetime_total, 200);
  } finally { next.close(); }
});

test('new quota movement propagates a provisional estimate through session and model snapshots', async () => {
  const {home, c}=fixture();
  const reset = (t + 86400000) / 1000;
  const q = (used_percent, ms) => ({
    timestamp: new Date(t + ms).toISOString(),
    type: 'event_msg',
    payload: { type: 'token_count', rate_limits: { primary: { window_minutes: 10080, used_percent, resets_at: reset } } }
  });
  const reply = record('a', 'first', 500000, 2000);
  reply.payload.turn_id = 'one';
  const earlier = record('b', 'earlier', 300000, 800);
  earlier.payload.turn_id = 'two';
  const later = record('b', 'later', 500000, 4000);
  later.payload.turn_id = 'three';
  rollout(home, 'a', [
    meta('a', { creator_account_id: 'local-account' }), q(49, 1000),
    modelContext('gpt-6.2-sol', 'one', 1500),
    reply, q(50, 3000), record('a', 'after-last-quota', 10000, 4000)
  ]);
  rollout(home, 'b', [meta('b', { creator_account_id: 'local-account' }),
    modelContext('gpt-6.2-astra', 'two', 700), earlier,
    modelContext('gpt-6.1-sol', 'three', 3500), later]);
  try {
    await c.scan();
    const s = c.snapshot(t + 5000);
    assert.equal(s.calibration.mode, 'pending');
    const combo = s.combinations.find(g => g.model === 'gpt-6.2-sol');
    const session = s.sessions.find(row => row.id === 'a');
    assert.equal(combo.provisional_rate, 2);
    assert.equal(session.week_total, 510000);
    assert.equal(session.quota_eligible_tokens, 500000);
    assert.equal(session.quota_estimate, 1);
    assert.equal(session.quota_estimate_status, 'provisional');
    assert.equal(combo.quota_estimate_status, 'provisional');
    assert.equal(combo.quota_estimate, 1);
    assert.deepEqual(combo.cycle_share, { used: 2, total: 1, basis: 'provisional' });
    const uncalibrated = s.combinations.find(g => g.model === 'gpt-6.2-astra');
    assert.deepEqual(uncalibrated.cycle_share, { used: 98, total: 49, basis: 'weighted' });
    assert.equal(s.combinations.find(g => g.model === 'gpt-6.1-sol').cycle_share, undefined);
  } finally { c.close(); }
});

test('same-time quota rows from two known accounts remain separate and suspend account attribution', async () => {
  const {home, c}=fixture();
  const quota = {
    timestamp: new Date(t + 1000).toISOString(), type: 'event_msg',
    payload: { type: 'token_count', rate_limits: { primary: { window_minutes: 10080, used_percent: 10, resets_at: (t + 86400000) / 1000 } } }
  };
  rollout(home, 'a', [meta('a', { creator_account_id: 'one' }), quota]);
  rollout(home, 'b', [meta('b', { creator_account_id: 'two' }), quota]);
  try {
    await c.scan();
    assert.equal(c.db.prepare('SELECT COUNT(DISTINCT scope) n FROM quotas').get().n, 2);
    const s = c.snapshot(t + 3000);
    assert.equal(s.quota.conflict, true);
    assert.equal(s.calibration.provisional, null);
    assert.ok(s.sessions.every(item => item.quota_estimate === null));
  } finally { c.close(); }
});

test('only listed models are estimated, and changes to the Codex catalog apply without rewriting usage', async () => {
  const {home,c}=fixture();
  const catalogPath=path.join(home,'models_cache.json');
  const quota = (ms, used_percent) => ({
    timestamp:new Date(t+ms).toISOString(),type:'event_msg',payload:{type:'token_count',
      rate_limits:{primary:{window_minutes:10080,used_percent,resets_at:(t+86400000)/1000}}}
  });
  const records = [meta('a',{creator_account_id:'one'}), quota(1000,0)];
  for (const [i, model] of ['gpt-6.2-sol','codex-auto-review','unknown','next-codex-model'].entries()) {
    const response = record('a','response-'+i,250000,2500+i*500);
    response.payload.turn_id='turn-'+i;
    records.push(modelContext(model,'turn-'+i,2400+i*500),response);
  }
  rollout(home,'a',records.concat(quota(5000,12)));
  try {
    await c.scan();
    const startup = c.snapshot(t+7000);
    assert.equal(startup.calibration.model_catalog,'bundled');
    assert.equal(startup.week_total,1000000);
    assert.deepEqual(startup.combinations.map(g=>g.model),['gpt-6.2-sol']);
    assert.equal(startup.calibration.skipped.unlisted_model,1);
    assert.equal(startup.calibration.provisional,null);
    assert.equal(startup.calibration.eligible_tokens,250000);
    assert.equal(startup.calibration.unlisted_model_tokens,750000);
    assert.equal(startup.sessions[0].quota_estimate,null);
    assert.equal(startup.calibration.credit_reference.tokens,250000);
    fs.writeFileSync(catalogPath,JSON.stringify({fetched_at:new Date(t).toISOString(),models:[
      {slug:'gpt-6.2-sol',visibility:'list'},{slug:'codex-auto-review',visibility:'hide'},
      {slug:'next-codex-model',visibility:'list'},{slug:'unknown',visibility:'list'}
    ]}));
    const refreshed = c.snapshot(t+7000);
    assert.equal(refreshed.calibration.model_catalog,'codex');
    assert.deepEqual(refreshed.combinations.map(g=>g.model).sort(),['gpt-6.2-sol','next-codex-model']);
    assert.equal(refreshed.sessions[0].quota_unlisted_model_tokens,500000);
    assert.equal(refreshed.sessions[0].quota_estimate,null);
    const newModel = refreshed.combinations.find(g=>g.model==='next-codex-model');
    assert.equal(newModel.credit_reference_rate,null);
    assert.equal(newModel.local_weighted_share,null);
    assert.equal(refreshed.calibration.credit_reference.tokens,250000);
    assert.deepEqual(c.detail('a').models.map(g=>g.model).sort(),['gpt-6.2-sol','next-codex-model']);
    assert.equal(c.db.prepare('SELECT COUNT(*) n FROM usage').get().n,4);
  } finally { c.close(); }
});
