'use strict';
// Rates count completed usage records over wall-clock windows, not streamed generation speed.
const MINUTE=60000,DAY=86400000;
const terminal=s=>['completed','failed','interrupted'].includes(s);
function unionMilliseconds(intervals,start,end){
  const valid=intervals.map(([a,b])=>[Math.max(a,start),Math.min(b,end)]).filter(([a,b])=>Number.isFinite(a)&&Number.isFinite(b)&&b>a).sort((a,b)=>a[0]-b[0]);
  let total=0,left=null,right=null;
  for(const [a,b] of valid){if(left===null){left=a;right=b;}else if(a>right){total+=right-left;left=a;right=b;}else right=Math.max(right,b);}
  return total+(left===null?0:right-left);
}
function windowMetrics(records,now,seconds,available=true){
  const rows=records.filter(r=>r.at_ms>now-seconds*1000&&r.at_ms<=now);
  const sums={input:0,cached:0,output:0,reasoning:0,total:0,responses:0,legacy_records:0};
  for(const r of rows){for(const k of ['input','cached','output','reasoning','total'])sums[k]+=r[k]||0;if(r.kind==='response')sums.responses++;else sums.legacy_records++;}
  return {...sums,seconds,output_tps:available?sums.output/seconds:null,total_tpm:available?sums.total*(60/seconds):null,
    uncached_tpm:available?(Math.max(0,sums.input-sums.cached)+sums.output)*(60/seconds):null,
    responses_per_minute:available&&!sums.legacy_records?sums.responses*(60/seconds):null,
    cache_percent:sums.input&&sums.cached<=sums.input?sums.cached/sums.input*100:null};
}
function summarizeTurn(turn,records,commands,now,available){
  const end=terminal(turn.status)&&turn.ended_ms?Math.min(turn.ended_ms,now):now;
  const elapsed=Math.max(0,end-turn.started_ms),own=records.filter(r=>r.turn_id===turn.turn_id&&r.at_ms>=turn.started_ms&&r.at_ms<=end);
  const totals=windowMetrics(own,end,Math.max(1,elapsed/1000),available);
  const responses=own.filter(r=>r.kind==='response').sort((a,b)=>a.at_ms-b.at_ms);
  const intervals=commands.filter(c=>c.turn_id===turn.turn_id).map(c=>{
    let start=c.start_ms,end=c.end_ms;
    if(!end&&/progress|running/i.test(c.status||''))end=now;
    if(start>=end&&c.duration_ms>0)start=end-c.duration_ms;
    return [start,end];
  });
  const commandMs=unionMilliseconds(intervals,turn.started_ms,end);
  const gaps=responses.slice(1).map((r,i)=>r.at_ms-responses[i].at_ms).sort((a,b)=>a-b);
  const middle=gaps.length>>1,median=gaps.length?(gaps.length%2?gaps[middle]:(gaps[middle-1]+gaps[middle])/2):null;
  return {elapsed_ms:elapsed,total:own.reduce((n,r)=>n+r.total,0),input:own.reduce((n,r)=>n+r.input,0),cached:own.reduce((n,r)=>n+r.cached,0),
    output:own.reduce((n,r)=>n+r.output,0),reasoning:own.reduce((n,r)=>n+r.reasoning,0),responses:responses.length,
    average_output_tps:available&&elapsed>0?own.reduce((n,r)=>n+r.output,0)/(elapsed/1000):null,
    first_record_wait_ms:responses.length?responses[0].at_ms-turn.started_ms:null,
    last_record_at:responses.at(-1)?.at_ms||0,median_response_gap_ms:median,
    command_ms:commandMs,command_percent:elapsed>0?commandMs/elapsed*100:null,command_count:intervals.length,
    legacy_records:totals.legacy_records,available};
}
function buildSpeed({sessions,turns,usage,commands,edges=[],now=Date.now(),retained=new Set(),receipts={}}){
  const latest=new Map(),byUsage=new Map(),byCommands=new Map(),parents=new Map();
  for(const t of turns){if(t.started_ms<=0||t.started_ms>now)continue;const old=latest.get(t.thread_id);if(!old||t.started_ms>old.started_ms||t.started_ms===old.started_ms&&t.updated_ms>old.updated_ms)latest.set(t.thread_id,t);}
  for(const r of usage){if(r.at_ms>now)continue;if(!byUsage.has(r.thread_id))byUsage.set(r.thread_id,[]);byUsage.get(r.thread_id).push(r);}
  for(const c of commands){if(!byCommands.has(c.thread_id))byCommands.set(c.thread_id,[]);byCommands.get(c.thread_id).push(c);}
  for(const e of edges)if(e.kind!=='interaction'&&e.parent_id!==e.child_id&&!parents.has(e.child_id))parents.set(e.child_id,e.parent_id);
  const rows=[];
  for(const s of sessions){
    const t=latest.get(s.id);if(!t)continue;
    const isOpen=!terminal(t.status);if(!isOpen&&now-t.ended_ms>15*MINUTE&&!retained.has(s.id)&&receipts[s.id]?.first_unread_turn==null&&!s.pending_questions?.length)continue;
    const records=byUsage.get(s.id)||[],commandRows=byCommands.get(s.id)||[];
    const lastUsage=records.reduce((a,r)=>Math.max(a,r.at_ms),0);
    const activity=Math.max(s.last_event||0,t.updated_ms||0,lastUsage);
    const quiet=Math.max(0,now-activity),longStale=isOpen&&quiet>DAY;
    const state=isOpen?(quiet>10*MINUTE?'quiet':'running'):t.status;
    const available=!!s.log_available||records.some(r=>r.turn_id===t.turn_id);
    const one=windowMetrics(records,now,60,available),five=windowMetrics(records,now,300,available);
    const current=s.speed_context&&s.speed_context.at>=t.started_ms?s.speed_context:null;
    const recent=records.filter(r=>r.turn_id===t.turn_id).sort((a,b)=>b.at_ms-a.at_ms)[0];
    const model=current?.model||recent?.model||s.model||'unknown',effort=current?.effort||recent?.effort||'unknown',tier=current?.tier||recent?.tier||'unknown';
    const trend=Array.from({length:10},(_,i)=>{const end=now-(9-i)*30000;const m=windowMetrics(records,end,30,available);return {at:end,output_tps:m.output_tps,responses:m.responses};});
    rows.push({id:s.id,turn_id:t.turn_id,title:s.title||s.agent_path||s.id,source:s.thread_source||s.source||'user',parent_id:parents.get(s.id)||null,
      state,is_open:isOpen,long_stale:longStale,available,started_ms:t.started_ms,ended_ms:t.ended_ms,last_activity_at:activity,quiet_ms:quiet,requires_input:isOpen&&!!s.pending_questions?.length,
      model,effort,tier,one,five,turn:summarizeTurn(t,records,commandRows,now,available),trend});
  }
  rows.sort((a,b)=>Number(b.is_open)-Number(a.is_open)||Number(a.long_stale)-Number(b.long_stale)||b.started_ms-a.started_ms||a.id.localeCompare(b.id));
  return {as_of:now,rows,running:rows.filter(r=>r.state==='running').length,quiet:rows.filter(r=>r.state==='quiet'&&!r.long_stale).length,
    stale:rows.filter(r=>r.long_stale).length,recent_completed:rows.filter(r=>!r.is_open).length};
}
module.exports={windowMetrics,summarizeTurn,unionMilliseconds,buildSpeed};
