// Occluded WebKit must deliver one frame, and cancellation must stop both paths.
const fs=require('node:fs'),vm=require('node:vm'),assert=require('node:assert/strict');
const frames=new Map(),timers=new Map();let frameID=0,timerID=0,calls=0;
const window={requestAnimationFrame:fn=>{frames.set(++frameID,fn);return frameID;},cancelAnimationFrame:id=>frames.delete(id)};
const context={window,performance:{now:()=>80},setTimeout:fn=>{timers.set(++timerID,fn);return timerID;},clearTimeout:id=>timers.delete(id)};
vm.createContext(context);vm.runInContext(fs.readFileSync('App/Resources/Reader/reader-frame.js','utf8'),context);
window.requestAnimationFrame(()=>calls++);const fallback=[...timers.values()][0];[...frames.values()][0](16);fallback();
assert.equal(calls,1);assert.equal(timers.size,0);assert.equal(frames.size,0);
window.requestAnimationFrame(()=>calls++);const native=[...frames.values()][0];[...timers.values()][0]();native(32);
assert.equal(calls,2);assert.equal(frames.size,0);
const canceled=window.requestAnimationFrame(()=>calls++);window.cancelAnimationFrame(canceled);
assert.equal(timers.size,0);assert.equal(frames.size,0);assert.equal(calls,2);
const html=fs.readFileSync('App/Resources/Reader/index.html','utf8');
assert.ok(html.indexOf('reader-frame.js')<html.indexOf('epub.min.js'),'Scheduler is installed before EPUB.js captures it');
console.log('Reader frame: native delivery, occluded fallback, single delivery and cancellation passed');
