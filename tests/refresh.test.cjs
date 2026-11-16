'use strict';
const {test}=require('node:test');const assert=require('node:assert/strict');
const {RefreshLoop,refreshSeconds}=require('../src/collector.cjs');
function fakeClock(){let id=0;const jobs=new Map();return {jobs,setTimeout(fn,ms){jobs.set(++id,{fn,ms});return id;},clearTimeout(key){jobs.delete(key);},async fire(){const [key,job]=jobs.entries().next().value;jobs.delete(key);await job.fn();}};}
test('refresh intervals accept manual and seconds; invalid settings fall back to 30 seconds',()=>{
 for(const n of [0,5,10,30,60,300,3600])assert.equal(refreshSeconds(n),n);
 assert.equal(refreshSeconds('60'),60);
 for(const n of [undefined,null,'',false,[],{},-5,1,4,3.2,Infinity,3601,'broken'])assert.equal(refreshSeconds(n),30);
});
test('changing the interval replaces the timer and manual mode cancels it',async()=>{
 const clock=fakeClock();const calls=[];const loop=new RefreshLoop(async manual=>calls.push(manual),clock);
 loop.configure(10);assert.equal(clock.jobs.size,1);assert.equal([...clock.jobs.values()][0].ms,10000);
 loop.configure(60);assert.equal(clock.jobs.size,1);assert.equal([...clock.jobs.values()][0].ms,60000);
 await clock.fire();assert.deepEqual(calls,[false]);assert.equal(clock.jobs.size,1);
 loop.configure(0);assert.equal(clock.jobs.size,0);await loop.refresh();assert.deepEqual(calls,[false,true]);assert.equal(clock.jobs.size,0);
 loop.stop();
});
test('an in-flight refresh cannot overlap; a changed interval takes effect after it completes',async()=>{
 const clock=fakeClock();let release,calls=0;const loop=new RefreshLoop(()=>{calls++;return new Promise(r=>release=r);},clock);
 loop.configure(5);const first=clock.fire();await loop.refresh();assert.equal(calls,1);
 loop.configure(300);assert.equal(clock.jobs.size,0);release();await first;
 assert.equal(clock.jobs.size,1);assert.equal([...clock.jobs.values()][0].ms,300000);
 const second=clock.fire();loop.configure(0);release();await second;assert.equal(clock.jobs.size,0);
 loop.stop();await loop.refresh();assert.equal(calls,2);
});
