// Deterministic renderer bridge checks; no browser or server access.
const fs = require('node:fs');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const messages = [], timers = new Map(), displays = [];
let timerID = 0, release, rejectLoad, unloaded = 0, finds = 0;
const context = {window:{webkit:{messageHandlers:{reader:{postMessage:m=>messages.push(m)}}}},
 document:{body:{style:{}},documentElement:{dataset:{}},querySelectorAll:()=>[]}, requestAnimationFrame:fn=>fn(), setTimeout:fn=>{timers.set(++timerID,fn); return timerID;}, clearTimeout:id=>timers.delete(id)};
vm.createContext(context);
vm.runInContext(fs.readFileSync('App/Resources/Reader/reader.js','utf8'),context);
const section = {idref:'Chapter',load:()=>new Promise((r,j)=>{release=r;rejectLoad=j;}),find:()=>{finds++;return [{cfi:'one',excerpt:'match'}];},unload:()=>unloaded++};
context.mockBook = {load(){},spine:{spineItems:[section]}};
context.mockRendition = {location:{start:{cfi:'original'}},themes:{default(){}},flow(){},display:async cfi=>displays.push(cfi),views:()=>({displayed:()=>[]})};
vm.runInContext('book=mockBook; rendition=mockRendition; current="original";',context);
context.mockBook.spine.get=target=>({index:target==='one.xhtml'||target==='loc0'||target==='loc1'||target==='loc2'?0:1});
context.mockBook.locations={length:()=>6,cfiFromLocation:index=>`loc${index}`,percentageFromLocation:index=>index/6};
const chapters=vm.runInContext("chapterRanges([{id:'one.xhtml',title:'Chapter 1'},{id:'two.xhtml',title:'Chapter 2: The Return'}])",context);
assert.equal(chapters.length,2);
assert.equal(chapters[0].start,0);
assert.equal(chapters[0].end,0.5);
assert.equal(chapters[1].title,'Chapter 2: The Return');
const excerptText = 'before '.repeat(30) + 'Winston\n  stood beside the window. ' + 'after '.repeat(50);
context.excerptText = excerptText;
const excerpt = vm.runInContext("excerptWindow(excerptText, excerptText.indexOf('Winston'), 7)", context);
assert.ok(excerpt.includes('Winston stood beside the window.'), 'Excerpts normalize paragraph whitespace without indentation');
assert.ok(excerpt.startsWith('… before ') && excerpt.endsWith('after …'), 'Excerpt boundaries preserve whole words');
assert.ok(excerpt.length > 200 && excerpt.length < 340, 'Search provides bounded surrounding context');
const tick = async()=>{ await Promise.resolve(); await Promise.resolve(); };
const fireTimer=()=>{const callback=[...timers.values()].at(-1);timers.clear();return callback();};
(async()=>{
 let turns = 0;
 context.mockRendition.next=async()=>turns++;
 context.mockRendition.prev=async()=>turns--;
 await context.window.readerCommand({name:'gesture',value:{action:'tap',x:10,y:10}});
 assert.equal(messages.filter(m=>m.kind==='toggleControls').length,1);
 await context.window.readerCommand({name:'gesture',value:{action:'next'}});
 assert.equal(turns,1);
 await context.window.readerCommand({name:'gesture',value:{action:'previous'}});
 assert.equal(turns,0);
 const transitions=[];
 context.document.startViewTransition=update=>{
   transitions.push({direction:context.document.documentElement.dataset.pageTurn,style:context.document.documentElement.dataset.pageStyle});
   return {finished:Promise.resolve().then(update)};
 };
 context.window.matchMedia=()=>({matches:false});
 vm.runInContext("pageTransition='slide'",context);
 await context.window.readerCommand({name:'next'});
 assert.equal(turns,1);
 assert.equal(transitions.length,1,'One transition snapshots outgoing and incoming pages');
 assert.equal(transitions[0].direction,'next');
 assert.equal(context.document.documentElement.dataset.pageTurn,undefined,'Transition state is removed after animation');
 vm.runInContext('nativePageTurns=true',context);
 vm.runInContext('ready=true',context);
 assert.equal(context.window.readerCanTurn(30,40),true,'A plain rendered page permits an interactive swipe');
 await context.window.readerCommand({name:'next'});
 assert.equal(turns,2);
 assert.equal(transitions.length,1,'Native mobile turns skip the WebKit page transition');
 assert.equal(messages.at(-1).kind,'turned','Native animation starts only after the next page renders');
 assert.equal(messages.at(-1).direction,'next');
 await context.window.readerCommand({name:'gesture',value:{action:'previous',x:30,y:40}});
 assert.equal(messages.at(-1).kind,'swipe','Native swipe requests the same animated turn as the arrow');
 assert.equal(messages.at(-1).direction,'previous');
 assert.equal(turns,2,'Native swipe does not also turn the page in JavaScript');
 let cleared = 0;
 const touchedFrame=()=>({left:0,top:0,right:100,bottom:100});
 context.document.querySelectorAll=()=>[{getBoundingClientRect:touchedFrame,contentWindow:{getSelection:()=>({toString:()=>"selected",removeAllRanges:()=>cleared++})}}];
 assert.equal(context.window.readerCanTurn(30,40),false,'Interactive swipe does not cover text selection');
 await context.window.readerCommand({name:'gesture',value:{action:'next',x:30,y:40}});
 assert.equal(messages.at(-1).direction,'previous','Selection blocks a native swipe');
 await context.window.readerCommand({name:'gesture',value:{action:'tap',x:30,y:40}});
 assert.equal(cleared,1,'A tap dismisses selected text so controls can be reached again');
 assert.equal(messages.at(-1).direction,'previous','Dismissing selection does not also toggle controls');
 context.document.querySelectorAll=()=>[{contentWindow:{getSelection:()=>({toString:()=>""})},getBoundingClientRect:touchedFrame,contentDocument:{elementFromPoint:()=>({closest:()=>({})})}}];
 assert.equal(context.window.readerCanTurn(30,40),false,'Interactive swipe does not cover links or controls');
 await context.window.readerCommand({name:'gesture',value:{action:'next',x:30,y:40}});
 assert.equal(messages.at(-1).direction,'previous','Interactive chapter content blocks a native swipe');
 context.document.querySelectorAll=()=>[{getBoundingClientRect:()=>({left:200,top:0,right:300,bottom:100}),contentWindow:{getSelection:()=>({toString:()=>"selected"})}}];
 assert.equal(context.window.readerCanTurn(30,40),true,'Offscreen selections cannot block an interactive swipe');
 await context.window.readerCommand({name:'gesture',value:{action:'next',x:30,y:40}});
 assert.equal(messages.at(-1).direction,'next','Selection in an offscreen chapter cannot block a swipe on the current page');
 context.document.querySelectorAll=()=>[];
 context.document.querySelectorAll=()=>[{contentWindow:{getSelection:()=>({removeAllRanges:()=>cleared++})}}];
 await context.window.readerCommand({name:'next'});
 assert.equal(cleared,2,'Completed page turn releases a transient chapter selection');
 await context.window.readerCommand({name:'clearSelection'});
 assert.equal(cleared,3,'Native animation completion can release selection created after relocation');
 context.document.querySelectorAll=()=>[];
 context.window.matchMedia=()=>({matches:true});
 // Tap zones use the whole reader viewport and the native animation route.
 context.document.getElementById=()=>({getBoundingClientRect:()=>({left:20,width:1000})});
 await context.window.readerCommand({name:'gesture',value:{action:'tap',x:50,y:40}});
 assert.equal(messages.at(-1).direction,'previous');
 await context.window.readerCommand({name:'gesture',value:{action:'tap',x:1000,y:40}});
 assert.equal(messages.at(-1).direction,'next');
 assert.equal(turns,3,'Native edge taps request one animation without turning twice');
 const edgeMessageCount=messages.length;
 context.document.querySelectorAll=()=>[{getBoundingClientRect:()=>({left:20,top:0,right:1020,bottom:100}),contentWindow:{getSelection:()=>({toString:()=>"selected",removeAllRanges:()=>cleared++})}}];
 await context.window.readerCommand({name:'gesture',value:{action:'tap',x:1000,y:40}});
 assert.equal(messages.length,edgeMessageCount,'Selection dismissal does not turn or toggle from an edge');
 context.document.querySelectorAll=()=>[{getBoundingClientRect:()=>({left:20,top:0,right:1020,bottom:100}),contentWindow:{getSelection:()=>({toString:()=>""})},contentDocument:{elementFromPoint:()=>({closest:()=>({})})}}];
 await context.window.readerCommand({name:'gesture',value:{action:'tap',x:1000,y:40}});
 assert.equal(messages.length,edgeMessageCount,'An interactive link in an edge zone keeps its original action');
 context.document.querySelectorAll=()=>[];
 for(const x of [220,520,820]) {
   await context.window.readerCommand({name:'gesture',value:{action:'tap',x,y:40}});
   assert.equal(messages.at(-1).kind,'toggleControls','Center and boundaries reveal controls');
 }
 vm.runInContext('scrolling=true',context);
 await context.window.readerCommand({name:'gesture',value:{action:'tap',x:50,y:40}});
 assert.equal(messages.at(-1).kind,'toggleControls','Vertical reading keeps taps for controls');
 vm.runInContext('scrolling=false;pageTapZoneFraction=0.3',context);
 await context.window.readerCommand({name:'gesture',value:{action:'tap',x:270,y:40}});
 assert.equal(messages.at(-1).direction,'previous','Wider edge setting applies immediately');
 vm.runInContext('pageTapZoneFraction=0.2;nativePageTurns=false',context);
 await context.window.readerCommand({name:'gesture',value:{action:'tap',x:50,y:40}});
 assert.equal(turns,2,'Desktop edge tap turns exactly one page');
 await context.window.readerCommand({name:'gesture',value:{action:'tap',x:1000,y:40}});
 assert.equal(turns,3);
 delete context.document.getElementById;
 vm.runInContext('nativePageTurns=false',context);
 context.window.matchMedia=()=>({matches:true});
 await context.window.readerCommand({name:'previous'});
 assert.equal(turns,2);
 assert.equal(transitions.length,1,'Reduce Motion bypasses page animations');
 context.mockBook.locations.percentageFromCfi=()=>0.4;
 context.mockRendition.location={start:{cfi:'chapter-cfi',href:'chapter.xhtml',displayed:{page:3,total:10}}};
 vm.runInContext('reportPosition(mockRendition.location)',context);
 assert.equal(messages.at(-1).chapterPage,3);
 assert.equal(messages.at(-1).chapterPageCount,10);
 assert.equal(messages.at(-1).bookPageCount,0,'No invented total before layout counting completes');
 vm.runInContext("layoutPages = [{sectionIndex:0,localPage:1},{sectionIndex:0,localPage:2},{sectionIndex:0,localPage:3},{sectionIndex:1,localPage:1}]; navigationTitles=new Map([[0,'Chapter 7']])",context);
 context.mockRendition.location.start.index=0;
 vm.runInContext('reportPosition(mockRendition.location)',context);
 assert.equal(messages.at(-1).bookPage,3,'Book page is the actual rendered page, not a character percentage');
 assert.equal(messages.at(-1).bookPageCount,4);
 assert.equal(messages.at(-1).chapterTitle,'Chapter 7','Contents title is independent of spine ordinal');
 vm.runInContext('layoutPages=[]',context);
 context.mockRendition.views=()=>[{section}];
 assert.equal(vm.runInContext('sectionIsDisplayed(mockBook.spine.spineItems[0])',context),true,'Displayed EPUB.js views are an array and must not be unloaded');
 context.mockRendition.views=()=>({displayed:()=>[]});
 const displayBeforeNavigation=context.mockRendition.display;
 const spineGetBeforeNavigation=context.mockBook.spine.get;
 context.mockRendition.display=async target=>{ if(target==='broken.xhtml#heading') throw Error('missing anchor'); displays.push(target); };
 context.mockBook.spine.get=target=>target==='broken.xhtml'?{href:'chapter.xhtml'}:spineGetBeforeNavigation(target);
 const fatalErrorsBeforeNavigation=messages.filter(message=>message.kind==='error').length;
 await context.window.readerCommand({name:'location',value:'broken.xhtml#heading'});
 assert.equal(displays.at(-1),'chapter.xhtml','A broken TOC anchor falls back to the chapter start');
 assert.equal(messages.filter(message=>message.kind==='error').length,fatalErrorsBeforeNavigation,'A TOC fallback is not a fatal reader error');
 vm.runInContext('current="original"',context);
 context.mockRendition.display=async target=>{ if(target==='original') { displays.push(target); return; } throw Error('missing section'); };
 await context.window.readerCommand({name:'location',value:'missing.xhtml#heading'});
 assert.equal(displays.at(-1),'original','A failed TOC jump restores the preceding reading position');
 assert.equal(messages.at(-1).kind,'navigationError','An unrecoverable TOC jump reports a nonfatal navigation error');
 context.mockRendition.display=displayBeforeNavigation;
 context.mockBook.spine.get=spineGetBeforeNavigation;
 displays.length=0;
 context.document.querySelectorAll=()=>[{getBoundingClientRect:touchedFrame,contentWindow:{getSelection:()=>({toString:()=>"selected"})}}];
 await context.window.readerCommand({name:'gesture',value:{action:'next',x:30,y:40}});
 assert.equal(turns,2,'Selection prevents native swipe navigation');
 context.document.querySelectorAll=()=>[];
 let pending = context.window.readerCommand({name:'search',value:{query:'a',id:'obsolete'}});
 await tick();
 await context.window.readerCommand({name:'cancelSearch'});
 release(); await pending;
 assert.equal(messages.filter(m=>m.kind==='results').length,0);
 assert.equal(finds,0,'Cancelled load must not proceed to find');
 assert.equal(unloaded,1,'Search-owned section must be released after cancelled load');
 pending=context.window.readerCommand({name:'search',value:{query:'a',id:'stale-error'}});
 await tick(); await context.window.readerCommand({name:'cancelSearch'});
 rejectLoad(new Error('fixture')); await pending;
 assert.equal(messages.filter(m=>m.kind==='searchError').length,0,'Obsolete errors must not surface');
 section.document={}; section.load=async()=>{};
 await context.window.readerCommand({name:'search',value:{query:'a',id:'live'}});
 assert.equal(unloaded,2,'Preloaded sections must remain loaded');
 assert.equal(messages.filter(m=>m.kind==='results').length,1);
 await context.window.readerCommand({name:'preferences',value:{theme:'light',fontSize:18}});
 await context.window.readerCommand({name:'preferences',value:{theme:'dark',fontSize:22}});
 assert.equal(timers.size,1,'Rapid appearance edits must coalesce');
 vm.runInContext('current="navigated"',context);
 await fireTimer();
 assert.deepEqual(displays,['navigated'],'Capture exact CFI when layout applies, after pending navigation');
 let finishDisplay;
 context.mockRendition.display=cfi=>{displays.push(cfi);return new Promise(r=>finishDisplay=r);};
 const first=vm.runInContext('queueLayout({theme:"light"})',context);
 await tick();
 const second=vm.runInContext('queueLayout({theme:"dark"}); queueLayout(undefined,true)',context);
 assert.equal(displays.length,2,'Overlapping layout must wait');
 assert.equal(vm.runInContext('restoring',context),true);
 finishDisplay(); await tick();
 assert.equal(displays.length,3,'Latest preference and resize applied after first restoration');
 assert.equal(vm.runInContext('restoring',context),true,'Suppression spans queued restoration');
 finishDisplay(); await first; await second;
 assert.equal(vm.runInContext('restoring',context),false);
 context.mockRendition.display=async()=>{throw new Error('fixture');};
 await vm.runInContext('queueLayout({theme:"light"})',context);
 assert.equal(messages.filter(m=>m.kind==='error').length,1,'Asynchronous layout error handled');
 assert.equal(vm.runInContext('restoring',context),false,'Failed layout releases suppression');
 context.mockRendition.location={start:{cfi:'anchor',href:'chapter.xhtml',displayed:{page:2,total:10}}};
 vm.runInContext('nativePageTurns=true',context);
 context.mockRendition.next=async()=>{turns++;context.mockRendition.location.start.cfi='previewed';};
 context.mockRendition.display=async cfi=>{context.mockRendition.location.start.cfi=cfi;};
 const savedPositions=messages.filter(m=>m.kind==='position').length;
 await context.window.readerCommand({name:'previewTurn',value:'next'});
 assert.equal(messages.at(-1).kind,'previewReady','Interactive turn waits for the incoming page');
 assert.equal(context.window.readerCanTurn(30,40),false,'A second swipe cannot interrupt a preview');
 assert.equal(messages.filter(m=>m.kind==='position').length,savedPositions,'Provisional page is not persisted');
 await context.window.readerCommand({name:'cancelTurn'});
 assert.equal(context.mockRendition.location.start.cfi,'anchor','Reversed gesture restores the exact EPUB location');
 assert.equal(messages.at(-1).kind,'turnCancelled','Native card remains until restoration finishes');
 assert.equal(messages.filter(m=>m.kind==='position').length,savedPositions,'Cancelled preview never writes reading progress');
 await context.window.readerCommand({name:'previewTurn',value:'next'});
 assert.equal(messages.filter(m=>m.kind==='position').length,savedPositions,'Second preview also remains unsaved');
 await context.window.readerCommand({name:'commitTurn'});
 assert.equal(messages.at(-1).cfi,'previewed','Only a committed swipe saves the new position');
 const previewDocument={querySelectorAll:()=>[{textContent:'A descriptive opening sentence from the selected chapter, available locally without network access.'}]};
 const previewSection={index:1,document:previewDocument,load:async()=>previewDocument};
 context.mockBook.spine.get=()=>previewSection;
 context.mockBook.locations.cfiFromPercentage=()=> 'loc4';
 await context.window.readerCommand({name:'chapterSnippet',value:{fraction:0.7,number:2}});
 assert.equal(messages.at(-1).kind,'chapterSnippet');
 assert.equal(messages.at(-1).number,2);
 assert.match(messages.at(-1).text,/descriptive opening sentence/);
 // Keyboard focus/blur can emit repeated viewport observations. These must
 // neither repaginate nor redisplay a page-boundary CFI.
 const resized = [];
 const displaysBeforeKeyboard = displays.length;
 const positionBeforeKeyboard = vm.runInContext('current', context);
 context.mockRendition.resize=(width,height)=>resized.push({width,height});
 vm.runInContext('viewportSize={width:375,height:700}', context);
 for (let cycle=0; cycle<5; cycle++) {
   vm.runInContext('resizeViewport({width:375.2,height:700.4}); resizeViewport({width:375,height:700})', context);
 }
 assert.equal(resized.length,0,'Search keyboard open/close at unchanged book dimensions must not resize the rendition');
 assert.equal(displays.length,displaysBeforeKeyboard,'Search open/close must not redisplay a boundary CFI');
 assert.equal(vm.runInContext('current',context),positionBeforeKeyboard,'Search resize notifications preserve the exact reading location');
 // Unlike mouse input, the software keyboard really changes the viewport.
 // Search freezes the hidden EPUB box through all intermediate sizes.
 const readerElement={style:{}};
 context.document.getElementById=()=>readerElement;
 for (let cycle=0;cycle<3;cycle++) {
   await context.window.readerCommand({name:'searchPresentation',value:true});
   assert.equal(readerElement.style.width,'375px');
   assert.equal(readerElement.style.height,'700px');
   vm.runInContext('resizeViewport({width:375,height:410}); resizeViewport({width:375,height:500}); resizeViewport({width:375,height:700})',context);
   assert.equal(resized.length,0,'Keyboard show/hide must not repaginate the hidden EPUB');
   await context.window.readerCommand({name:'cancelSearch'});
   assert.equal(readerElement.style.height,'700px','Cancelling text search does not release the layout before keyboard dismissal');
   await context.window.readerCommand({name:'searchPresentation',value:false});
   assert.equal(readerElement.style.height,'','Keyboard did-hide releases the fixed box');
   vm.runInContext('resizeViewport({width:375,height:700})',context);
 }
 assert.equal(resized.length,0,'Repeated physical-keyboard cycles do not resize');
 assert.equal(displays.length,displaysBeforeKeyboard,'Keyboard cycles do not redisplay');
 assert.equal(vm.runInContext('current',context),positionBeforeKeyboard,'Keyboard cycles preserve exact location');
 vm.runInContext('resizeViewport({width:700,height:375}); resizeViewport({width:700,height:375})',context);
 assert.deepEqual(resized,[{width:700,height:375}],'A real rotation resizes the rendition exactly once');
 assert.equal(displays.length,displaysBeforeKeyboard,'Leave resize location restoration to EPUB.js instead of displaying twice');
 vm.runInContext('resizeViewport({width:0,height:0})',context);
 assert.equal(resized.length,1,'Ignore transient empty layout dimensions');
 // Exercise the production open command, not a separate copy of its options.
 // Both initial modes must retain a manager that can append adjacent chapters.
 for (const initiallyScrolling of [false, true]) {
   const flowMessages = [], flowTimers = new Map(), flows = [], anchors = [];
   let options;
   const location = {start:{cfi:'saved-anchor',href:'chapter.xhtml',displayed:{page:1,total:4}}};
   const renderer = {
     location, themes:{default(){}}, hooks:{content:{register(){}}}, on(){},
     flow:value=>flows.push(value),
     display:async target=>{ if (target) { anchors.push(target); location.start.cfi=target; } },
   };
   const publication = {
     ready:Promise.resolve(), on(){},
     renderTo:(_element,value)=>{ options=value; return renderer; },
     spine:{get:()=>({index:0}),hooks:{content:{register(){}}}},
     locations:{generate:async()=>{},length:()=>0,cfiFromPercentage:()=> 'fraction-anchor',percentageFromCfi:()=>0.25},
     loaded:{navigation:Promise.resolve({toc:[]})},
   };
   const flowContext = {
     window:{webkit:{messageHandlers:{reader:{postMessage:m=>flowMessages.push(m)}}}},
     document:{body:{style:{}},getElementById:()=>({getBoundingClientRect:()=>({width:375,height:700})})},
     ePub:()=>publication,
     ResizeObserver:class {observe(){} disconnect(){}},
     setTimeout:callback=>{flowTimers.set(1,callback);return 1;},clearTimeout:id=>flowTimers.delete(id),
   };
   vm.createContext(flowContext);
   vm.runInContext(fs.readFileSync('App/Resources/Reader/reader.js','utf8'),flowContext);
   await flowContext.window.readerCommand({name:'open',value:{url:'fixture.opf',cfi:'saved-anchor',preferences:{scrolling:initiallyScrolling}}});
   assert.equal(options.manager,'continuous','Opening uses adjacent-chapter rendering in either mode');
   assert.equal(options.flow,initiallyScrolling?'scrolled-continuous':'paginated');
   assert.equal(flows.at(-1),options.flow,'Initial preferences agree with renderer setup');
   assert.equal(flowMessages.at(-1).kind,'ready');
   assert.equal(anchors.at(-1),'saved-anchor','Opening restores the saved exact location');
   for (const scrolling of [!initiallyScrolling, initiallyScrolling]) {
     await flowContext.window.readerCommand({name:'preferences',value:{scrolling}});
     const apply=[...flowTimers.values()].at(-1);flowTimers.clear();await apply();
     assert.equal(flows.at(-1),scrolling?'scrolled-continuous':'paginated','Mode changes retain continuous chapter flow');
     assert.equal(anchors.at(-1),'saved-anchor','Mode changes restore the exact CFI');
     assert.equal(flowMessages.filter(m=>m.kind==='error').length,0);
   }
 }
 console.log('Reader bridge: cancellation, ownership, layout, resize, continuous-flow opening and mode restoration checks passed');
})().catch(e=>{console.error(e);process.exitCode=1});
