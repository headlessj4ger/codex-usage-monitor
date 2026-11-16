'use strict';
const {test}=require('node:test'),assert=require('node:assert/strict'),fs=require('node:fs'),os=require('node:os'),path=require('node:path');
const {windowMetrics,unionMilliseconds,summarizeTurn,buildSpeed}=require('../src/speed.cjs');
const {Collector}=require('../src/collector.cjs');
const {DatabaseSync}=require('node:sqlite');
const now=Date.parse('2026-11-12T02:00:00Z');
const turn={thread_id:'a',turn_id:'t',started_ms:now-120000,ended_ms:0,status:'inProgress',updated_ms:now-120000};
const session={id:'a',title:'test',thread_source:'user',log_available:true,last_event:now-1000,model:'model'};
const r=(age,values={})=>({thread_id:'a',turn_id:'t',kind:'response',at_ms:now-age,model:'model',effort:'max',tier:'default',input:900,cached:600,output:100,reasoning:60,total:1000,...values});
function fixture(values={}){return buildSpeed({now,sessions:[session],turns:[turn],usage:[r(1000)],commands:[],...values});}
test('wall-clock windows have fixed denominators and never double-count reasoning',()=>{
 const w=windowMetrics([r(60000),r(59999),r(0),r(-1)],now,60);assert.equal(w.total,2000);assert.equal(w.output_tps,200/60);assert.equal(w.total_tpm,2000);assert.equal(w.uncached_tpm,800);assert.equal(w.responses_per_minute,2);assert.equal(w.reasoning,120);assert.equal(w.cache_percent,600/900*100);
});
test('recorded throughput decays to zero during a quiet period; future records are excluded',()=>{
 const rows=[r(1000),r(-1000000)];assert.equal(windowMetrics(rows,now,60).output_tps,100/60);assert.equal(windowMetrics(rows,now+61000,60).output_tps,0);assert.equal(windowMetrics(rows,now+61000,300).output_tps,100/300);
});
test('legacy deltas cannot be mislabeled as a known number of model responses',()=>{
 const w=windowMetrics([r(1000,{kind:'cumulative_delta'})],now,60);assert.equal(w.output_tps,100/60);assert.equal(w.responses_per_minute,null);assert.equal(w.legacy_records,1);
});
test('missing logs are unknown, while a new observed turn with no completion is zero booked throughput',()=>{
 assert.equal(fixture({sessions:[{...session,log_available:false}],usage:[]}).rows[0].one.output_tps,null);
 const row=fixture({usage:[]}).rows[0];assert.equal(row.one.output_tps,0);assert.equal(row.turn.first_record_wait_ms,null);assert.equal(row.is_open,true);
});
test('overlapping command durations are merged and clipped to the turn boundary',()=>{
 assert.equal(unionMilliseconds([[0,50],[30,80],[90,120],[5,5],[100,90]],10,100),80);
 const s=summarizeTurn(turn,[r(1000)],[{turn_id:'t',start_ms:now-130000,end_ms:now-60000},{turn_id:'t',start_ms:now-90000,end_ms:now-30000},{turn_id:'other',start_ms:now-120000,end_ms:now}],now,true);
 assert.equal(s.command_ms,90000);assert.equal(s.command_percent,75);
});
test('active command timing grows until its completion and zero-duration timestamps use logged duration',()=>{
 const s=summarizeTurn(turn,[],[{turn_id:'t',start_ms:now-20000,end_ms:0,status:'inProgress'},{turn_id:'t',start_ms:now-40000,end_ms:now-40000,duration_ms:10000}],now,true);assert.equal(s.command_ms,30000);
});
test('completed turns keep fixed elapsed/average while rolling rates continue to decay',()=>{
 const ended={...turn,status:'completed',ended_ms:now-60000};const rows=[r(90000)];const a=summarizeTurn(ended,rows,[],now,true),b=summarizeTurn(ended,rows,[],now+60000,true);
 assert.equal(a.elapsed_ms,60000);assert.equal(a.average_output_tps,100/60);assert.equal(b.average_output_tps,a.average_output_tps);assert.equal(b.elapsed_ms,a.elapsed_ms);
});
test('first record wait and response gap use completed responses, not time-to-first-token',()=>{
 const s=summarizeTurn(turn,[r(90000),r(60000),r(10000)],[],now,true);assert.equal(s.first_record_wait_ms,30000);assert.equal(s.median_response_gap_ms,40000);assert.equal(s.last_record_at,now-10000);
});
test('only the latest turn determines status; an orphan old running turn cannot override a later completion',()=>{
 const row=fixture({turns:[{...turn,turn_id:'old',started_ms:now-3600000},{...turn,status:'completed',ended_ms:now-1000}]}).rows[0];assert.equal(row.state,'completed');assert.equal(row.is_open,false);
});
test('long reasoning/tool waits stay visible as quiet, not incorrectly finished after three minutes',()=>{
 const result=fixture({sessions:[{...session,last_event:now-900000}],turns:[{...turn,started_ms:now-1200000,updated_ms:now-1200000}],usage:[]});assert.equal(result.rows[0].state,'quiet');assert.equal(result.rows[0].long_stale,false);assert.equal(result.rows[0].is_open,true);
});
test('ancient unclosed records are flagged separately, and old finished turns leave the view',()=>{
 const s={...session,last_event:now-2*86400000},t={...turn,started_ms:now-2*86400000,updated_ms:now-2*86400000};assert.equal(fixture({sessions:[s],turns:[t],usage:[]}).stale,1);assert.equal(fixture({turns:[{...turn,status:'completed',ended_ms:now-16*60000}]}).rows.length,0);
});
test('parent and child throughput remain separate and hierarchy is preserved',()=>{
 const result=fixture({sessions:[session,{...session,id:'b',thread_source:'subagent'}],turns:[turn,{...turn,thread_id:'b'}],usage:[r(1000),r(1000,{thread_id:'b',output:300,total:1200})],edges:[{parent_id:'a',child_id:'b',kind:'subagent'}]});
 assert.equal(result.rows.find(s=>s.id==='a').one.output,100);assert.equal(result.rows.find(s=>s.id==='b').one.output,300);assert.equal(result.rows.find(s=>s.id==='b').parent_id,'a');
 assert.equal(result.rows[0].trend.length,10);assert.equal(result.rows[0].trend.at(-1).output_tps,100/30);
});
test('task lifecycle persists, aborts end activity, and copied parent lifecycle is rejected',()=>{
 const dir=fs.mkdtempSync(path.join(require('./fixture-root.cjs'),'codex-speed-test-'));const c=new Collector({home:dir,dataDir:path.join(dir,'data')}),cursor={};
 const ingest=(type,p,at)=>c.ingestObject({type,payload:p,timestamp:new Date(at).toISOString()},cursor,'fake.jsonl',0);
 ingest('session_meta',{id:'a'},now-60000);ingest('event_msg',{type:'task_started',turn_id:'old'},now-60001);ingest('event_msg',{type:'task_started',turn_id:'t'},now-30000);ingest('event_msg',{type:'turn_aborted',turn_id:'t',duration_ms:20000},now-10000);
 const turns=c.db.prepare('SELECT * FROM turns').all();assert.equal(turns.length,1);assert.equal(turns[0].status,'interrupted');assert.equal(turns[0].started_ms,now-30000);assert.equal(turns[0].ended_ms,now-10000);c.close();
});
test('history fallback supplies latest status without overwriting a more recent log completion',()=>{
 const dir=fs.mkdtempSync(path.join(require('./fixture-root.cjs'),'codex-speed-history-')),source=new DatabaseSync(path.join(dir,'thread_history_1.sqlite'));
 source.exec('CREATE TABLE thread_turns(thread_id TEXT,turn_id TEXT,status TEXT,started_at INTEGER,completed_at INTEGER,duration_ms REAL,rollout_ordinal INTEGER);CREATE TABLE thread_items(thread_id TEXT,turn_id TEXT,item_type TEXT,item_id TEXT,started_at_ms INTEGER,completed_at_ms INTEGER)');
 source.prepare('INSERT INTO thread_turns VALUES(?,?,?,?,?,?,?)').run('a','t','inProgress',(now-100000)/1000,null,null,1);source.close();
 const c=new Collector({home:dir,dataDir:path.join(dir,'data')});c.sessions.set('a',session);c.addTurn('a','t',now-100000,now-1000,'completed',99000,now-1000,'rollout');c.readTurnHistory();assert.equal(c.db.prepare('SELECT status FROM turns').get().status,'completed');c.close();
});
test('live command timing is closed by history and later named by the actual command record',()=>{
 const dir=fs.mkdtempSync(path.join(require('./fixture-root.cjs'),'codex-speed-command-')),source=new DatabaseSync(path.join(dir,'thread_history_1.sqlite'));
 source.exec('CREATE TABLE thread_turns(thread_id TEXT,turn_id TEXT,status TEXT,started_at INTEGER,completed_at INTEGER,duration_ms REAL,rollout_ordinal INTEGER);CREATE TABLE thread_items(thread_id TEXT,turn_id TEXT,item_type TEXT,item_id TEXT,started_at_ms INTEGER,completed_at_ms INTEGER)');
 source.prepare('INSERT INTO thread_turns VALUES(?,?,?,?,?,?,?)').run('a','t','inProgress',(now-100000)/1000,null,null,1);source.prepare('INSERT INTO thread_items VALUES(?,?,?,?,?,?)').run('a','t','commandExecution','cmd',now-1000,null);
 const c=new Collector({home:dir,dataDir:path.join(dir,'data')});c.sessions.set('a',session);c.readTurnHistory();assert.equal(c.db.prepare('SELECT status FROM commands').get().status,'inProgress');
 source.prepare('UPDATE thread_items SET completed_at_ms=?').run(now-500);c.readTurnHistory();let item=c.db.prepare('SELECT * FROM commands').get();assert.equal(item.end_ms,now-500);assert.equal(item.duration_ms,500);
 c.addCommand('a','t',{id:'cmd',command:'node example.js --secret value',status:'completed',exit_code:0,durationMs:500},now-1000,now-500);item=c.db.prepare('SELECT * FROM commands').get();assert.equal(item.executable,'node');assert.equal(item.exit_code,0);source.close();c.close();
});
