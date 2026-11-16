const {test}=require('node:test'),assert=require('node:assert/strict');
const {ActivityTracker}=require('../src/activity.cjs');const {pendingFromItems,answerIds}=require('../src/questions.cjs');
const {buildSpeed}=require('../src/speed.cjs');
const row=(extra={})=>({id:'thread',turn_id:'turn1',state:'running',source:'user',is_open:true,started_ms:1,turn:{responses:1},...extra});
test('new, running, complete and acknowledged lifecycle; next turn reappears',()=>{
 const a=new ActivityTracker();assert.equal(a.update([row({turn:{responses:0}})],{},100)[0].display_state,'starting');
 assert.equal(a.update([row()],{},1000)[0].display_state,'running');
 const done=row({state:'completed',is_open:false});assert.equal(a.update([done],{},2000)[0].display_state,'completed');
 assert.equal(a.update([done],{},900000).length,1);assert.equal(a.acknowledge('thread','old'),false);
 assert.equal(a.acknowledge('thread','turn1'),true);assert.equal(a.update([done],{},901000).length,0);
 assert.equal(a.update([row({turn_id:'turn2'})],{},902000).length,1);
});
test('unread terminal survives restart; known read retires after checkmark grace',()=>{
 const done=row({state:'completed',is_open:false,ended_ms:900}),unread={thread:{first_unread_turn:'turn1'}};
 const a=new ActivityTracker();assert.equal(a.update([done],unread,1000).length,1);
 const b=new ActivityTracker(JSON.parse(JSON.stringify(a.entries)));
 assert.equal(b.update([done],unread,1000000).length,1);
 assert.equal(b.update([done],{thread:{first_unread_turn:null}},1001000).length,0);
});
test('already-read historical completions never flood a first startup',()=>{
 assert.equal(new ActivityTracker().update([row({state:'completed',is_open:false})],{thread:{first_unread_turn:null}},10).length,0);
 assert.equal(new ActivityTracker().update([row({state:'completed',is_open:false})],{},10).length,0);
});
test('running rows ignore an old receipt and waiting requires an explicit signal',()=>{
 const a=new ActivityTracker();const read={thread:{first_unread_turn:null}};
 assert.equal(a.update([row({state:'quiet'})],read,1000000).length,0);
 assert.equal(a.update([row({requires_input:true})],read,1000001)[0].display_state,'waiting');
 assert.equal(a.update([row({requires_input:false})],read,1000002)[0].display_state,'running');
});
test('failed and interrupted stay distinct; guardian and stale rows are excluded',()=>{
 const a=new ActivityTracker();a.update([row()],{},100);
 assert.equal(a.update([row({is_open:false,state:'failed'})],{},200)[0].display_state,'failed');
 assert.equal(a.update([row({is_open:false,state:'interrupted'})],{},300)[0].display_state,'interrupted');
 assert.equal(a.update([row({long_stale:true})],{},400).length,0);
 assert.equal(a.update([row({source:'guardian_review'})],{},400).length,0);
});
test('question identifiers are matched without storing question or answer text',()=>{
 const id=JSON.stringify(['request_user_input_async','call_a',0]);
 const question={item_id:'call_a',item_type:'agentMessage',item_json:JSON.stringify({id:'call_a',questions:[{question:'private text'},{}]})};
 const response={item_type:'userMessage',item_json:JSON.stringify({content:[{type:'text',text:'<send_user_message_question_reply>'+JSON.stringify([{questionItemId:id,answer:'private answer'}])+'</send_user_message_question_reply>'}]})};
 assert.deepEqual(pendingFromItems([question]),[id,JSON.stringify(['request_user_input_async','call_a',1])]);
 assert.deepEqual(pendingFromItems([question,response]),[JSON.stringify(['request_user_input_async','call_a',1])]);
 assert.equal(JSON.stringify(pendingFromItems([question,response])).includes('private'),false);
 assert.equal(answerIds([{text:'<send_user_message_question_reply>invalid</send_user_message_question_reply>'}]).size,0);
});
test('old unread or locally retained completion remains available beyond fifteen minutes',()=>{
 const options={sessions:[{id:'thread'}],turns:[{thread_id:'thread',turn_id:'turn1',started_ms:1,ended_ms:1000,status:'completed'}],usage:[],commands:[],now:10000000};
 assert.equal(buildSpeed(options).rows.length,0);
 assert.equal(buildSpeed({...options,retained:new Set(['thread'])}).rows.length,1);
 assert.equal(buildSpeed({...options,receipts:{thread:{first_unread_turn:'turn1'}}}).rows.length,1);
});
test('ancient unread history is not imported as new activity on first launch',()=>{
 const old=row({is_open:false,state:'completed',ended_ms:1});
 assert.equal(new ActivityTracker().update([old],{thread:{first_unread_turn:'turn1'}},10000000).length,0);
});
const fs=require('node:fs'),path=require('node:path');const {DatabaseSync}=require('node:sqlite');const {Collector}=require('../src/collector.cjs');
function fixture(){const root=require('./fixture-root.cjs');fs.mkdirSync(root,{recursive:true});const dir=fs.mkdtempSync(path.join(root,'activity-'));const home=path.join(dir,'home');fs.mkdirSync(home);return {dir,home,c:new Collector({home,dataDir:path.join(dir,'data')})};}
test('history projects current unanswered questions and clears them at a terminal turn',()=>{
 const {home,c}=fixture();const h=new DatabaseSync(path.join(home,'thread_history_1.sqlite'));
 h.exec(`CREATE TABLE thread_turns(thread_id TEXT,turn_id TEXT,status TEXT,started_at REAL,completed_at REAL,duration_ms REAL,rollout_ordinal INTEGER);
 CREATE TABLE thread_items(thread_id TEXT,turn_id TEXT,item_id TEXT,item_type TEXT,item_json TEXT,started_at_ms REAL,completed_at_ms REAL);`);
 h.prepare('INSERT INTO thread_turns VALUES(?,?,?,?,?,?,?)').run('thread','turn','inProgress',100,0,0,1);
 c.sessions.set('thread',{id:'thread',log_available:true});
 h.prepare('INSERT INTO thread_items VALUES(?,?,?,?,?,?,?)').run('thread','turn','call_q','agentMessage',JSON.stringify({id:'call_q',questions:[{}]}),100000,100010);
 c.readTurnHistory();assert.equal(c.snapshot(110000).speed.activity[0].display_state,'waiting');
 h.prepare('INSERT INTO thread_items VALUES(?,?,?,?,?,?,?)').run('thread','turn','answer','userMessage',JSON.stringify({content:[{text:'<send_user_message_question_reply>'+JSON.stringify([{questionItemId:JSON.stringify(['request_user_input_async','call_q',0])}])+'</send_user_message_question_reply>'}]}),110000,110010);
 c.readTurnHistory();assert.equal(c.sessions.get('thread').pending_questions.length,0);
 h.exec("UPDATE thread_turns SET status='completed',completed_at=120");c.readTurnHistory();assert.equal(c.snapshot(121000).speed.activity[0].display_state,'completed');
 h.close();c.close();
});
test('rollout async accepted only creates waiting; actual reply and new turn clear it',()=>{
 const {c}=fixture(),cursor={};let tick=0;const send=(type,payload)=>c.ingestObject({type,payload,timestamp:new Date(100000+(++tick)*1000).toISOString()},cursor,'fixture.jsonl',tick);
 send('session_meta',{id:'thread'});send('event_msg',{type:'task_started',turn_id:'turn'});
 send('response_item',{type:'function_call',name:'request_user_input_async',call_id:'call_q',arguments:JSON.stringify({questions:[{}]})});
 assert.equal(c.sessions.get('thread').pending_questions.length,0);
 send('response_item',{type:'function_call_output',call_id:'call_q',output:'{"accepted":true}'});assert.equal(c.sessions.get('thread').pending_questions.length,1);
 send('response_item',{type:'message',role:'user',content:[{text:'<send_user_message_question_reply>'+JSON.stringify([{questionItemId:JSON.stringify(['request_user_input_async','call_q',0])}])+'</send_user_message_question_reply>'}]});
 assert.equal(c.sessions.get('thread').pending_questions.length,0);
 send('event_msg',{type:'task_started',turn_id:'turn2'});assert.equal(c.sessions.get('thread').pending_questions.length,0);c.close();
});
test('client receipts are read only and acknowledgements survive collector restart',()=>{
 const {home,dir,c}=fixture();const file=path.join(home,'state_5.sqlite');const source=new DatabaseSync(file);
 source.exec('CREATE TABLE threads(id TEXT,title TEXT); CREATE TABLE thread_read_receipts(thread_id TEXT, first_unread_turn TEXT, revision TEXT)');
 source.exec("INSERT INTO threads VALUES('thread','fixture'); INSERT INTO thread_read_receipts VALUES('thread','turn','r1')");source.close();const before=fs.readFileSync(file);
 c.readState();c.addTurn('thread','turn',1000,2000,'completed',1000,2000,'history');
 assert.equal(c.snapshot(3000).speed.activity.length,1);c.activity.acknowledge('thread','turn');c.snapshot(3001);c.close();
 const next=new Collector({home,dataDir:path.join(dir,'data')});next.readState();assert.equal(next.snapshot(3002).speed.activity.length,0);next.close();assert.deepEqual(fs.readFileSync(file),before);
});
