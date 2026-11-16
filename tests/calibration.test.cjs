'use strict';
const {test}=require('node:test'),assert=require('node:assert/strict');
const fs=require('node:fs'),os=require('node:os'),path=require('node:path');
const {DatabaseSync}=require('node:sqlite');
const {Collector}=require('../src/collector.cjs');
const {groupKey,buildObservations,calibrate,calibrationReport,estimateRows}=require('../src/calibration.cjs');
const DAY=86400000,t=Date.parse('2026-11-11T00:00:00Z');
const a=groupKey({model:'a',effort:'high',tier:'default'}),b=groupKey({model:'b',effort:'max',tier:'fast'});
const latest={at_ms:t+DAY,scope:'account',plan:'unknown',reset_at:(t+2*DAY)/1000};
function samples(n=40){return Array.from({length:n},(_,i)=>{const av=(1+(i%5))/10,bv=(1+((i*3)%7))/10;return {start:t+i*60000,end:t+(i+1)*60000,reset_at:latest.reset_at,groups:{[a]:[av*0.2,av*0.6,av*0.2],[b]:[bv*0.2,bv*0.6,bv*0.2]},total:av+bv,delta:av*2+bv*8};});}
test('learns differing combination rates and validates on later unseen blocks',()=>{
 const c=calibrate(samples(),latest);assert.equal(c.mode,'learned');assert.equal(c.channel_model,false);assert.equal(c.train,30);assert.equal(c.holdout,10);assert.ok(c.mae<c.baseline_mae);assert.ok(Math.abs(c.groups.find(g=>g.key===a).rates[0]-2)<0.01);assert.ok(Math.abs(c.groups.find(g=>g.key===b).rates[0]-8)<0.01);
 const e=estimateRows([{model:'a',effort:'high',tier:'default',scope:'account',input:800000,cached:600000,output:200000,total:1000000}],c);assert.ok(Math.abs(e.value-2)<0.01);
});
test('enough varied samples learn separate uncached, cached and output rates',()=>{
 let seed=123;const random=()=>((seed=(seed*1664525+1013904223)>>>0)/2**32);
 const rows=Array.from({length:100},(_,i)=>{const av=Array.from({length:3},()=>0.01+random()*0.2),bv=Array.from({length:3},()=>0.01+random()*0.2);return {start:t+i*60000,end:t+(i+1)*60000,reset_at:latest.reset_at,groups:{[a]:av,[b]:bv},total:[...av,...bv].reduce((s,x)=>s+x,0),delta:av[0]*2+av[1]*0.2+av[2]*10+bv[0]*8+bv[1]+bv[2]*20};});
 const c=calibrate(rows,latest);assert.equal(c.mode,'learned');assert.equal(c.channel_model,true);assert.ok(c.mae<0.01);assert.ok(Math.abs(c.groups.find(g=>g.key===b).rates[2]-20)<0.05);
});
test('small samples and permanently mixed combinations do not invent rates',()=>{
 assert.equal(calibrate(samples(8),latest).mode,'pending');
 const rows=samples().map(o=>({...o,groups:{[a]:o.groups[a],[b]:o.groups[a]},total:o.groups[a].reduce((s,v)=>s+v,0)*2}));
 const c=calibrate(rows,latest);assert.equal(c.mode,'pending');assert.match(c.reason,/无法分离/);
});
test('changed recent quota behavior fails chronological validation',()=>{
 const rows=samples();for(const r of rows.slice(30))r.delta*=3;const c=calibrate(rows,latest);assert.equal(c.mode,'pending');assert.ok(c.mae>1.25);assert.equal(c.groups.length,0);
});
test('a uniform relationship is not falsely advertised as improved calibration',()=>{
 const c=calibrate(samples().map(o=>({...o,delta:o.total*4})),latest);assert.equal(c.mode,'pending');assert.match(c.reason,/暂未证实/);
});
test('a coefficient at the nonnegative boundary is unresolved, not free quota',()=>{
 const c=calibrate(samples().map(o=>({...o,delta:o.groups[a].reduce((s,v)=>s+v,0)*2-o.groups[b].reduce((s,v)=>s+v,0)*0.1})),latest);
 assert.equal(c.mode,'learned');assert.equal(c.groups.length,1);assert.equal(c.unresolved_groups[0].key,b);
 const r={model:'b',effort:'max',tier:'fast',scope:'account',total:1000000,input:800000,cached:600000,output:200000};
 assert.equal(estimateRows([r],c).value,null);
 assert.equal(estimateRows([r],{...c,groups:[{key:b,rates:[0],channel_model:false}]}).value,null);
});
test('unknown combinations/accounts stay incomplete instead of being forced to account total',()=>{
 const c=calibrate(samples(),latest),r={model:'c',effort:'high',tier:'default',scope:'account',total:1000,input:900,cached:0,output:100};
 assert.equal(estimateRows([r],c).value,null);assert.equal(estimateRows([{...r,model:'a',scope:'other'}],c).value,null);
});
test('rare new combinations cannot contaminate or block the well-observed combinations',()=>{
 const rows=samples();rows[5].groups['["rare","low","fast"]']=[1,0,0];rows[5].delta+=90;
 rows[35].groups['["rare","low","fast"]']=[1,0,0];rows[35].delta+=90;
 const c=calibrate(rows,latest);assert.equal(c.mode,'learned');assert.equal(c.excluded_sparse,2);assert.equal(c.groups.length,2);assert.ok(c.mae<0.01);
});
function quota(at,used,extra={}){return {at_ms:at,used_percent:used,reset_at:latest.reset_at,limit_id:'codex',window_minutes:10080,scope:'account',plan:'unknown',...extra};}
function token(at,extra={}){return {at_ms:at,model:'a',effort:'high',tier:'default',scope:'account',kind:'response',input:900,cached:600,output:100,total:1000,...extra};}
test('interval progress reports partial quota movement and resets at cycle boundaries',()=>{
 const qs=[quota(t,0),quota(t+60000,2)],c=buildObservations([token(t+1)],qs,latest);
 assert.equal(c.progress.interval_accumulated_pp,2);assert.equal(c.progress.interval_required_pp,3);assert.equal(c.observations.length,0);
 const next={...latest,at_ms:t+7*DAY,reset_at:latest.reset_at+7*DAY/1000};
 const n=buildObservations([],qs.concat(quota(next.at_ms,0,{reset_at:next.reset_at})),next);
 assert.equal(n.progress.interval_accumulated_pp,0);assert.equal(n.progress.current_cycle_observations,0);
});
function historyFixture(){
 const qs=[quota(t,0)],us=[];
 for(let i=0;i<32;i++){
  const av=0.1+(i%5)*0.2,bv=(3-av*2)/8,at=t+(i+1)*60000;
  for(const [model,effort,tier,total] of [['a','high','default',av*1e6],['b','max','fast',bv*1e6]])us.push(token(at-1,{model,effort,tier,input:total*.8,cached:total*.6,output:total*.2,total}));
  qs.push(quota(at,(i+1)*3));
 }
 const next={...latest,at_ms:t+7*DAY+60000,reset_at:latest.reset_at+7*DAY/1000};
 qs.push(quota(next.at_ms-60000,0,{reset_at:next.reset_at}),quota(next.at_ms,2,{reset_at:next.reset_at}));
 return {us,qs,next};
}
test('a new cycle retains historical rates for display without applying them as current estimates',()=>{
 const {us,qs,next}=historyFixture(),report=calibrationReport(us,qs,next);
 assert.equal(report.mode,'pending');assert.equal(report.current_cycle_holdout,0);assert.equal(report.requirements.current_cycle_holdout,3);
 assert.equal(report.historical.groups.length,2);assert.ok(report.historical.mae<0.01);assert.ok(report.historical.as_of<next.at_ms);
 assert.equal(estimateRows([us[0]],report).value,null);assert.equal(report.progress.interval_accumulated_pp,2);
});
test('historical coefficients cannot cross account, plan or retention boundaries',()=>{
 const {us,qs,next}=historyFixture();
 for(const q of [{...next,scope:'another-account'},{...next,plan:'other-plan'},{...next,at_ms:next.at_ms+40*DAY,reset_at:next.reset_at+40*DAY/1000}])assert.equal(calibrationReport(us,qs,q).historical,null);
});
test('quota windows merge seconds of reset jitter; duplicate snapshots and other accounts are excluded',()=>{
 const qs=[quota(t,10),quota(t,10),quota(t+60000,11,{reset_at:latest.reset_at+5}),quota(t+120000,13),quota(t+180000,16,{scope:'other'})];
 const result=buildObservations([token(t+1),token(t+60001)],qs,latest);assert.equal(result.observations.length,1);assert.equal(result.observations[0].delta,3);assert.equal(result.observations[0].total,0.002);
});
test('unknown effort, missing records, large gaps, resets and saturation cannot become samples',()=>{
 const qs=[quota(t,10),quota(t+60000,13)];
 assert.equal(buildObservations([token(t+1,{effort:'unknown'})],qs,latest).skipped.unknown,1);
 assert.equal(buildObservations([token(t+1)],qs,latest,{missingAt:[t+1000]}).skipped.missing,1);
 assert.equal(buildObservations([token(t+1)],[quota(t,10),quota(t+3*3600000,13)],latest).observations.length,0);
 assert.equal(buildObservations([token(t+1)],[quota(t,10),quota(t+60000,13,{reset_at:latest.reset_at+7*DAY/1000})],latest).observations.length,0);
 assert.equal(buildObservations([token(t+1)],[quota(t,97),quota(t+60000,100)],latest).observations.length,0);
});
test('schema upgrade preserves pruned usage and backfills available dimensions without adding tokens',async()=>{
 const dir=fs.mkdtempSync(path.join(require('./fixture-root.cjs'),'codex-calibration-test-')),home=path.join(dir,'home'),data=path.join(dir,'data');fs.mkdirSync(path.join(home,'sessions'),{recursive:true});fs.mkdirSync(data);
 const old=new DatabaseSync(path.join(data,'usage-v2.sqlite'));old.exec("CREATE TABLE usage(event_key TEXT PRIMARY KEY,thread_id TEXT,at_ms INTEGER,model TEXT,input INTEGER,cached INTEGER,output INTEGER,reasoning INTEGER,total INTEGER,kind TEXT)");
 const add=old.prepare('INSERT INTO usage VALUES(?,?,?,?,?,?,?,?,?,?)');add.run('response:kept','session',t+1000,'a',90,30,10,5,100,'response');add.run('response:pruned','old',t,'old-model',180,60,20,10,200,'response');old.close();
 const objects=[{type:'session_meta',payload:{id:'session',creator_account_id:'private-account',timestamp:new Date(t).toISOString()}},{type:'event_msg',payload:{type:'thread_settings_applied',thread_settings:{model:'a',reasoning_effort:'high',service_tier:'fast'}}},{type:'turn_context',payload:{turn_id:'turn1',model:'a',effort:'max'}},{type:'token_usage_record',timestamp:new Date(t+1000).toISOString(),payload:{thread_id:'session',turn_id:'turn1',response_id:'kept',usage:{input_tokens:90,cached_input_tokens:30,output_tokens:10,reasoning_output_tokens:5,total_tokens:100}}}];
 fs.writeFileSync(path.join(home,'sessions','s.jsonl'),objects.map(JSON.stringify).join('\n')+'\n');const c=new Collector({home,dataDir:data});await c.scan();let rows=c.db.prepare('SELECT * FROM usage ORDER BY total').all();assert.equal(rows.length,2);assert.equal(rows[0].effort,'max');assert.equal(rows[0].tier,'fast');assert.notEqual(rows[0].scope,'private-account');assert.equal(rows[0].scope.length,64);assert.equal(rows[1].effort,'unknown');assert.equal(rows.reduce((s,r)=>s+r.total,0),300);await c.scan();assert.equal(c.db.prepare('SELECT SUM(total) n FROM usage').get().n,300);c.close();
});
test('mid-turn changes and delayed responses retain their own model and effort',()=>{
 const dir=fs.mkdtempSync(path.join(require('./fixture-root.cjs'),'codex-context-test-')),c=new Collector({home:dir,dataDir:path.join(dir,'data')}),cursor={};
 const ingest=(type,p,offset=0)=>c.ingestObject({type,payload:p,timestamp:new Date(t+offset).toISOString()},cursor,'test.jsonl',offset);
 ingest('session_meta',{id:'session',creator_account_id:'acct'});ingest('turn_context',{turn_id:'one',model:'a',effort:'high'});ingest('response_item',{type:'configuration_update',reasoning:{effort:'max'}});ingest('turn_context',{turn_id:'two',model:'b',effort:'low'});
 ingest('token_usage_record',{thread_id:'session',turn_id:'one',response_id:'one',usage:{input_tokens:10,output_tokens:2}},1);
 ingest('token_usage_record',{thread_id:'session',turn_id:'two',response_id:'two',usage:{input_tokens:20,output_tokens:2}},2);
 ingest('token_usage_record',{thread_id:'session',turn_id:'missing',response_id:'missing',usage:{input_tokens:20,output_tokens:2}},3);
 const get=c.db.prepare('SELECT model,effort FROM usage WHERE event_key=?');assert.deepEqual({...get.get('response:one')},{model:'a',effort:'max'});assert.deepEqual({...get.get('response:two')},{model:'b',effort:'low'});assert.deepEqual({...get.get('response:missing')},{model:'unknown',effort:'unknown'});c.close();
});
test('settings after context fill the active tier; future settings cannot rewrite an older turn',()=>{
 const dir=fs.mkdtempSync(path.join(require('./fixture-root.cjs'),'codex-settings-test-')),c=new Collector({home:dir,dataDir:path.join(dir,'data')}),cursor={};
 const ingest=(type,p,offset=0)=>c.ingestObject({type,payload:p,timestamp:new Date(t+offset).toISOString()},cursor,'test.jsonl',offset);
 ingest('session_meta',{id:'session'});ingest('turn_context',{turn_id:'one',model:'a',effort:'max'},1);
 ingest('event_msg',{type:'thread_settings_applied',thread_settings:{model:'a',reasoning_effort:'max',service_tier:'priority'}},2);
 ingest('event_msg',{type:'thread_settings_applied',thread_settings:{model:'b',reasoning_effort:'low',service_tier:'default'}},5000);
 ingest('turn_context',{turn_id:'two',model:'b',effort:'low'},5010);
 for(const turn of ['one','two'])ingest('token_usage_record',{thread_id:'session',turn_id:turn,response_id:turn,usage:{input_tokens:10,output_tokens:2}},6000);
 const get=c.db.prepare('SELECT model,effort,tier FROM usage WHERE event_key=?');assert.deepEqual({...get.get('response:one')},{model:'a',effort:'max',tier:'priority'});assert.deepEqual({...get.get('response:two')},{model:'b',effort:'low',tier:'default'});c.close();
});
