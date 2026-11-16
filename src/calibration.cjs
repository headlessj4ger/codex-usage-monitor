'use strict';
// Empirical quota estimates, never an official conversion from tokens to subscription quota.
const DAY = 86400000;
const UNKNOWN = 'unknown';
const groupKey = r => JSON.stringify([r.model || UNKNOWN, r.effort || UNKNOWN, r.tier || UNKNOWN]);
const dimensions = key => { const [model, effort, tier] = JSON.parse(key); return { key, model, effort, tier }; };
const sum = a => a.reduce((s, v) => s + v, 0);
const dot = (a, b) => a.reduce((s, v, i) => s + v * b[i], 0);
const features = r => [Math.max(0, r.input - r.cached), r.cached, r.output].map(n => n / 1e6);
function upperBound(rows, at) { let lo=0,hi=rows.length;while(lo<hi){const mid=(lo+hi)>>>1;if(rows[mid].at_ms<=at)lo=mid+1;else hi=mid;}return lo; }

function buildObservations(usage, quotas, latest, options = {}) {
  const skipped = { gap:0, backwards:0, unknown:0, missing:0, empty:0, jump:0, invalid:0 };
  const rows = usage.filter(r => r.at_ms <= latest.at_ms && r.at_ms >= latest.at_ms - 28*DAY).sort((a,b)=>a.at_ms-b.at_ms);
  const snapshots = quotas.filter(q => q.scope === latest.scope && q.plan === latest.plan && q.limit_id === 'codex' && q.window_minutes === 10080 && q.at_ms <= latest.at_ms && q.at_ms >= latest.at_ms - 28*DAY).sort((a,b)=>a.at_ms-b.at_ms || a.used_percent-b.used_percent);
  const observations=[];let anchor=null,previous=null;
  for (const q of snapshots) {
    if (!(q.used_percent>=0 && q.used_percent<100 && q.reset_at*1000>q.at_ms && q.reset_at*1000-7*DAY<=q.at_ms+120000)) {skipped.invalid++;anchor=null;previous=null;continue;}
    if (!previous || Math.abs(q.reset_at-previous.reset_at)>120) {anchor=q;previous=q;continue;}
    if (q.at_ms-previous.at_ms>2*3600000 || q.at_ms-anchor.at_ms>12*3600000) {skipped.gap++;anchor=q;previous=q;continue;}
    if (q.used_percent<previous.used_percent) {
      skipped.backwards++;
      // Small out-of-order reports are ignored. A large decrease breaks the block.
      if(previous.used_percent-q.used_percent>1){anchor=q;previous=q;}
      continue;
    }
    previous=q;
    const delta=q.used_percent-anchor.used_percent;
    if(delta<3)continue; // Integer snapshot endpoints alone carry up to ~1 pp rounding error.
    const start=anchor.at_ms,end=q.at_ms;anchor=q;
    if(delta>15){skipped.jump++;continue;}
    const chunk=rows.slice(upperBound(rows,start),upperBound(rows,end));
    if(chunk.some(r => !r.scope || r.scope===UNKNOWN || r.scope===latest.scope && (!r.model || r.model===UNKNOWN || !r.effort || r.effort===UNKNOWN || r.kind!=='response'))){skipped.unknown++;continue;}
    if((options.missingAt||[]).some(at=>at>start&&at<=end)){skipped.missing++;continue;}
    const groups={};let tokenTotal=0;
    for(const r of chunk){
      if(r.scope!==latest.scope)continue;
      const key=groupKey(r),f=features(r);if(!groups[key])groups[key]=[0,0,0];
      for(let j=0;j<3;j++)groups[key][j]+=f[j];tokenTotal+=r.total;
    }
    if(!tokenTotal){skipped.empty++;continue;}
    observations.push({start,end,reset_at:q.reset_at,delta,groups,total:tokenTotal/1e6});
  }
  const currentAnchor=anchor&&Math.abs(anchor.reset_at-latest.reset_at)<=120?anchor:null;
  const accumulating=currentAnchor&&previous?Math.max(0,previous.used_percent-currentAnchor.used_percent):0;
  return { observations, skipped, snapshots:snapshots.length,
    progress:{interval_required_pp:3,interval_accumulated_pp:accumulating,interval_started_at:currentAnchor?.at_ms||0,
      current_cycle_observations:observations.filter(o=>Math.abs(o.reset_at-latest.reset_at)<=120).length} };
}

function independentColumns(x) {
  if(!x.length||!x[0].length)return false;
  const basis=[];
  for(let j=0;j<x[0].length;j++){
    const v=x.map(r=>r[j]);const norm=Math.sqrt(dot(v,v));if(norm<1e-10)return false;
    for(let i=0;i<v.length;i++)v[i]/=norm;
    // Reorthogonalize for numerical stability. Strongly confounded combinations stay pending.
    for(let pass=0;pass<2;pass++)for(const b of basis){const a=dot(v,b);for(let i=0;i<v.length;i++)v[i]-=a*b[i];}
    const residual=Math.sqrt(dot(v,v));if(residual<0.05)return false;
    basis.push(v.map(n=>n/residual));
  }
  return true;
}
function fitNonnegative(x,y) {
  const norms=x[0].map((_,j)=>Math.sqrt(sum(x.map(r=>r[j]*r[j]))));
  const columns=norms.map((norm,j)=>x.map(r=>r[j]/norm));
  const beta=norms.map(()=>0),residual=[...y],ridge=0.0001;
  for(let iteration=0;iteration<4000;iteration++){
    let change=0;
    for(let j=0;j<beta.length;j++){
      const next=Math.max(0,(dot(columns[j],residual)+beta[j])/(1+ridge));
      const delta=next-beta[j];beta[j]=next;change=Math.max(change,Math.abs(delta));
      for(let i=0;i<residual.length;i++)residual[i]-=delta*columns[j][i];
    }
    if(change<1e-8)break;
  }
  return beta.map((v,j)=>v/norms[j]);
}
function matrix(observations,keys,channels) {
  return observations.map(o=>keys.flatMap(key=>channels ? o.groups[key]||[0,0,0] : [sum(o.groups[key]||[0,0,0])]));
}
function score(x,y,beta) {
  const errors=x.map((r,i)=>dot(r,beta)-y[i]);
  return {mae:sum(errors.map(Math.abs))/errors.length,bias:sum(errors),max:Math.max(...errors.map(Math.abs))};
}
function calibrate(observations, latest) {
  const keys=[...new Set(observations.flatMap(o=>Object.keys(o.groups)))].sort();
  const support=Object.fromEntries(keys.map(k=>[k,observations.filter(o=>sum(o.groups[k]||[])>0).length]));
  const base={mode:'pending',reason:'样本不足',observations:observations.length,train:0,holdout:0,groups:[],unresolved_groups:[],as_of:latest?.at_ms||0,scope:latest?.scope||UNKNOWN,plan:latest?.plan||UNKNOWN,channel_model:false,mae:null,baseline_mae:null,validation_bias:null,support,
    requirements:{observations:18,train:12,holdout:5,current_cycle_holdout:3},current_cycle_holdout:0};
  if(!latest || !latest.scope || latest.scope===UNKNOWN)return {...base,reason:'缺少可核对的账户标识'};
  if(observations.length<18)return base;
  const holdoutCount=Math.max(5,Math.ceil(observations.length*0.25));
  const trainingPool=observations.slice(0,-holdoutCount),validationPool=observations.slice(-holdoutCount);
  // Sparse/new combinations do not block well-observed ones. Exclude entire mixed blocks;
  // never assign their quota to a better-observed group. Eligibility uses TRAINING inputs only.
  let fittedKeys=[...keys],train=trainingPool,changed=true;
  while(changed){
    const keep=fittedKeys.filter(k=>train.filter(o=>sum(o.groups[k]||[])>0).length>=4);
    changed=keep.length!==fittedKeys.length;fittedKeys=keep;const allowed=new Set(keep);
    train=trainingPool.filter(o=>Object.keys(o.groups).every(k=>allowed.has(k)));
  }
  const allowed=new Set(fittedKeys),holdout=validationPool.filter(o=>Object.keys(o.groups).every(k=>allowed.has(k)));
  const eligible=[...train,...holdout];
  Object.assign(base,{train:train.length,holdout:holdout.length,excluded_sparse:observations.length-eligible.length,candidate_groups:fittedKeys.length});
  base.requirements.train=Math.max(12,fittedKeys.length*3);
  base.current_cycle_holdout=holdout.filter(o=>Math.abs(o.reset_at-latest.reset_at)<=120).length;
  if(!fittedKeys.length || train.length<Math.max(12,fittedKeys.length*3))return {...base,reason:'组合较多，需要更多独立用量区间'};
  if(holdout.length<5)return {...base,reason:'近期可验证的组合样本不足'};
  if(base.current_cycle_holdout<3)return {...base,reason:'当前配额周期还需要验证样本'};
  let channels=false,x=matrix(train,fittedKeys,false);
  if(!independentColumns(x))return {...base,reason:'组合经常同时使用，暂时无法分离系数'};
  if(train.length>=fittedKeys.length*18){const separate=matrix(train,fittedKeys,true);if(independentColumns(separate)){channels=true;x=separate;}}
  const y=train.map(o=>o.delta),testY=holdout.map(o=>o.delta),testX=matrix(holdout,fittedKeys,channels);
  const beta=fitNonnegative(x,y),measured=score(testX,testY,beta);
  const baselineX=train.map(o=>[o.total]),baseline=fitNonnegative(baselineX,y);
  const baselineScore=score(holdout.map(o=>[o.total]),testY,baseline);
  Object.assign(base,{channel_model:channels,mae:measured.mae,baseline_mae:baselineScore.mae,validation_bias:measured.bias,validation_start:holdout[0].start});
  if(measured.mae>1.25 || Math.abs(measured.bias)>Math.max(1.5,sum(testY)*0.20))return {...base,reason:'近期验证误差较大，继续积累样本'};
  if(!(measured.mae<=baselineScore.mae*0.90 && baselineScore.mae-measured.mae>=0.15))return {...base,reason:'暂未证实优于统一 token 换算'};
  // Validation is performed BEFORE refitting all observations, never on the fitted data.
  const full=fitNonnegative(matrix(eligible,fittedKeys,channels),eligible.map(o=>o.delta));
  const candidates=fittedKeys.map((key,j)=>({...dimensions(key),samples:eligible.filter(o=>sum(o.groups[key]||[])>0).length,rates:channels?full.slice(j*3,j*3+3):[full[j]],channel_model:channels,
    boundary:!(channels?full.slice(j*3,j*3+3).some(n=>n>1e-8)&&beta.slice(j*3,j*3+3).some(n=>n>1e-8):full[j]>1e-8&&beta[j]>1e-8)}));
  // A nonnegative fit at zero is not evidence that a model is free. Retain it as
  // an unresolved attribution, never publish a zero quota estimate for that group.
  const groups=candidates.filter(g=>!g.boundary),unresolved_groups=candidates.filter(g=>g.boundary).map(g=>({...g,reason:'系数落在零边界，暂时无法可靠分离'}));
  return {...base,mode:groups.length?'learned':'pending',reason:groups.length?(groups.length<keys.length?'部分组合已通过时间留出验证':'已通过时间留出验证'):'组合系数暂时无法可靠分离',groups,unresolved_groups};
}
function calibrationReport(usage,quotas,latest,options={}) {
  const blocks=buildObservations(usage,quotas,latest,options);
  const result={...calibrate(blocks.observations,latest),progress:blocks.progress,skipped:blocks.skipped,snapshot_count:blocks.snapshots,historical:null};
  // Reconstruct a prior result from the stored observations. Historical rates are
  // displayed as historical only; they never feed estimates in the new cycle.
  if(result.mode!=='learned'&&latest.scope&&latest.scope!==UNKNOWN){
    const previous=quotas.filter(q=>q.limit_id==='codex'&&q.window_minutes===10080&&q.scope===latest.scope&&q.plan===latest.plan&&q.at_ms<latest.at_ms&&q.at_ms>=latest.at_ms-28*DAY&&q.reset_at<latest.reset_at-120).sort((a,b)=>b.at_ms-a.at_ms)[0];
    if(previous){const oldBlocks=buildObservations(usage,quotas,previous,options),old=calibrate(oldBlocks.observations,previous);
      if(old.mode==='learned')result.historical={as_of:old.as_of,reset_at:previous.reset_at,mae:old.mae,baseline_mae:old.baseline_mae,groups:old.groups,unresolved_groups:old.unresolved_groups,reason:old.reason};}
  }
  return result;
}
function estimateRows(rows, calibration) {
  const rates=new Map(calibration.groups.map(g=>[g.key,g]));
  let value=0,covered=0,total=0;
  for(const r of rows){
    total+=r.total;
    const g=r.scope===calibration.scope && rates.get(groupKey(r));
    if(calibration.mode!=='learned'||!g||!g.rates.some(n=>Number.isFinite(n)&&n>1e-8))continue;
    value+=g.channel_model?dot(features(r),g.rates):r.total/1e6*g.rates[0];covered+=r.total;
  }
  return {value:calibration.mode==='learned'&&total>0&&covered===total?value:null,known_value:calibration.mode==='learned'?value:null,covered_tokens:covered,total_tokens:total};
}
module.exports={groupKey,dimensions,features,buildObservations,independentColumns,fitNonnegative,calibrate,calibrationReport,estimateRows};
