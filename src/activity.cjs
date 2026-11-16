'use strict';
// Local presentation state. Codex databases and read receipts are never modified.
class ActivityTracker {
  constructor(saved={}) { this.entries=saved&&typeof saved==='object'?saved:{}; }
  acknowledge(id,turn) {
    const entry=this.entries[id];
    if(!entry||entry.turn_id!==turn)return false;
    entry.acknowledged=true;return true;
  }
  update(rows,receipts={},now=Date.now()) {
    const visible=[];
    for(const row of rows){
      if(['guardian','guardian_review'].includes(row.source))continue;
      let entry=this.entries[row.id];
      if(!entry||entry.turn_id!==row.turn_id){entry={turn_id:row.turn_id,observed_open:false,terminal_at:0,acknowledged:false};this.entries[row.id]=entry;}
      const receipt=receipts[row.id];
      if(row.is_open){entry.observed_open=true;entry.acknowledged=false;entry.terminal_at=0;}
      else if(!entry.terminal_at)entry.terminal_at=now;
      const seenRead=receipt&&receipt.first_unread_turn==null;
      // A completed row gets a perceptible checkmark before the client's read receipt retires it.
      if(!row.is_open&&seenRead&&now-entry.terminal_at>=4000)entry.acknowledged=true;
      const unread=receipt&&receipt.first_unread_turn!=null;
      const recentUnread=unread&&row.ended_ms>0&&now-row.ended_ms<=15*60000;
      const show=row.requires_input || (row.is_open&&!row.long_stale&&row.state!=='quiet') || (!row.is_open&&!entry.acknowledged&&(entry.observed_open||entry.notified||recentUnread));
      if(show&&!row.is_open)entry.notified=true;
      const display=row.requires_input?'waiting':row.state==='running'&&!(row.turn?.responses>0)&&now-row.started_ms<15000?'starting':row.state;
      if(show)visible.push({...row,display_state:display,mini_visible:true,receipt_supported:!!receipt});
    }
    return visible;
  }
  retainedIds(){return new Set(Object.entries(this.entries).filter(([,v])=>(v.observed_open||v.notified)&&!v.acknowledged).map(([id])=>id));}
}
module.exports={ActivityTracker};
