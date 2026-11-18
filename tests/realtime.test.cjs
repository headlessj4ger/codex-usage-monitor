'use strict';
const {test}=require('node:test'),assert=require('node:assert/strict');
const fs=require('node:fs'),path=require('node:path'),{DatabaseSync}=require('node:sqlite');
const {RefreshQueue,LocalChangeFeed}=require('../src/realtime.cjs');
const {Collector,CollectorService}=require('../src/collector.cjs');
const delay=ms=>new Promise(resolve=>setTimeout(resolve,ms));
async function until(check,ms=3000){const end=Date.now()+ms;while(!check()){if(Date.now()>end)throw new Error('Timed out waiting for a live change');await delay(10);}}
function fixture(){
  const root=require('./fixture-root.cjs');fs.mkdirSync(root,{recursive:true});
  const dir=fs.mkdtempSync(path.join(root,'realtime-')),home=path.join(dir,'home');fs.mkdirSync(home);
  const file=path.join(home,'sessions','2026','11','16','rollout.jsonl');fs.mkdirSync(path.dirname(file),{recursive:true});
  const c=new Collector({home,dataDir:path.join(dir,'data')});
  const write=(type,payload)=>fs.appendFileSync(file,JSON.stringify({timestamp:new Date().toISOString(),type,payload})+'\n');
  return {dir,home,file,c,write};
}
test('changes arriving during a scan are merged without loss or overlapping SQLite work',async()=>{
  let release,active=0,max=0;const batches=[];
  const q=new RefreshQueue(async b=>{active++;max=Math.max(max,active);batches.push(b);if(batches.length===1)await new Promise(r=>release=r);active--;});
  const first=q.request({full:true});
  const second=q.request({state:true,files:['a'],observed_at:20});
  const third=q.request({history:true,files:['b','a'],observed_at:30});
  release();await Promise.all([first,second,third]);
  assert.equal(max,1);assert.equal(batches.length,2);assert.deepEqual([...batches[1].files],['a','b']);
  assert.equal(batches[1].state,true);assert.equal(batches[1].history,true);assert.equal(batches[1].observed_at,20);q.stop();
});
test('a failed scan does not discard a queued follow-up change',async()=>{
  let release;const batches=[];const q=new RefreshQueue(async b=>{batches.push(b);if(batches.length===1){await new Promise(r=>release=r);throw new Error('busy');}});
  const failed=assert.rejects(q.request({state:true}),/busy/),next=q.request({history:true});release();await Promise.all([failed,next]);assert.equal(batches.length,2);q.stop();
});
test('native file events publish within the coalescing window and stop in manual mode',async t=>{
  const {home,file,c,write}=fixture(),batches=[];
  const feed=new LocalChangeFeed(home,()=>fs.existsSync(file)?[file]:[],b=>batches.push(b),{pollMs:60000});
  t.after(()=>{feed.stop();c.close();});feed.configure(true);await until(()=>batches.length>0);batches.length=0;
  const at=Date.now();write('session_meta',{id:'thread'});await until(()=>batches.some(b=>b.files.has(file)),2000);
  assert.ok(Date.now()-at<2000);feed.configure(false);batches.length=0;write('event_msg',{type:'task_started',turn_id:'turn'});await delay(250);assert.equal(batches.length,0);
});
test('signature fallback discovers new directories and SQLite WAL changes without native watchers',async t=>{
  const {home,c}=fixture(),batches=[],files=[];
  const feed=new LocalChangeFeed(home,()=>files,b=>batches.push(b),{pollMs:40,debounceMs:10,watch:()=>{throw new Error('not supported');}});
  t.after(()=>{feed.stop();c.close();});feed.configure(true);await delay(70);batches.length=0;
  const file=path.join(home,'archived_sessions','new.jsonl');fs.mkdirSync(path.dirname(file));fs.writeFileSync(file,'{}\n');files.push(file);
  fs.writeFileSync(path.join(home,'thread_history_1.sqlite-wal'),'changed');
  await until(()=>batches.some(b=>b.history&&b.files.has(file)));assert.equal(feed.watchers.size,0);
});
test('SQLite shared memory and unrelated local files never trigger a state scan',async t=>{
  const {home,c}=fixture(),batches=[];const feed=new LocalChangeFeed(home,()=>[],b=>batches.push(b),{pollMs:60000,debounceMs:10});
  t.after(()=>{feed.stop();c.close();});feed.configure(true);await delay(40);batches.length=0;
  fs.writeFileSync(path.join(home,'state_5.sqlite-shm'),'reader lock');fs.writeFileSync(path.join(home,'ignored.json'),'{}');
  await delay(100);assert.equal(batches.length,0);
  fs.writeFileSync(path.join(home,'state_5.sqlite-wal'),'state changed');await until(()=>batches.some(b=>b.state));
});
test('slow process enumeration does not delay start, waiting, interrupted or resumed activity',async t=>{
  const {c,write}=fixture(),messages=[];let finishProcesses;
  c.sampleProcesses=async()=>{c.sampling=true;await new Promise(r=>finishProcesses=r);c.processAt=Date.now();c.sampling=false;};
  const service=new CollectorService(c,m=>messages.push(m),60);t.after(()=>{service.stop();finishProcesses?.();c.close();});
  await service.start();assert.equal(messages.some(m=>m.type==='ready'),true);assert.equal(c.processAt,0);
  const current=()=>messages.filter(m=>m.speed).at(-1)?.speed.activity.find(r=>r.id==='thread');
  let at=Date.now();write('session_meta',{id:'thread'});write('event_msg',{type:'task_started',turn_id:'t1'});
  await until(()=>current()?.display_state==='starting');assert.ok(Date.now()-at<2000);assert.equal(c.processAt,0);
  write('response_item',{type:'function_call',name:'request_user_input_async',call_id:'call_q',arguments:'{"questions":[{}]}'});
  write('response_item',{type:'function_call_output',call_id:'call_q',output:'{"accepted":true}'});
  await until(()=>current()?.display_state==='waiting');
  write('event_msg',{type:'turn_aborted',turn_id:'t1'});await until(()=>current()?.display_state==='interrupted');
  write('event_msg',{type:'task_started',turn_id:'t2'});await until(()=>current()?.turn_id==='t2'&&current().is_open);
  assert.equal(messages.filter(m=>m.type==='snapshot').length,1);assert.equal(c.processAt,0);
  service.configure(0);await delay(200);const count=messages.length;write('event_msg',{type:'task_complete',turn_id:'t2'});await delay(350);assert.equal(messages.length,count);
  await service.refresh();assert.equal(current()?.display_state,'completed');
});
test('history and read receipt changes update activity before the full refresh interval',async t=>{
  const {home,c}=fixture(),messages=[],state=new DatabaseSync(path.join(home,'state_5.sqlite')),history=new DatabaseSync(path.join(home,'thread_history_1.sqlite'));
  state.exec("PRAGMA journal_mode=WAL; CREATE TABLE threads(id TEXT,title TEXT); CREATE TABLE thread_read_receipts(thread_id TEXT,first_unread_turn TEXT,revision TEXT); INSERT INTO threads VALUES('thread','fixture'); INSERT INTO thread_read_receipts VALUES('thread','turn','r1');");
  history.exec("PRAGMA journal_mode=WAL; CREATE TABLE thread_turns(thread_id TEXT,turn_id TEXT,status TEXT,started_at REAL,completed_at REAL,duration_ms REAL,rollout_ordinal INTEGER); CREATE TABLE thread_items(thread_id TEXT,turn_id TEXT,item_id TEXT,item_type TEXT,item_json TEXT,started_at_ms REAL,completed_at_ms REAL);");
  history.prepare('INSERT INTO thread_turns VALUES(?,?,?,?,?,?,?)').run('thread','turn','inProgress',Date.now()/1000,0,0,1);
  c.sampleProcesses=async()=>{c.processAt=Date.now();};
  const service=new CollectorService(c,m=>messages.push(m),60);t.after(()=>{service.stop();c.close();state.close();history.close();});await service.start();
  history.prepare("UPDATE thread_turns SET status='failed',completed_at=?").run(Date.now()/1000);
  await until(()=>messages.filter(m=>m.speed).at(-1)?.speed.activity[0]?.state==='failed');
  assert.equal(messages.filter(m=>m.type==='snapshot').length,1);
  c.activity.entries.thread.terminal_at=Date.now()-5000;
  state.exec("UPDATE thread_read_receipts SET first_unread_turn=NULL,revision='r2'");
  await until(()=>messages.filter(m=>m.speed).at(-1)?.speed.activity.length===0);
});
test('a delayed history projection cannot erase or resurrect an explicit log question',async()=>{
  const {home,c,write,file}=fixture(),history=new DatabaseSync(path.join(home,'thread_history_1.sqlite'));
  history.exec('CREATE TABLE thread_turns(thread_id TEXT,turn_id TEXT,status TEXT,started_at REAL,completed_at REAL,duration_ms REAL,rollout_ordinal INTEGER); CREATE TABLE thread_items(thread_id TEXT,turn_id TEXT,item_id TEXT,item_type TEXT,item_json TEXT,started_at_ms REAL,completed_at_ms REAL);');
  const at=Date.now();history.prepare('INSERT INTO thread_turns VALUES(?,?,?,?,?,?,?)').run('thread','turn','inProgress',at/1000,0,0,1);
  write('session_meta',{id:'thread'});write('event_msg',{type:'task_started',turn_id:'turn'});
  write('response_item',{type:'function_call',name:'request_user_input_async',call_id:'q',arguments:'{"questions":[{}]}'});write('response_item',{type:'function_call_output',call_id:'q',output:'{"accepted":true}'});
  await c.scanActivity({files:[file],history:true});assert.equal(c.sessions.get('thread').pending_questions.length,1);
  const id=JSON.stringify(['request_user_input_async','q',0]);
  write('response_item',{type:'message',role:'user',content:[{text:'<send_user_message_question_reply>'+JSON.stringify([{questionItemId:id}])+'</send_user_message_question_reply>'}]});
  history.prepare('INSERT INTO thread_items VALUES(?,?,?,?,?,?,?)').run('thread','turn','q','agentMessage','{"id":"q","questions":[{}]}',at,at);
  await c.scanActivity({files:[file],history:true});assert.equal(c.sessions.get('thread').pending_questions.length,0);history.close();c.close();
});

test('the first quota movement updates the estimate before the full refresh interval', async t => {
  const {c, write} = fixture(), messages = [];
  const resets_at = Math.floor(Date.now() / 1000) + 86400;
  const quota = used_percent => write('event_msg', { type: 'token_count',
    rate_limits: { primary: { window_minutes: 10080, used_percent, resets_at } } });
  write('session_meta', { id: 'thread', creator_account_id: 'fixture-account' });
  quota(0);
  const service = new CollectorService(c, m => messages.push(m), 60);
  t.after(() => { service.stop(); c.close(); });
  await service.start();
  await delay(20);
  write('turn_context', { turn_id: 'turn', model: 'gpt-6.2-sol', effort: 'high', service_tier: 'default' });
  write('token_usage_record', { thread_id: 'thread', turn_id: 'turn', response_id: 'first',
    usage: { input_tokens: 400000, output_tokens: 100000, total_tokens: 500000 } });
  await delay(20);
  quota(1);
  const updated = () => messages.find(m => m.type === 'snapshot' && m.quota?.used_percent === 1);
  await until(updated);
  assert.equal(updated().sessions[0].quota_estimate_status, 'provisional');
  assert.equal(updated().sessions[0].quota_estimate, 1);
  service.configure(0);
  quota(2);
  await delay(250);
  assert.ok(!messages.some(m => m.type === 'snapshot' && m.quota?.used_percent === 2));
});
