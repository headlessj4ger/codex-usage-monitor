'use strict';
const fs=require('node:fs'),path=require('node:path');

// Coalesce changes that arrive during a scan. All SQLite work stays on one queue.
class RefreshQueue {
  constructor(run){this.run=run;this.running=false;this.pending=null;this.stopped=false;}
  request(change={}){
    if(this.stopped)return Promise.resolve();
    if(!this.pending)this.pending={files:new Set(),acknowledgements:[],waiters:[]};
    const pending=this.pending;
    for(const key of ['full','manual','state','history','tick','detail'])pending[key] ||= !!change[key];
    for(const file of change.files||[])pending.files.add(file);
    if(change.acknowledge)pending.acknowledgements.push(change.acknowledge);
    if(change.observed_at)pending.observed_at=Math.min(pending.observed_at||Infinity,change.observed_at);
    const done=new Promise((resolve,reject)=>pending.waiters.push({resolve,reject}));
    void this.drain();return done;
  }
  async drain(){
    if(this.running||this.stopped)return;this.running=true;
    try{while(this.pending&&!this.stopped){const batch=this.pending;this.pending=null;
      try{await this.run(batch);for(const waiter of batch.waiters)waiter.resolve();}
      catch(error){for(const waiter of batch.waiters)waiter.reject(error);}
    }}finally{this.running=false;}
  }
  stop(){this.stopped=true;if(this.pending)for(const waiter of this.pending.waiters)waiter.resolve();this.pending=null;}
}

const databaseKind=name=>/^state_\d+\.sqlite(?:-wal)?$/i.test(name)?'state':/^thread_history_\d+\.sqlite(?:-wal)?$/i.test(name)?'history':null;
class LocalChangeFeed {
  constructor(home,getFiles,onChange,{debounceMs=120,pollMs=1000,watch=fs.watch,onError=()=>{}}={}){
    this.home=path.resolve(home);this.getFiles=getFiles;this.onChange=onChange;this.onError=onError;
    this.debounceMs=debounceMs;this.pollMs=pollMs;this.watch=watch;this.watchers=new Map();this.signatures=new Map();
    this.enabled=false;this.pending=null;this.timer=null;this.pollTimer=null;this.stopped=false;
  }
  configure(enabled){
    if(this.stopped||this.enabled===enabled)return;this.enabled=enabled;
    if(enabled){this.ensureWatchers();this.poll();this.pollTimer=setInterval(()=>this.poll(),this.pollMs);}
    else this.release();
  }
  ensureWatchers(){
    for(const [directory,recursive] of [[this.home,false],[path.join(this.home,'sessions'),true],[path.join(this.home,'archived_sessions'),true]]){
      if(this.watchers.has(directory)||!fs.existsSync(directory))continue;
      try{
        const watcher=this.watch(directory,{recursive},(event,filename)=>{
          if(!this.enabled)return;
          if(!filename){this.poll();return;}
          const file=path.resolve(directory,String(filename)),relative=path.relative(directory,file);
          if(relative.startsWith('..')||path.isAbsolute(relative))return;
          const kind=recursive?null:databaseKind(relative);
          if(kind)this.changed({[kind]:true});
          else if(recursive&&file.endsWith('.jsonl'))this.changed({files:[file]});
          else if(!recursive&&['sessions','archived_sessions'].includes(relative))this.ensureWatchers();
        });
        watcher.on('error',()=>{watcher.close();this.watchers.delete(directory);});
        this.watchers.set(directory,watcher);
      }catch{/* File signatures remain a fallback when native watching is unavailable. */}
    }
  }
  changed(change){
    if(!this.enabled)return;
    if(!this.pending)this.pending={files:new Set(),observed_at:Date.now()};
    for(const key of ['state','history','tick'])this.pending[key] ||= !!change[key];
    for(const file of change.files||[])this.pending.files.add(file);
    // A fixed coalescing window cannot be postponed forever by a busy stream.
    if(this.timer===null)this.timer=setTimeout(()=>{
      this.timer=null;const batch=this.pending;this.pending=null;
      if(batch&&this.enabled)Promise.resolve().then(()=>this.onChange(batch)).catch(this.onError);
    },this.debounceMs);
  }
  poll(){
    if(!this.enabled)return;
    this.ensureWatchers();
    try{
      const files=new Map(this.getFiles().map(file=>[file,'log']));
      for(const name of fs.readdirSync(this.home)){const kind=databaseKind(name);if(kind)files.set(path.join(this.home,name),kind);}
      const changed={files:[],tick:true};
      for(const [file,kind] of files){
        let signature='missing';try{const stat=fs.statSync(file);signature=[stat.ino,stat.size,stat.mtimeMs].join(':');}catch{}
        if(this.signatures.get(file)!==signature){this.signatures.set(file,signature);if(kind==='log')changed.files.push(file);else changed[kind]=true;}
      }
      for(const file of this.signatures.keys())if(!files.has(file)){this.signatures.delete(file);const kind=databaseKind(path.basename(file));if(kind)changed[kind]=true;else changed.files.push(file);}
      this.changed(changed);
    }catch(error){this.onError(error);}
  }
  release(){
    if(this.timer!==null)clearTimeout(this.timer);if(this.pollTimer!==null)clearInterval(this.pollTimer);
    this.timer=null;this.pollTimer=null;this.pending=null;
    for(const watcher of this.watchers.values())watcher.close();this.watchers.clear();
  }
  stop(){this.enabled=false;this.stopped=true;this.release();}
}
module.exports={RefreshQueue,LocalChangeFeed,databaseKind};
