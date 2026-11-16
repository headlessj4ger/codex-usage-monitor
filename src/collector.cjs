'use strict';
// Local-only collector. Codex databases are opened read-only; no credentials or transcript bodies are stored.
const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');
const readline = require('node:readline');
const { spawn } = require('node:child_process');
const { DatabaseSync } = require('node:sqlite');
const { createHash } = require('node:crypto');
const { groupKey, dimensions, calibrationReport, estimateRows } = require('./calibration.cjs');
const { buildSpeed } = require('./speed.cjs');
const { ActivityTracker } = require('./activity.cjs');
const { answerIds, pendingFromItems } = require('./questions.cjs');
const { RefreshQueue, LocalChangeFeed } = require('./realtime.cjs');
const appVersion = require('./version.json').version;

const MINUTE = 60000, WEEK = 10080 * MINUTE;
const number = v => Number.isFinite(Number(v)) ? Math.max(0, Number(v)) : 0;
function usage(u = {}) {
  const input = number(u.input_tokens), output = number(u.output_tokens);
  return { input, cached: Math.min(input, number(u.cached_input_tokens)), output,
    reasoning: Math.min(output, number(u.reasoning_output_tokens)), total: u.total_tokens == null ? input + output : number(u.total_tokens) };
}
function hash(s) { return createHash('sha256').update(s).digest('hex'); }
function localPath(s) { return typeof s === 'string' ? s.replace(/^\\\\\?\\/, '') : s; }
function parse(value, fallback = null) { try { return JSON.parse(value); } catch { return fallback; } }
function sourceParent(source) {
  const s = typeof source === 'string' ? parse(source, {}) : source || {};
  return s.subagent?.thread_spawn?.parent_thread_id || null;
}
function weekdayStart(now) {
  const shifted = new Date(now + 8 * 3600000);
  const day = (shifted.getUTCDay() + 6) % 7;
  return Date.UTC(shifted.getUTCFullYear(), shifted.getUTCMonth(), shifted.getUTCDate() - day) - 8 * 3600000;
}
function periodFromQuota(quota, now = Date.now()) {
  if (quota && quota.reset_at * 1000 > now && quota.reset_at * 1000 - WEEK <= now)
    return { start: quota.reset_at * 1000 - WEEK, end: quota.reset_at * 1000, kind: 'quota', expired: false };
  const start = weekdayStart(now);
  return { start, end: start + WEEK, kind: 'calendar', expired: !!quota };
}
function normalizedWindows(raw) {
  if (!raw || typeof raw !== 'object') return [];
  const id = raw.limit_id || raw.limitId || 'codex';
  return ['primary', 'secondary'].flatMap(key => {
    const w = raw[key];
    if (!w || w.used_percent == null && w.usedPercent == null) return [];
    return [{ limit_id: id, window_minutes: number(w.window_minutes ?? w.windowDurationMins),
      reset_at: number(w.resets_at ?? w.resetsAt), used_percent: number(w.used_percent ?? w.usedPercent) }];
  });
}
function summarizeCommand(command) {
  // Retain only the executable/verb, never shell arguments, output, environment values, or scripts.
  const match = String(command || '').trim().match(/^(?:&\s*)?(?:"([^"\r\n]+)"|'([^'\r\n]+)'|([^\s;|&\r\n]+))/);
  if (!match) return '命令执行';
  let name = path.win32.basename(match[1] || match[2] || match[3]);
  return /^[\p{L}\p{N}_.-]{1,70}$/u.test(name) ? name : '脚本执行';
}
function flattenProcesses(rows, knownIds, monitorPid) {
  const all = new Map(rows.map(p => [Number(p.pid), p]));
  const selected = new Set(rows.filter(p => /codex/i.test(p.name || '') || Number(p.pid) === monitorPid).map(p => Number(p.pid)));
  // Include the desktop parent and descendants, but not unrelated sibling applications.
  for (const p of rows) if (/^codex\.exe$/i.test(p.name || '') && all.has(Number(p.ppid))) selected.add(Number(p.ppid));
  let changed = true;
  while (changed) { changed = false; for (const p of rows) if (selected.has(Number(p.ppid)) && !selected.has(Number(p.pid))) { selected.add(Number(p.pid)); changed = true; } }
  const result = rows.filter(p => selected.has(Number(p.pid))).map(p => {
    const command = String(p.command || '');
    const flag = command.match(/--(?:thread|session)[-_]id(?:=|\s+)["']?([0-9a-f-]{36})/i);
    const scoped = command.match(/[\\/]\.codex[\\/]node_repl[\\/]([0-9a-f-]{36})(?:[\\/]|["'\s]|$)/i);
    const candidate = (flag || scoped)?.[1];
    const thread_id = candidate && knownIds.has(candidate) ? candidate : null;
    return { pid: Number(p.pid), ppid: Number(p.ppid), name: p.name, created: p.created,
      memory: number(p.memory), cpu: number(p.cpu), thread_id, association: thread_id ? 'explicit' : 'unknown' };
  });
  const byPid = new Map(result.map(p => [p.pid, p]));
  for (const p of result) {
    let parent = byPid.get(p.ppid); const seen = new Set([p.pid]);
    while (!p.thread_id && parent && !seen.has(parent.pid)) {
      seen.add(parent.pid);
      if (!Number.isFinite(Date.parse(parent.created)) || !Number.isFinite(Date.parse(p.created)) || Date.parse(parent.created) > Date.parse(p.created)) break; // PID reuse or missing creation data.
      if (parent.thread_id) { p.thread_id = parent.thread_id; p.association = 'ancestor'; break; }
      parent = byPid.get(parent.ppid);
    }
  }
  return result;
}

class Collector {
  constructor(options = {}) {
    this.processSampler = options.processSampler;
    this.home = options.home || process.env.CODEX_HOME || path.join(os.homedir(), '.codex');
    this.dataDir = options.dataDir || path.join(__dirname, 'data');
    fs.mkdirSync(this.dataDir, { recursive: true });
    this.db = new DatabaseSync(path.join(this.dataDir, 'usage-v2.sqlite'));
    this.db.exec(`PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL; PRAGMA busy_timeout=3000;
      CREATE TABLE IF NOT EXISTS usage(event_key TEXT PRIMARY KEY,thread_id TEXT,at_ms INTEGER,model TEXT,input INTEGER,cached INTEGER,output INTEGER,reasoning INTEGER,total INTEGER,kind TEXT);
      CREATE INDEX IF NOT EXISTS usage_time ON usage(at_ms,thread_id);
      CREATE INDEX IF NOT EXISTS usage_thread ON usage(thread_id,at_ms);
      CREATE TABLE IF NOT EXISTS sessions(id TEXT PRIMARY KEY,json TEXT);
      CREATE TABLE IF NOT EXISTS cursors(path TEXT PRIMARY KEY,json TEXT);
      CREATE TABLE IF NOT EXISTS edges(parent_id TEXT,child_id TEXT,kind TEXT,evidence TEXT,PRIMARY KEY(parent_id,child_id,kind));
      CREATE TABLE IF NOT EXISTS quotas(event_key TEXT PRIMARY KEY,limit_id TEXT,window_minutes INTEGER,reset_at INTEGER,at_ms INTEGER,used_percent REAL);
      CREATE INDEX IF NOT EXISTS quota_latest ON quotas(window_minutes,at_ms);
      CREATE TABLE IF NOT EXISTS commands(thread_id TEXT,id TEXT,turn_id TEXT,start_ms INTEGER,end_ms INTEGER,process_ref TEXT,source TEXT,status TEXT,exit_code INTEGER,duration_ms REAL,executable TEXT,cwd TEXT,PRIMARY KEY(thread_id,id));
      CREATE INDEX IF NOT EXISTS command_thread ON commands(thread_id,start_ms);
      CREATE TABLE IF NOT EXISTS turns(thread_id TEXT,turn_id TEXT,started_ms INTEGER,ended_ms INTEGER,status TEXT,duration_ms REAL,updated_ms INTEGER,source TEXT,PRIMARY KEY(thread_id,turn_id));
      CREATE INDEX IF NOT EXISTS turn_started ON turns(started_ms,thread_id);`);
    // Non-destructive migration: replay available logs to backfill dimensions, retaining pruned history.
    const usageFields=new Set(this.db.prepare('PRAGMA table_info(usage)').all().map(r=>r.name));
    const quotaFields=new Set(this.db.prepare('PRAGMA table_info(quotas)').all().map(r=>r.name));
    let backfill=this.db.prepare('PRAGMA user_version').get().user_version<5;
    this.db.exec('BEGIN');
    for(const field of ['effort','tier','scope','turn_id'])if(!usageFields.has(field)){this.db.exec(`ALTER TABLE usage ADD COLUMN ${field} TEXT NOT NULL DEFAULT 'unknown'`);backfill=true;}
    for(const field of ['scope','plan'])if(!quotaFields.has(field)){this.db.exec(`ALTER TABLE quotas ADD COLUMN ${field} TEXT NOT NULL DEFAULT 'unknown'`);backfill=true;}
    if(backfill)this.db.exec('DELETE FROM cursors');
    this.db.exec('PRAGMA user_version=5; COMMIT');
    this.sessions = new Map(this.db.prepare('SELECT * FROM sessions').all().map(r => [r.id, parse(r.json, {})]));
    this.cursors = new Map(this.db.prepare('SELECT * FROM cursors').all().map(r => [r.path, parse(r.json, {})]));
    this.insertUsage = this.db.prepare(`INSERT INTO usage(event_key,thread_id,at_ms,model,input,cached,output,reasoning,total,kind,effort,tier,scope,turn_id) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?)
      ON CONFLICT(event_key) DO UPDATE SET model=CASE WHEN excluded.model!='unknown' THEN excluded.model ELSE usage.model END,
      effort=CASE WHEN excluded.model!='unknown' AND excluded.turn_id!='unknown' THEN excluded.effort ELSE usage.effort END,
      tier=CASE WHEN excluded.model!='unknown' AND excluded.turn_id!='unknown' THEN excluded.tier ELSE usage.tier END,
      scope=CASE WHEN excluded.scope!='unknown' THEN excluded.scope ELSE usage.scope END,
      turn_id=CASE WHEN excluded.turn_id!='unknown' THEN excluded.turn_id ELSE usage.turn_id END`);
    this.insertQuota = this.db.prepare(`INSERT INTO quotas(event_key,limit_id,window_minutes,reset_at,at_ms,used_percent,scope,plan) VALUES(?,?,?,?,?,?,?,?)
      ON CONFLICT(event_key) DO UPDATE SET scope=CASE WHEN excluded.scope!='unknown' THEN excluded.scope ELSE quotas.scope END,
      plan=CASE WHEN excluded.plan!='unknown' THEN excluded.plan ELSE quotas.plan END`);
    this.insertCommand = this.db.prepare(`INSERT INTO commands VALUES(?,?,?,?,?,?,?,?,?,?,?,?) ON CONFLICT(thread_id,id) DO UPDATE SET
      end_ms=MAX(commands.end_ms,excluded.end_ms),status=excluded.status,exit_code=COALESCE(excluded.exit_code,commands.exit_code),duration_ms=excluded.duration_ms,
      executable=CASE WHEN excluded.executable!='命令执行' THEN excluded.executable ELSE commands.executable END,
      process_ref=CASE WHEN excluded.process_ref!='' THEN excluded.process_ref ELSE commands.process_ref END,
      cwd=CASE WHEN excluded.cwd!='' THEN excluded.cwd ELSE commands.cwd END`);
    this.insertTurn=this.db.prepare(`INSERT INTO turns VALUES(?,?,?,?,?,?,?,?) ON CONFLICT(thread_id,turn_id) DO UPDATE SET
      started_ms=CASE WHEN turns.started_ms=0 OR excluded.source='rollout' AND excluded.started_ms>0 THEN excluded.started_ms ELSE turns.started_ms END,
      ended_ms=MAX(turns.ended_ms,excluded.ended_ms),
      status=CASE WHEN turns.ended_ms>0 AND excluded.ended_ms=0 THEN turns.status ELSE excluded.status END,
      duration_ms=COALESCE(excluded.duration_ms,turns.duration_ms),updated_ms=MAX(turns.updated_ms,excluded.updated_ms),source=excluded.source`);
    this.db.exec('CREATE TABLE IF NOT EXISTS activity_state (id INTEGER PRIMARY KEY, json TEXT NOT NULL)');
    this.activity=new ActivityTracker(parse(this.db.prepare('SELECT json FROM activity_state WHERE id=1').get()?.json,{}));
    this.receipts={};this.activitySaved='';
    this.warnings = []; this.processes = []; this.processAt = 0; this.processError = null;
    this.lastScan = 0; this.scanning = false; this.stateAvailable = false; this.selected = null;
  }
  warn(text) { if (!this.warnings.includes(text)) this.warnings.push(text); }
  edge(parent, child, kind, evidence) {
    if (parent && child && parent !== child) this.db.prepare('INSERT OR REPLACE INTO edges VALUES(?,?,?,?)').run(parent, child, kind, evidence);
  }
  statePath() {
    const names = fs.readdirSync(this.home).filter(n => /^state_\d+\.sqlite$/.test(n));
    names.sort((a,b) => Number(b.match(/\d+/)[0]) - Number(a.match(/\d+/)[0]));
    return names.length ? path.join(this.home, names[0]) : null;
  }
  readState() {
    this.receipts={};
    let source;
    try {
      const file = this.statePath(); if (!file) return;
      source = new DatabaseSync(file, { readOnly: true });
      source.exec('PRAGMA query_only=ON; PRAGMA busy_timeout=1000');
      const fields = new Set(source.prepare('PRAGMA table_info(threads)').all().map(r => r.name));
      const wanted = ['id','rollout_path','created_at','updated_at','source','model_provider','cwd','title','name','tokens_used','archived','agent_nickname','agent_role','agent_path','model','thread_source','attached_thread_parent_id'];
      const rows = source.prepare('SELECT ' + wanted.filter(k => fields.has(k)).join(',') + ' FROM threads').all();
      for (const row of rows) {
        const old = this.sessions.get(row.id) || {};
        const s = { ...old, ...row, title:row.name || row.title, rollout_path:localPath(row.rollout_path),cwd:localPath(row.cwd),created: number(row.created_at) * 1000, updated: number(row.updated_at) * 1000, metadata_tokens: number(row.tokens_used) };
        delete s.tokens_used;
        const parent = sourceParent(row.source);
        if (parent) this.edge(parent, row.id, 'subagent', 'state.source');
        if (row.attached_thread_parent_id) this.edge(row.attached_thread_parent_id, row.id, 'attached', 'state.attached_thread_parent_id');
        this.sessions.set(row.id, s);
      }
      if (source.prepare("SELECT name FROM sqlite_master WHERE name='thread_spawn_edges'").get())
        for (const e of source.prepare('SELECT parent_thread_id,child_thread_id FROM thread_spawn_edges').all()) this.edge(e.parent_thread_id, e.child_thread_id, 'subagent', 'state.thread_spawn_edges');
      this.stateAvailable = true;
      this.receipts={};
      if(source.prepare("SELECT name FROM sqlite_master WHERE name='thread_read_receipts'").get()){
        for(const receipt of source.prepare('SELECT thread_id,first_unread_turn,revision FROM thread_read_receipts').all())this.receipts[receipt.thread_id]=receipt;
      }
    } catch (e) { this.warn('会话数据库读取失败：' + e.message); this.stateAvailable = false; }
    finally { if (source) source.close(); }
  }
  discoverFiles() {
    const found = new Set();
    const walk = dir => {
      let entries; try { entries = fs.readdirSync(dir, { withFileTypes: true }); } catch { return; }
      for (const e of entries) { const full = path.join(dir, e.name); if (e.isDirectory()) walk(full); else if (e.isFile() && e.name.endsWith('.jsonl')) found.add(full); }
    };
    walk(path.join(this.home,'sessions')); walk(path.join(this.home,'archived_sessions'));
    // Only local rollout files below CODEX_HOME are eligible; metadata cannot redirect the collector to unrelated files.
    for (const s of this.sessions.values()) if (s.rollout_path && s.rollout_path.endsWith('.jsonl')) {
      const relative = path.relative(this.home, s.rollout_path);
      if (!relative.startsWith('..') && !path.isAbsolute(relative) && fs.existsSync(s.rollout_path)) found.add(s.rollout_path);
    }
    return [...found];
  }
  addUsage(key, thread, at, model, u, kind, context = {}) {
    this.insertUsage.run(key, thread, at, model || 'unknown', u.input, u.cached, u.output, u.reasoning, u.total, kind,context.effort||'unknown',context.tier||'unknown',context.scope||'unknown',context.turn||'unknown');
    this.calibrationCache=null;
  }
  context(cursor, settings, turn, reset = false, remember = true) {
    const collaboration=settings.collaboration_mode?.settings||{};
    cursor.model=settings.model||collaboration.model||(reset?'unknown':cursor.model)||'unknown';
    cursor.effort=settings.effort||settings.reasoning_effort||settings.reasoning?.effort||collaboration.reasoning_effort||(reset?'unknown':cursor.effort)||'unknown';
    cursor.tier=Object.hasOwn(settings,'service_tier')?(settings.service_tier||'unknown'):(cursor.tier||'unknown');
    if(turn)cursor.turn=turn;
    if(cursor.turn && remember){
      cursor.contexts||={};cursor.contexts[cursor.turn]={model:cursor.model,effort:cursor.effort,tier:cursor.tier,turn:cursor.turn};
      const keys=Object.keys(cursor.contexts);for(const key of keys.slice(0,-64))delete cursor.contexts[key];
    }
  }
  ingestObject(obj, cursor, file, byteOffset) {
    const p = obj.payload || {}, at = Date.parse(obj.timestamp) || 0;
    if (obj.type === 'session_meta') {
      const id = cursor.owner || p.id; if (!id) return;
      cursor.id = id;
      if(p.id===id && p.creator_account_id)cursor.scope=hash(String(p.creator_account_id));
      if (cursor.owner && p.id && p.id !== cursor.owner) {
        // Full-history forks can retain the parent's session_meta at byte 0.
        // The state database / rollout filename identifies the actual owner.
        const child = this.sessions.get(id);
        cursor.created = child?.created || cursor.created || 0;
        this.edge(p.id,id,child?.thread_source==='subagent'?'subagent':child?.thread_source==='guardian_review'?'guardian':'fork','rollout.inherited_session_meta');
        if(child){child.rollout_path=file;child.log_available=true;}
        return;
      }
      cursor.created = Date.parse(p.timestamp || obj.timestamp) || cursor.created || 0;
      const s = this.sessions.get(id) || { id, title: p.agent_path || p.agent_nickname || id, metadata_tokens: 0 };
      Object.assign(s, { rollout_path: file, log_available:true, created: s.created || cursor.created, source: p.source,
        cwd: localPath(p.cwd) || s.cwd, thread_source: p.thread_source || s.thread_source || 'user',
        agent_path: p.agent_path || s.agent_path, model_provider: p.model_provider || s.model_provider });
      this.sessions.set(id, s);
      const fork = p.forked_from_id || p.forked_from_thread_id;
      if (fork) this.edge(fork, id, 'fork', 'rollout.session_meta');
      const parent = p.parent_thread_id || sourceParent(p.source);
      if (parent) this.edge(parent, id, s.thread_source === 'guardian_review' ? 'guardian' : 'subagent', 'rollout.session_meta');
      return;
    }
    if (!cursor.id) return;
    const s = this.sessions.get(cursor.id);
    if (!s) return;
    s.last_event = Math.max(s.last_event || 0, at);
    if (obj.type === 'turn_context') { this.context(cursor,p,p.turn_id,true);cursor.contextAt=at;if(at>=cursor.created)s.speed_context={model:cursor.model,effort:cursor.effort,tier:cursor.tier,at}; return; }
    if (p.type === 'thread_settings_applied') {
      const settings=p.thread_settings||{};
      this.context(cursor,settings,p.turn_id,false,!!p.turn_id);
      // Desktop logs emit settings immediately before OR after turn_context. The latter
      // can supply its missing tier, but must not rewrite a preceding, already-running turn.
      const active=cursor.contexts?.[cursor.turn];
      if(!p.turn_id && active && at>=cursor.contextAt && at-cursor.contextAt<=1000 && active.model===settings.model && active.effort===(settings.reasoning_effort||settings.effort))active.tier=cursor.tier;
      if(active&&at>=cursor.created&&at-cursor.contextAt<=1000)s.speed_context={...active,at:cursor.contextAt};
      return;
    }
    if (obj.type === 'response_item' && p.type === 'configuration_update') { this.context(cursor,p,p.turn_id);if(at>=cursor.created)s.speed_context={model:cursor.model,effort:cursor.effort,tier:cursor.tier,at}; return; }
    if(at>=cursor.created&&(!p.thread_id||p.thread_id===cursor.id)){
      if(p.type==='task_started'){
        s.last_task_start=at;cursor.task_turn=p.turn_id||cursor.turn;
        s.pending_questions=[];cursor.questionCalls={};s.rollout_questions={turn_id:cursor.task_turn,pending:[],answered:[]};
        this.addTurn(cursor.id,cursor.task_turn,at,0,'inProgress',null,at,'rollout');
      }
      if(['task_complete','task_aborted','turn_aborted'].includes(p.type)){
        s.last_task_end=at;
        s.pending_questions=[];cursor.questionCalls={};s.rollout_questions=null;
        const turn=p.turn_id||cursor.task_turn||cursor.turn,duration=Number.isFinite(p.duration_ms)?p.duration_ms:null;
        this.addTurn(cursor.id,turn,0,at,p.type==='task_complete'?'completed':'interrupted',duration,at,'rollout');
      }
    }
    if(obj.type==='response_item'&&at>=cursor.created){
      if(p.type==='function_call'&&p.name?.split('.').at(-1)==='request_user_input_async'){
        const args=parse(p.arguments,{});cursor.questionCalls||={};
        if(Array.isArray(args.questions))cursor.questionCalls[p.call_id]=args.questions.map((_,i)=>JSON.stringify(['request_user_input_async',p.call_id,i]));
      }
      if(p.type==='function_call_output'&&cursor.questionCalls?.[p.call_id]){
        if(parse(p.output,{})?.accepted===true){
          s.rollout_questions||={turn_id:cursor.task_turn||cursor.turn,pending:[],answered:[]};
          s.rollout_questions.pending=[...new Set([...s.rollout_questions.pending,...cursor.questionCalls[p.call_id]])];
          s.pending_questions=[...new Set([...(s.pending_questions||[]),...cursor.questionCalls[p.call_id]])];
        }
        delete cursor.questionCalls[p.call_id];
      }
      if(p.type==='message'&&p.role==='user'){
        const answered=answerIds(p.content);s.pending_questions=(s.pending_questions||[]).filter(id=>!answered.has(id));
        if(s.rollout_questions){s.rollout_questions.pending=s.rollout_questions.pending.filter(id=>!answered.has(id));s.rollout_questions.answered=[...new Set([...s.rollout_questions.answered,...answered])];}
      }
    }
    if (obj.type === 'token_usage_record') {
      // A fork may contain copied parent records. Record ownership is authoritative.
      if (p.thread_id && p.thread_id !== cursor.id) return;
      if (at < cursor.created) return;
      const u = usage(p.usage);
      const key = p.response_id ? 'response:' + p.response_id : 'record:' + cursor.id + ':' + (obj.ordinal ?? byteOffset);
      const context=p.turn_id ? cursor.contexts?.[p.turn_id]||{model:'unknown'} : cursor;
      this.addUsage(key, cursor.id, at, context.model, u, 'response',{...context,scope:cursor.scope});
      cursor.recordSinceCount = true;
      s.record_count = (s.record_count || 0) + 1;
      return;
    }
    if (p.type === 'token_count') {
      for (const q of normalizedWindows(p.rate_limits)) {
        const key = hash([q.limit_id,q.window_minutes,q.reset_at,at,q.used_percent].join(':'));
        this.insertQuota.run(key,q.limit_id,q.window_minutes,q.reset_at,at,q.used_percent,cursor.scope||'unknown',p.rate_limits?.plan_type||'unknown');
        this.calibrationCache=null;
      }
      const raw = p.info?.total_token_usage;
      if (!raw) return;
      const current = usage(raw), previous = cursor.baseline;
      if (!cursor.recordSinceCount && at >= cursor.created) {
        let delta;
        if (previous && current.total < previous.total) {
          // A counter reset is not negative spend. Use only the explicitly reported last request.
          delta = p.info.last_token_usage ? usage(p.info.last_token_usage) : null;
        } else delta = Object.fromEntries(Object.keys(current).map(k => [k, Math.max(0,current[k] - (previous?.[k] || 0))]));
        if (delta && delta.total > 0) this.addUsage('legacy:' + cursor.id + ':' + hash([at,JSON.stringify(current)].join(':')),cursor.id,at,cursor.model,delta,'cumulative_delta',cursor);
      }
      cursor.baseline = current; cursor.recordSinceCount = false;
      s.last_counter = current.total;
      return;
    }
    if (p.type === 'item_completed') {
      if (p.thread_id && p.thread_id !== cursor.id || at < cursor.created) return;
      const i = p.item || {};
      if (i.type === 'CommandExecution' || i.type === 'commandExecution') this.addCommand(cursor.id, p.turn_id || cursor.turn, i, p.started_at_ms || at, p.completed_at_ms || at);
      if (i.type === 'CollabAgentToolCall' || i.type === 'collabAgentToolCall') {
        const receivers = i.receiver_thread_ids || i.receiverThreadIds || [];
        // Calls to existing peers are interactions, never inferred parenthood.
        for (const receiver of receivers) this.edge(cursor.id,receiver,'interaction','rollout.collabAgentToolCall');
      }
    }
  }
  addCommand(thread, turn, i, started, ended) {
    const d = i.duration;
    const duration = i.durationMs ?? (d && typeof d === 'object' ? number(d.secs) * 1000 + number(d.nanos) / 1e6 : number(d));
    this.insertCommand.run(thread,String(i.id),turn || '',number(started),number(ended),String(i.process_id ?? i.processId ?? ''),i.source || '',i.status || '',i.exit_code ?? i.exitCode ?? null,duration,summarizeCommand(i.command),i.cwd || '');
  }
  addTurn(thread,turn,started,ended,status,duration,updated,source){
    if(!thread||!turn)return;
    this.insertTurn.run(thread,turn,started||0,ended||0,status,duration,updated||0,source);
  }
  readTurnHistory(){
    let history;
    try{
      const file=path.join(this.home,'thread_history_1.sqlite');if(!fs.existsSync(file))return;
      history=new DatabaseSync(file,{readOnly:true});history.exec('PRAGMA query_only=ON; PRAGMA busy_timeout=1000');
      // Latest turn per thread prevents an orphaned old inProgress record from looking current.
      const rows=history.prepare(`SELECT thread_id,turn_id,status,started_at,completed_at,duration_ms FROM
        (SELECT thread_id,turn_id,status,started_at,completed_at,duration_ms,ROW_NUMBER() OVER(PARTITION BY thread_id ORDER BY started_at DESC,rollout_ordinal DESC) n FROM thread_turns) WHERE n=1`).all();
      const itemFields=new Set(history.prepare('PRAGMA table_info(thread_items)').all().map(r=>r.name));
      const questionQuery=itemFields.has('item_json')?history.prepare("SELECT item_id,item_type,item_json FROM thread_items WHERE thread_id=? AND turn_id=? AND item_type IN ('agentMessage','userMessage')"):null;
      const latestTurn=this.db.prepare('SELECT turn_id,started_ms,ended_ms FROM turns WHERE thread_id=? ORDER BY started_ms DESC,updated_ms DESC LIMIT 1');
      for(const r of rows){const session=this.sessions.get(r.thread_id);if(!session)continue;
        const known=latestTurn.get(r.thread_id);
        if(known&&known.turn_id!==r.turn_id&&known.started_ms>number(r.started_at)*1000)continue;
        if(r.status!=='inProgress'||known?.turn_id===r.turn_id&&known.ended_ms>0)session.pending_questions=[];
        else if(questionQuery){
          const items=questionQuery.all(r.thread_id,r.turn_id),projected=pendingFromItems(items);
          const log=session.rollout_questions?.turn_id===r.turn_id?session.rollout_questions:null;
          const answered=new Set(log?.answered||[]);
          for(const item of items)if(item.item_type==='userMessage')for(const id of answerIds(parse(item.item_json,{})?.content))answered.add(id);
          session.pending_questions=[...new Set([...projected,...(log?.pending||[])])].filter(id=>!answered.has(id));
        }
      }
      this.db.exec('BEGIN');
      try{
        for(const r of rows){if(!this.sessions.has(r.thread_id))continue;const start=number(r.started_at)*1000,end=number(r.completed_at)*1000;
          this.addTurn(r.thread_id,r.turn_id,start,end,r.status,r.duration_ms,Math.max(start,end),'history');}
        this.db.exec('COMMIT');
      }catch(e){this.db.exec('ROLLBACK');throw e;}
      // Only timing/status fields are read for live commands; no command text or tool output.
      const live=rows.filter(r=>(r.status==='inProgress'||number(r.completed_at)*1000>Date.now()-15*MINUTE)&&this.sessions.has(r.thread_id));
      const query=history.prepare("SELECT item_id,started_at_ms,completed_at_ms FROM thread_items WHERE thread_id=? AND turn_id=? AND item_type='commandExecution'");
      const existing=this.db.prepare('SELECT end_ms FROM commands WHERE thread_id=? AND id=?');
      const finish=this.db.prepare("UPDATE commands SET end_ms=?,duration_ms=?,status='completed' WHERE thread_id=? AND id=? AND end_ms=0");
      for(const r of live)for(const item of query.all(r.thread_id,r.turn_id)){
        if(!item.started_at_ms)continue;const known=existing.get(r.thread_id,item.item_id),end=item.completed_at_ms||0;
        if(!known)this.addCommand(r.thread_id,r.turn_id,{id:item.item_id,status:end?'completed':'inProgress',durationMs:end?end-item.started_at_ms:0},item.started_at_ms,end);
        else if(!known.end_ms&&end)finish.run(end,Math.max(0,end-item.started_at_ms),r.thread_id,item.item_id);
      }
      this.turnHistoryAvailable=true;
    }catch(e){this.turnHistoryAvailable=false;this.warn('轮次状态读取失败：'+e.message);}
    finally{if(history)history.close();}
  }
  async readFile(file) {
    const stat = fs.statSync(file);
    let cursor = this.cursors.get(file) || { offset: 0, fileId: String(stat.ino), size: 0 };
    if (stat.size < cursor.offset || cursor.fileId && cursor.fileId !== String(stat.ino) || stat.size === cursor.offset && cursor.mtime !== stat.mtimeMs) {
      // Re-read replaced/truncated sources. Stable event keys make replay idempotent.
      cursor = { offset: 0, fileId: String(stat.ino), size: 0 };
    }
    if (stat.size === cursor.offset && cursor.mtime === stat.mtimeMs) return;
    const suffix = path.basename(file).match(/([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\.jsonl$/i)?.[1];
    const owner = suffix && this.sessions.has(suffix) ? suffix : [...this.sessions.values()].find(s=>s.rollout_path===file)?.id;
    if(owner){cursor.owner=owner;cursor.id=owner;cursor.created=this.sessions.get(owner).created||cursor.created||0;this.sessions.get(owner).log_available=true;}
    const stream = fs.createReadStream(file,{ start: cursor.offset, end: Math.max(cursor.offset,stat.size - 1), highWaterMark: 256 * 1024 });
    let pending = Buffer.alloc(0), committed = cursor.offset;
    this.db.exec('BEGIN');
    try {
      for await (const chunk of stream) {
        pending = Buffer.concat([pending,chunk]); let from = 0, end;
        while ((end = pending.indexOf(10,from)) >= 0) {
          const text = pending.subarray(from,end).toString('utf8').replace(/^\uFEFF/, '').replace(/\r$/, '');
          const obj = parse(text);
          if (obj) this.ingestObject(obj,cursor,file,committed);
          else if (text.trim()) this.warn('有损坏的日志行已跳过：' + path.basename(file));
          const length = end - from + 1; committed += length; from = end + 1;
        }
        pending = pending.subarray(from);
        if (pending.length > 32 * 1024 * 1024) throw new Error('日志单行超过 32 MB');
      }
      // An unfinished final line is intentionally left for the next scan.
      cursor.offset = committed; cursor.mtime = stat.mtimeMs; cursor.size = stat.size; cursor.fileId = String(stat.ino);
      this.cursors.set(file,cursor);
      this.db.prepare('INSERT OR REPLACE INTO cursors VALUES(?,?)').run(file,JSON.stringify(cursor));
      if (cursor.id && this.sessions.has(cursor.id)) this.saveSession(this.sessions.get(cursor.id));
      this.db.exec('COMMIT');
    } catch (e) { this.db.exec('ROLLBACK'); this.cursors.delete(file); throw e; }
  }
  saveSession(s) { this.db.prepare('INSERT OR REPLACE INTO sessions VALUES(?,?)').run(s.id,JSON.stringify(s)); }
  async scan({snapshot=true}={}) {
    if (this.scanning) return null;
    this.scanning = true; this.warnings = [];
    try {
      this.readState();
      const files = this.discoverFiles();
      const present = new Set(files);
      for (const s of this.sessions.values()) s.log_available = present.has(s.rollout_path);
      for (const file of files) { try { await this.readFile(file); } catch (e) { this.warn(path.basename(file) + '：' + e.message); } }
      this.readTurnHistory();
      this.db.exec('BEGIN');
      try { for (const s of this.sessions.values()) this.saveSession(s); this.db.exec('COMMIT'); }
      catch (e) { this.db.exec('ROLLBACK'); throw e; }
      this.lastScan = Date.now();
      this.lastActivityScan=this.lastScan;
      return snapshot?this.snapshot():null;
    } finally { this.scanning = false; }
  }
  async scanActivity(change={}){
    if(this.scanning)throw new Error('采集任务重叠');
    this.scanning=true;
    try{
      if(change.state)this.readState();
      const files=new Set(change.files||[]);
      if(change.state)for(const s of this.sessions.values())if(s.rollout_path&&!this.cursors.has(s.rollout_path))files.add(s.rollout_path);
      for(const file of files){
        const relative=path.relative(this.home,file);
        if(relative.startsWith('..')||path.isAbsolute(relative)||!file.endsWith('.jsonl'))continue;
        try{if(fs.existsSync(file))await this.readFile(file);else for(const s of this.sessions.values())if(s.rollout_path===file)s.log_available=false;}
        catch(error){this.warn(path.basename(file)+'：'+error.message);}
      }
      if(change.history||change.state||files.size)this.readTurnHistory();
      this.lastActivityScan=Date.now();
      return this.activitySnapshot();
    }finally{this.scanning=false;}
  }
  speedSnapshot(now=Date.now(),edges=this.db.prepare('SELECT * FROM edges').all()){
    const speed=buildSpeed({now,sessions:[...this.sessions.values()],edges,retained:this.activity.retainedIds(),receipts:this.receipts,
      turns:this.db.prepare('SELECT * FROM turns').all(),usage:this.db.prepare('SELECT * FROM usage WHERE at_ms<=?').all(now),
      commands:this.db.prepare('SELECT thread_id,turn_id,start_ms,end_ms,status,duration_ms FROM commands').all()});
    speed.activity=this.activity.update(speed.rows,this.receipts,now);
    const activitySaved=JSON.stringify(this.activity.entries);
    if(activitySaved!==this.activitySaved){this.db.prepare('INSERT OR REPLACE INTO activity_state VALUES(1,?)').run(activitySaved);this.activitySaved=activitySaved;}
    speed.capabilities={read_receipts:Object.keys(this.receipts).length>0,questions:'rollout',permission_approvals:false};
    return speed;
  }
  activitySnapshot(now=Date.now()){
    return {type:'activity',at:now,last_activity_scan:this.lastActivityScan||0,speed:this.speedSnapshot(now)};
  }
  snapshot(now = Date.now()) {
    const quota = this.db.prepare("SELECT * FROM quotas WHERE window_minutes=10080 AND limit_id='codex' AND at_ms<=? ORDER BY at_ms DESC LIMIT 1").get(now) || null;
    const period = periodFromQuota(quota,now);
    const all = new Map(this.db.prepare('SELECT thread_id,SUM(total) total,SUM(input) input,SUM(cached) cached,SUM(output) output,SUM(reasoning) reasoning,COUNT(*) requests FROM usage GROUP BY thread_id').all().map(r => [r.thread_id,r]));
    const weekly = new Map(this.db.prepare('SELECT thread_id,SUM(total) total,SUM(input) input,SUM(cached) cached,SUM(output) output,SUM(reasoning) reasoning,COUNT(*) requests FROM usage WHERE at_ms>=? AND at_ms<? GROUP BY thread_id').all(period.start,Math.min(now + 1,period.end)).map(r => [r.thread_id,r]));
    const commandCounts = new Map(this.db.prepare('SELECT thread_id,COUNT(*) n FROM commands GROUP BY thread_id').all().map(r => [r.thread_id,r.n]));
    const edges = this.db.prepare('SELECT * FROM edges').all();
    const items = [...this.sessions.values()].map(s => {
      const totals = all.get(s.id), week = weekly.get(s.id);
      const recorded = totals?.total || 0;
      const total = Math.max(recorded,s.metadata_tokens || 0);
      const coverage = !s.log_available && !recorded ? 'metadata' : total > recorded ? 'partial' : 'records';
      return { id:s.id, title:s.title || s.agent_path || s.id, source:s.thread_source || 'user', model:s.model || 'unknown',
        agent_path:s.agent_path || '', cwd:s.cwd || '', archived:!!s.archived,
        created:s.created || 0, updated:Math.max(s.updated || 0,s.last_event || 0), total, recorded,
        input:totals?.input ?? null,cached:totals?.cached ?? null,output:totals?.output ?? null,reasoning:totals?.reasoning ?? null,
        week_total:week?.total || 0, week_input:week?.input || 0,week_cached:week?.cached || 0,week_output:week?.output || 0,
        week_known:!!s.log_available || !!week, coverage, requests:totals?.requests || 0,
        commands:commandCounts.get(s.id) || 0, log_available:!!s.log_available,
        active:!!s.last_task_start && s.last_task_start > (s.last_task_end || 0) && now - (s.last_event || 0) < 180000 };
    });
    const weekTotal = items.reduce((sum,s) => sum + s.week_total,0);
    for (const item of items) {
      item.local_share = weekTotal ? item.week_total / weekTotal * 100 : null;
      // This is deliberately a transparent allocation scenario, not a billed per-thread quota.
      item.quota_allocation = quota && period.kind === 'quota' && weekTotal && item.week_known ? quota.used_percent * item.week_total / weekTotal : null;
    }
    const learned=this.calibrationSnapshot(quota,period,now,items);
    const speed=this.speedSnapshot(now,edges);
    const speedById=new Map(speed.rows.map(r=>[r.id,r]));
    for(const item of items){
      const estimate=learned.byThread.get(item.id);
      item.quota_estimate=estimate?.value??null;
      item.quota_estimated_tokens=estimate?.covered_tokens||0;
      item.quota_eligible_tokens=estimate?.total_tokens||0;
      const live=speedById.get(item.id);item.active=!!live?.is_open&&!live.long_stale;item.speed=live||null;
    }
    items.sort((a,b) => b.updated-a.updated);
    return { type:'snapshot',version:1,app_version:appVersion,at:now,last_scan:this.lastScan,home:this.home,quota:quota ? {...quota,age_ms:now-quota.at_ms,expired:period.expired} : null,
      period,week_total:weekTotal,lifetime_total:items.reduce((sum,s) => sum+s.total,0),sessions:items,edges,calibration:learned.report,combinations:learned.combinations,speed,
      coverage:{ sessions:items.length,with_logs:items.filter(s => s.log_available).length,metadata_only:items.filter(s => s.coverage==='metadata').length,
        recent_missing:items.filter(s => !s.log_available && s.updated>=period.start).length },
      processes:this.processes,process_at:this.processAt,process_error:this.processError,warnings:this.warnings,state_available:this.stateAvailable };
  }
  calibrationSnapshot(quota,period,now,sessions) {
    const cacheKey=[this.lastScan,quota?.event_key,period.start,period.kind].join('|');
    if(this.calibrationCache?.key===cacheKey)return this.calibrationCache;
    const rows=this.db.prepare('SELECT thread_id,at_ms,model,effort,tier,scope,input,cached,output,reasoning,total,kind FROM usage WHERE at_ms<=? ORDER BY at_ms').all(now);
    const q=quota||{at_ms:now,scope:'unknown',plan:'unknown'};
    const missingAt=sessions.filter(s=>s.coverage==='metadata').map(s=>s.updated);
    const quotas=this.db.prepare("SELECT * FROM quotas WHERE window_minutes=10080 AND limit_id='codex' AND at_ms>=? AND at_ms<=? ORDER BY at_ms").all(q.at_ms-28*86400000,q.at_ms);
    let report={...calibrationReport(rows,quotas,q,{missingAt}),history_days:28,source:'本机日志',plan_unknown:q.plan==='unknown'};
    if(period.kind!=='quota')report={...report,mode:'pending',reason:'配额快照缺失或已过期',groups:[]};
    const week=rows.filter(r=>r.at_ms>=period.start&&r.at_ms<period.end),eligible=week.filter(r=>r.at_ms<=q.at_ms);
    const byThread=new Map(),threadRows=new Map(),comboRows=new Map(),combinations=new Map();
    for(const r of eligible){
      if(!threadRows.has(r.thread_id))threadRows.set(r.thread_id,[]);threadRows.get(r.thread_id).push(r);
      const key=groupKey(r);if(!comboRows.has(key))comboRows.set(key,[]);comboRows.get(key).push(r);
    }
    for(const [id,records] of threadRows)byThread.set(id,estimateRows(records,report));
    for(const r of rows){
      const key=groupKey(r);
      if(!combinations.has(key))combinations.set(key,{...dimensions(key),total:0,requests:0,week_total:0,week_uncached:0,week_cached:0,week_output:0,week_reasoning:0,week_requests:0});
      const g=combinations.get(key);g.total+=r.total;g.requests++;
      if(r.at_ms>=period.start&&r.at_ms<period.end){g.week_total+=r.total;g.week_uncached+=r.input-r.cached;g.week_cached+=r.cached;g.week_output+=r.output;g.week_reasoning+=r.reasoning;g.week_requests++;}
    }
    for(const g of combinations.values()){
      const estimated=estimateRows(comboRows.get(g.key)||[],report);
      g.quota_estimate=estimated.value;g.calibration_samples=report.support[g.key]||0;
      g.rate=report.groups.find(m=>m.key===g.key)||null;
      g.historical_rate=report.historical?.groups.find(m=>m.key===g.key)||null;
      g.calibration_warning=(report.unresolved_groups.find(m=>m.key===g.key)||report.historical?.unresolved_groups.find(m=>m.key===g.key))?.reason||null;
    }
    const total=estimateRows(eligible,report);
    Object.assign(report,{estimated_quota:total.value,estimated_known_quota:total.known_value,covered_tokens:total.covered_tokens,eligible_tokens:total.total_tokens,
      unexplained_quota:total.value===null?null:q.used_percent-total.value,
      dimension_unknown_tokens:rows.filter(r=>r.model==='unknown'||r.effort==='unknown').reduce((a,r)=>a+r.total,0),
      missing_recent_sessions:missingAt.filter(at=>at>=q.at_ms-28*86400000).length,
      limitations:'配额以整数百分比记录；套餐信息未必提供。其他设备、云端消耗、缺失日志和计费变化仍可能影响估算。'});
    this.calibrationCache={key:cacheKey,report,byThread,combinations:[...combinations.values()].sort((a,b)=>b.week_total-a.week_total||a.key.localeCompare(b.key))};
    fs.writeFileSync(path.join(this.dataDir,'calibration.json'),JSON.stringify(report,null,2));
    return this.calibrationCache;
  }
  historicalCommands(id) {
    // Historical rollout files can be pruned while the paginated history database retains commands.
    let history;
    try {
      const file = path.join(this.home,'thread_history_1.sqlite'); if (!fs.existsSync(file)) return;
      history = new DatabaseSync(file,{ readOnly:true });
      history.exec('PRAGMA query_only=ON; PRAGMA busy_timeout=1000');
      const rows = history.prepare("SELECT turn_id,item_json,started_at_ms,completed_at_ms,created_at_ms FROM thread_items WHERE thread_id=? AND item_type='commandExecution' ORDER BY created_at_ms DESC LIMIT 300").all(id);
      for (const r of rows) { const i=parse(r.item_json);if(i)this.addCommand(id,r.turn_id,i,r.started_at_ms || r.created_at_ms,r.completed_at_ms || r.created_at_ms); }
    } catch (e) { this.warn('历史执行记录读取失败：' + e.message); }
    finally { if (history) history.close(); }
  }
  detail(id) {
    if (!this.sessions.has(id)) return {type:'detail',id,error:'会话不存在'};
    this.historicalCommands(id);
    const snap = this.snapshot();
    return {type:'detail',id,session:snap.sessions.find(s=>s.id===id),
      commands:this.db.prepare('SELECT * FROM commands WHERE thread_id=? ORDER BY start_ms DESC LIMIT 300').all(id),
      models:this.db.prepare('SELECT model,effort,tier,SUM(total) total,SUM(input-cached) uncached,SUM(cached) cached,SUM(output) output,SUM(reasoning) reasoning,COUNT(*) requests FROM usage WHERE thread_id=? GROUP BY model,effort,tier ORDER BY total DESC,model,effort,tier').all(id).map(r=>({...r,key:groupKey(r)})),
      daily:this.db.prepare("SELECT strftime('%Y-%m-%d',at_ms/1000,'unixepoch','+8 hours') day,SUM(total) total FROM usage WHERE thread_id=? GROUP BY day ORDER BY day DESC LIMIT 60").all(id),
      edges:snap.edges.filter(e=>e.parent_id===id||e.child_id===id),
      processes:this.processes.filter(p=>p.thread_id===id)};
  }
  async sampleProcesses() {
    if (process.platform !== 'win32') { this.processError='进程采样仅支持 Windows'; return; }
    if (this.sampling) return;
    if (!this.processSampler) { this.processAt=Date.now();this.processError='未提供进程采样器';return; }
    this.sampling = true;
    try {
      const rows = await new Promise((resolve,reject) => {
        const child=spawn(this.processSampler,['sample-processes'],{windowsHide:true,stdio:['ignore','pipe','pipe']});
        let data='',error='';const timer=setTimeout(()=>{child.kill();reject(new Error('进程采样超时'));},12000);
        child.stdout.on('data',d=>{data+=d;if(data.length>8*1024*1024){child.kill();reject(new Error('进程列表过大'));}});
        child.stderr.on('data',d=>{error+=d;});
        child.on('error',e=>{clearTimeout(timer);reject(e);});
        child.on('close',code=>{clearTimeout(timer);if(code!==0)reject(new Error(error.trim().slice(0,180)||'进程采样失败'));else{try{const value=JSON.parse(data.replace(/^\uFEFF/,''));if(!Array.isArray(value))throw new Error('进程采样格式错误');resolve(value);}catch(e){reject(e);}}});
      });
      this.processes=flattenProcesses(rows,new Set(this.sessions.keys()),process.pid);
      this.processAt=Date.now();this.processError=null;
    } catch(e) {this.processError=e.message;}
    finally {this.sampling=false;}
  }
  close() { this.db.close(); }
}

function refreshSeconds(value) {
  const n=Number(value);
  return (typeof value==='number'||typeof value==='string'&&value.trim()!=='') && Number.isInteger(n) && (n===0 || n>=5 && n<=3600) ? n : 30;
}
class RefreshLoop {
  constructor(run,clock={setTimeout,clearTimeout}) {this.run=run;this.clock=clock;this.seconds=30;this.timer=null;this.running=false;this.stopped=false;}
  configure(value) {this.seconds=refreshSeconds(value);this.schedule();return this.seconds;}
  schedule() {
    if(this.timer!==null)this.clock.clearTimeout(this.timer);
    this.timer=null;
    if(!this.stopped && !this.running && this.seconds>0)this.timer=this.clock.setTimeout(()=>this.refresh(false),this.seconds*1000);
  }
  async refresh(manual=true) {
    if(this.stopped||this.running)return;
    if(this.timer!==null)this.clock.clearTimeout(this.timer);this.timer=null;this.running=true;
    try{await this.run(manual);}finally{this.running=false;this.schedule();}
  }
  stop() {this.stopped=true;if(this.timer!==null)this.clock.clearTimeout(this.timer);this.timer=null;}
}
class CollectorService {
  constructor(collector,send,interval=30,feedOptions={}){
    this.collector=collector;this.send=send;this.stopped=false;
    this.error=error=>{if(!this.stopped)this.send({type:'error',message:error.message});};
    this.queue=new RefreshQueue(async batch=>{
      const started=Date.now();
      for(const ack of batch.acknowledgements)collector.activity.acknowledge(ack.id,ack.turn_id);
      if(batch.full){
        await collector.scan({snapshot:false});if(this.stopped)return;
        send(collector.snapshot());
        // Process enumeration is independent of session delivery, including slow CIM calls.
        if(!collector.sampling&&(batch.manual||Date.now()-collector.processAt>=15000)){
          void collector.sampleProcesses().then(()=>{if(!this.stopped)send({type:'processes',processes:collector.processes,process_at:collector.processAt,process_error:collector.processError});}).catch(this.error);
        }
      }else{
        const message=await collector.scanActivity(batch);if(this.stopped)return;
        message.sync={mode:'local-watch',observed_at:batch.observed_at||started,published_at:Date.now()};send(message);
      }
      if(collector.selected&&(batch.full||batch.detail))send(collector.detail(collector.selected));
    });
    this.loop=new RefreshLoop(manual=>this.queue.request({full:true,manual}).catch(this.error));
    this.loop.seconds=refreshSeconds(interval);
    this.feed=new LocalChangeFeed(collector.home,()=>collector.discoverFiles(),change=>this.queue.request(change),{...feedOptions,onError:this.error});
  }
  async start(){this.feed.configure(this.loop.seconds>0);await this.loop.refresh(true);if(!this.stopped)this.send({type:'ready',app_version:appVersion});}
  configure(value){const seconds=this.loop.configure(value);this.feed.configure(seconds>0);return seconds;}
  refresh(){return this.loop.refresh(true);}
  detail(id){this.collector.selected=id;return this.queue.request({detail:true}).catch(this.error);}
  acknowledge(id,turn_id){return this.queue.request({acknowledge:{id,turn_id}}).catch(this.error);}
  stop(){this.stopped=true;this.feed.stop();this.loop.stop();this.queue.stop();}
}
async function main() {
  const arg = name => { const i=process.argv.indexOf(name);return i>=0?process.argv[i+1]:undefined; };
  const collector=new Collector({home:arg('--home'),dataDir:arg('--data'),processSampler:arg('--process-sampler')});
  if (process.argv.includes('--once')) { await collector.scan(); await collector.sampleProcesses();process.stdout.write(JSON.stringify(collector.snapshot())+'\n');collector.close();return; }
  let closing=false;
  const send=o=>{if(!closing)process.stdout.write(JSON.stringify(o)+'\n');};
  const service=new CollectorService(collector,send,arg('--interval'));
  const shutdown=()=>{if(closing)return;closing=true;service.stop();process.exit(0);};
  const lines=readline.createInterface({input:process.stdin});
  lines.on('line',line=>{
    const request=parse(line,{});
    try {
      if(request.action==='detail')void service.detail(request.id);
      else if(request.action==='refresh')void service.refresh();
      else if(request.action==='configure')send({type:'settings',refresh_seconds:service.configure(request.refresh_seconds)});
      else if(request.action==='acknowledge')void service.acknowledge(request.id,request.turn_id);
      else if(request.action==='stop')shutdown();
    }catch(e){send({type:'error',message:e.message});}
  });
  lines.on('close',shutdown);process.on('SIGTERM',shutdown);process.on('SIGINT',shutdown);
  await service.start();
}
module.exports={Collector,CollectorService,usage,periodFromQuota,normalizedWindows,flattenProcesses,summarizeCommand,weekdayStart,localPath,refreshSeconds,RefreshLoop};
if(require.main===module)main().catch(e=>{process.stderr.write(e.stack+'\n');process.exit(1);});
