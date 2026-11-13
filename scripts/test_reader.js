// Deterministic renderer bridge checks; no browser or server access.
const fs = require('node:fs');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const messages = [], timers = new Map(), displays = [];
let timerID = 0, release, rejectLoad, unloaded = 0, finds = 0;
const context = {window:{webkit:{messageHandlers:{reader:{postMessage:m=>messages.push(m)}}}},
 document:{body:{style:{}},documentElement:{dataset:{},style:{setProperty(){}}},querySelectorAll:()=>[]}, requestAnimationFrame:fn=>fn(), setInterval:()=>1, clearInterval:()=>{}, setTimeout:fn=>{timers.set(++timerID,fn); return timerID;}, clearTimeout:id=>timers.delete(id)};
vm.createContext(context);
vm.runInContext(fs.readFileSync('App/Resources/Reader/reader.js','utf8'),context);
// A preview that has not moved is not necessarily an end-of-book boundary.
const spine = [{index:0,linear:true},{index:1,linear:true}];
const location = (index,page,total) => ({start:{index,displayed:{page,total}},end:{index,displayed:{page,total}}});
assert.equal(context.snapshotIsBookBoundary(location(0,9,9),'next',spine),false,'End of an interior spine is not the end of the book');
assert.equal(context.snapshotIsBookBoundary(location(1,1,9),'previous',spine),false,'Beginning of a later spine is not the start of the book');
assert.equal(context.snapshotIsBookBoundary(location(1,9,9),'next',spine),true,'Last page of last linear spine is a boundary');
assert.equal(context.snapshotIsBookBoundary(location(0,1,9),'previous',spine),true,'First page of first linear spine is a boundary');
assert.equal(context.snapshotIsBookBoundary(location(1,8,9),'next',spine),false,'Unchanged interior preview remains unknown');
assert.equal(context.snapshotIsBookBoundary({start:{index:0},end:{index:0}},'previous',spine),false,'Missing pagination cannot prove a boundary');
// Sandboxed chapter scripts cannot be trusted to deliver selection callbacks.
// The parent inspects a visible frame and emits changes without duplicate writes.
const selectionMessages = [];
const selectionState = {rangeCount:1,isCollapsed:false,toString:()=> 'selected text',getRangeAt:()=>({})};
const selectedDocument = {};
const selectedContents = {document:selectedDocument,window:{getSelection:()=>selectionState},cfiFromRange:()=> 'epubcfi(/6/2!/4/2,/1:0,/1:4)'};
const selectedFrame = {contentDocument:selectedDocument,getBoundingClientRect:()=>({left:0,right:300,top:0,bottom:600})};
context.document.querySelectorAll = () => [selectedFrame];
context.window.webkit.messageHandlers.reader.postMessage = message => selectionMessages.push(message);
context.pollRendition = {getContents:()=>[selectedContents]};
vm.runInContext('ready=true; viewportSize={width:300,height:600}; rendition=pollRendition; current="page"; pollSelection(); pollSelection()',context);
assert.deepEqual(selectionMessages.map(message=>message.kind),['selection','selectedText']);
assert.equal(selectionMessages.at(-1).context,'selected text','Unavailable surrounding context retains the selected excerpt');
assert.equal(selectionMessages.filter(message=>message.kind==='highlighterSelectionCommitted').length,0,'Observation alone cannot save a tool highlight');
const toolRequest='1D3A408B-7840-44E8-A1C6-E90020209001';
context.window.readerCommand({name:'commitHighlightSelection',value:{request:toolRequest}});
assert.equal(selectionMessages.at(-1).kind,'highlighterSelectionCommitted','Only explicit completed gestures commit tool selection');
assert.equal(selectionMessages.at(-1).request,toolRequest,'Tool commit retains mode generation for native validation');
assert.equal(selectionMessages.at(-1).context,'selected text','A tool commit retains observed context');

selectionState.isCollapsed = true;
vm.runInContext('pollSelection()',context);
assert.equal(selectionMessages.at(-1).active,false);
context.document.querySelectorAll = () => [];
context.window.webkit.messageHandlers.reader.postMessage = message => messages.push(message);
vm.runInContext('ready=false; lastPolledSelection=""',context);
const section = {idref:'Chapter',load:()=>new Promise((r,j)=>{release=r;rejectLoad=j;}),find:()=>{finds++;return [{cfi:'one',excerpt:'match'}];},unload:()=>unloaded++};
context.mockBook = {load(){},spine:{spineItems:[section]}};
context.mockRendition = {location:{start:{cfi:'original'}},themes:{registerCss(){}},flow(){},display:async cfi=>displays.push(cfi),views:()=>({displayed:()=>[]})};
vm.runInContext('book=mockBook; rendition=mockRendition; current="original";',context);
const themeCSS=[];
context.mockRendition.themes.registerCss=(name,css)=>themeCSS.push(css);
vm.runInContext("setReaderTheme(mockRendition,{theme:'dark',font:'Georgia',fontSize:20,lineHeight:1.6,margin:24})",context);
assert.match(themeCSS.at(-1), /font-family:Georgia/);
assert.match(themeCSS.at(-1), /p,li,blockquote/,'Reader style normalizes publisher prose while retaining semantic elements');
vm.runInContext("setReaderTheme(mockRendition,{theme:'dark',originalFormatting:true})",context);
assert.doesNotMatch(themeCSS.at(-1), /font-family|font-size|line-height|padding/);
assert.match(themeCSS.at(-1), /background:#171717/);
context.mockRendition.book={package:{metadata:{layout:'pre-paginated'}}};
vm.runInContext("setReaderTheme(mockRendition,{theme:'dark',font:'Georgia'})",context);
assert.doesNotMatch(themeCSS.at(-1), /font-family|font-size|background/);
delete context.mockRendition.book;
context.mockBook.spine.get=target=>({index:target==='one.xhtml'||target==='loc0'||target==='loc1'||target==='loc2'?0:1});
context.mockBook.locations={length:()=>6,cfiFromLocation:index=>`loc${index}`,percentageFromLocation:index=>index/6};
vm.runInContext("publicationTitle='A Book Title';navigationTitles=new Map();",context);
assert.equal(vm.runInContext('chapterTitleFor(0)',context),'A Book Title','A missing chapter title falls back to the publication title');
vm.runInContext("navigationTitles=new Map([[0,'A Long Chapter Title']]);",context);
assert.equal(vm.runInContext('chapterTitleFor(0)',context),'A Long Chapter Title','A supplied chapter title remains authoritative');
vm.runInContext("publicationTitle='';navigationTitles=new Map();",context);
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
 const marks=[];
 context.mockRendition.annotations={highlight:(cfi)=>marks.push(['add',cfi]),remove:(cfi,type)=>marks.push(['remove',cfi,type])};
 const cfi='epubcfi(/6/2!/4/2,/1:0,/1:4)';
 await context.window.readerCommand({name:'savedHighlights',value:[cfi,cfi,'not-a-cfi']});
 assert.deepEqual(marks,[['add',cfi]],'Only valid unique saved anchors are rendered');
 assert.equal(messages.at(-1).kind,'highlightsUpdated','Adding a highlight notifies native preview caches');
 await context.window.readerCommand({name:'location',value:cfi});
 assert.deepEqual(marks,[['add',cfi]],'Search cannot replace a saved highlight at the same CFI');
 await context.window.readerCommand({name:'savedHighlights',value:[]});
 assert.deepEqual(marks.at(-1),['remove',cfi,'highlight'],'Removing a saved highlight clears the overlay');
 assert.equal(messages.at(-1).kind,'highlightsUpdated','Removing a highlight notifies native preview caches');
 const noteID='1D3A408B-7840-44E8-A1C6-E90020209001';
 context.mockRendition.annotations.underline=(cfi,data,callback,cls,style)=>marks.push(['underline',cfi,style.stroke]);
 await context.window.readerCommand({name:'savedHighlights',value:[{id:noteID,cfi,color:'green',style:'underline',hasNote:true}]});
 assert.deepEqual(marks.at(-1),['underline',cfi,'#65b879'],'Saved underline uses its chosen color');
 await context.window.readerCommand({name:'savedHighlights',value:[{id:noteID,cfi,color:'pink',style:'highlight',hasNote:false}]});
 assert.deepEqual(marks.at(-2),['remove',cfi,'underline'],'Changing annotation style removes the old overlay type');
 await context.window.readerCommand({name:'savedHighlights',value:[]});

 marks.length=0;
 await context.window.readerCommand({name:'location',value:cfi});
 await context.window.readerCommand({name:'location',value:cfi});
 assert.deepEqual(marks,[['add',cfi]],'Repeated search jumps reuse the transient overlay');
 await context.window.readerCommand({name:'savedHighlights',value:[cfi]});
 assert.deepEqual(marks,[['add',cfi],['remove',cfi,'highlight'],['add',cfi]],'Saving a searched passage replaces its transient overlay first');
 await context.window.readerCommand({name:'savedHighlights',value:[]});
 marks.length=0;
 await context.window.readerCommand({name:'annotationLocation',value:'bad'});
 assert.equal(messages.at(-1).kind,'navigationError','Invalid annotation anchor reports failure');
 const originalSnapshot=context.renderSnapshot, snapshotJobs=[];
 let releaseSnapshot;
 context.renderSnapshot=value=>{
   snapshotJobs.push(value.request);
   return value.request==='busy' ? new Promise(resolve=>{releaseSnapshot=resolve;}) : Promise.resolve();
 };
 const busy=context.window.readerCommand({name:'snapshot',value:{request:'busy'}});
 const obsolete=context.window.readerCommand({name:'snapshot',value:{request:'obsolete'}});
 const newest=context.window.readerCommand({name:'snapshot',value:{request:'newest'}});
 assert.deepEqual(snapshotJobs,['busy'],'Only one auxiliary render is active');
 await obsolete;
 releaseSnapshot();await Promise.all([busy,newest]);
 assert.deepEqual(snapshotJobs,['busy','newest'],'Only latest waiting preview runs; obsolete work is discarded');
 context.renderSnapshot=originalSnapshot;
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
   const updateCallbackDone=Promise.resolve().then(update);
   return {updateCallbackDone,finished:updateCallbackDone,skipTransition(){}};
 };
 context.window.matchMedia=()=>({matches:false});
 vm.runInContext("pageTransition='slide'",context);
 await context.window.readerCommand({name:'next'});
 assert.equal(turns,1);
 assert.equal(transitions.length,1,'One transition snapshots outgoing and incoming pages');
 assert.equal(transitions[0].direction,'next');
 await tick();
 assert.equal(context.document.documentElement.dataset.pageTurn,undefined,'Transition state is removed after animation');
 vm.runInContext('nativePageTurns=true',context);
 vm.runInContext('ready=true',context);
 assert.equal(context.window.readerCanTurn(30,40),true,'A plain rendered page permits an interactive swipe');
 await context.window.readerCommand({name:'next'});
 assert.equal(turns,2);
 assert.equal(transitions.length,1,'Native mobile turns skip the WebKit page transition');
 assert.equal(messages.at(-1).kind,'turned','Native animation starts only after the next page renders');
 assert.equal(messages.at(-1).direction,'next');
 const ordered=[];
 let releaseTurn;
 context.mockRendition.next=()=>new Promise(resolve=>{releaseTurn=()=>{turns++;ordered.push('next');resolve();};});
 const rapidA=context.window.readerCommand({name:'nativeTurn',value:{direction:'next',request:'rapid-a'}});
 const rapidB=context.window.readerCommand({name:'nativeTurn',value:{direction:'previous',request:'rapid-b'}});
 await tick();await tick();
 assert.deepEqual(ordered,[],'Second input waits for rendering, not native decoration');
 const rapidSwipeCount=messages.filter(message=>message.kind==='swipe').length;
 const inFrame=()=>({left:0,top:0,right:100,bottom:100});
 context.document.querySelectorAll=()=>[{getBoundingClientRect:inFrame,contentWindow:{getSelection:()=>({toString:()=>"selected"})}}];
 await context.window.readerCommand({name:'gesture',value:{action:'next',x:30,y:40,queue:true}});
 assert.equal(messages.filter(message=>message.kind==='swipe').length,rapidSwipeCount,'A rapid follow-up cannot turn through an active selection');
 context.document.querySelectorAll=()=>[{getBoundingClientRect:inFrame,contentWindow:{getSelection:()=>({toString:()=>""})},contentDocument:{elementFromPoint:()=>({closest:()=>({})})}}];
 await context.window.readerCommand({name:'gesture',value:{action:'next',x:30,y:40,queue:true}});
 assert.equal(messages.filter(message=>message.kind==='swipe').length,rapidSwipeCount,'A rapid follow-up cannot turn through a link');
 context.document.querySelectorAll=()=>[];
 await context.window.readerCommand({name:'gesture',value:{action:'next',x:30,y:40,queue:true,queueRequest:'epoch-a'}});
 assert.equal(messages.filter(message=>message.kind==='swipe').length,rapidSwipeCount+1,'An ordinary rapid follow-up is delivered for native queueing');
 assert.equal(messages.at(-1).queue,true,'The native coordinator must queue the accepted follow-up even if the preceding turn finishes before delivery');
 assert.equal(messages.at(-1).queueRequest,'epoch-a','The native coordinator can reject a reply after its gesture epoch is invalidated');
 releaseTurn();await Promise.all([rapidA,rapidB]);
 assert.deepEqual(messages.filter(m=>m.request==='rapid-a'||m.request==='rapid-b').map(m=>m.request),['rapid-a','rapid-b'],'Rapid requests are acknowledged in order with their own identity');
 assert.equal(turns,2,'Rapid forward then backward inputs both execute');
 assert.equal(transitions.length,1,'Rapid native input does not wait for a browser animation');
 context.mockRendition.next=async()=>turns++;
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
 context.document.getElementById=()=>({getBoundingClientRect:()=>({left:20,top:0,width:1000,height:700})});
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
 context.mockRendition.location.start.index=1;
 vm.runInContext('reportPosition(mockRendition.location)',context);
 assert.equal(messages.at(-1).chapterTitle,'Chapter 7','Unnamed sections retain the preceding named chapter');
 vm.runInContext("navigationTitles=new Map([[2,'Chapter 8']])",context);
 vm.runInContext('reportPosition(mockRendition.location)',context);
 assert.equal(messages.at(-1).chapterTitle,'','Do not fabricate a chapter title before the first named section');
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
 const firstPreviewTimer = [...timers.keys()][0];
 await context.window.readerCommand({name:'preferences',value:{theme:'dark',fontSize:22}});
 assert.equal([...timers.keys()][0],firstPreviewTimer,'Sustained slider edits must not postpone live preview');
 assert.equal(timers.size,1,'Rapid appearance edits must coalesce');
 vm.runInContext('current="navigated"',context);
 await fireTimer(); await vm.runInContext('layoutTask',context);
 assert.deepEqual(displays,['navigated'],'Capture exact CFI when layout applies, after pending navigation');
 let finishDisplay;
 context.mockRendition.display=cfi=>{displays.push(cfi);return new Promise(r=>finishDisplay=r);};
 const first=vm.runInContext('queueLayout({theme:"light",fontSize:24})',context);
 await tick();
 const second=vm.runInContext('queueLayout({theme:"dark",fontSize:26}); queueLayout(undefined,true)',context);
 assert.equal(displays.length,2,'Overlapping layout must wait');
 assert.equal(vm.runInContext('restoring',context),true);
 finishDisplay(); await tick(); await tick(); await tick();
 assert.equal(displays.length,3,'Latest preference and resize applied after first restoration');
 assert.equal(vm.runInContext('restoring',context),true,'Suppression spans queued restoration');
 finishDisplay(); await first; await second;
 assert.equal(vm.runInContext('restoring',context),false);
 context.mockRendition.display=async()=>{throw new Error('fixture');};
 await vm.runInContext('queueLayout({theme:"light",fontSize:28})',context);
 assert.equal(messages.filter(m=>m.kind==='error').length,1,'Asynchronous layout error handled');
 assert.equal(vm.runInContext('restoring',context),false,'Failed layout releases suppression');
 context.mockRendition.location={start:{cfi:'anchor',href:'chapter.xhtml',displayed:{page:2,total:10}}};
 vm.runInContext('nativePageTurns=false',context);
 context.mockRendition.next=async()=>{turns++;context.mockRendition.location.start.cfi='previewed';};
 context.mockRendition.display=async cfi=>{context.mockRendition.location.start.cfi=cfi;};
 const savedPositions=messages.filter(m=>m.kind==='position').length;
 await context.window.readerCommand({name:'previewTurn',value:'next'});
 assert.equal(messages.at(-1).kind,'previewReady','Mac provisional turn reports after the incoming page without a decorative transition');
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
 const chromeHeader={style:{}}, chromeFooter={style:{}};
 context.document.getElementById=id=>id==='reader'?readerElement:id==='page-chapter'?chromeHeader:chromeFooter;
 vm.runInContext('setPageChrome({enabled:true,top:52,bottom:60,showChapter:true,showProgress:true})', context);
 for (let cycle=0;cycle<3;cycle++) {
   await context.window.readerCommand({name:'searchPresentation',value:true});
   assert.equal(readerElement.style.width,'375px');
   assert.equal(readerElement.style.height,'700px');
   vm.runInContext('resizeViewport({width:375,height:410}); resizeViewport({width:375,height:500}); resizeViewport({width:375,height:700})',context);
   assert.equal(resized.length,0,'Keyboard show/hide must not repaginate the hidden EPUB');
   await context.window.readerCommand({name:'cancelSearch'});
   assert.equal(readerElement.style.height,'700px','Cancelling text search does not release the layout before keyboard dismissal');
   await context.window.readerCommand({name:'searchPresentation',value:false});
   assert.equal(readerElement.style.height,'calc(100% - 112px)','Closing search restores chapter and progress insets');
   assert.equal(messages.at(-1).kind,'readerRevealed','Search dismissal explicitly rewarms native page-turn previews after layout and paint');
   vm.runInContext('resizeViewport({width:375,height:700})',context);
 }
 assert.equal(resized.length,0,'Repeated physical-keyboard cycles do not resize');
 assert.equal(displays.length,displaysBeforeKeyboard,'Keyboard cycles do not redisplay');
 assert.equal(vm.runInContext('current',context),positionBeforeKeyboard,'Keyboard cycles preserve exact location');
 vm.runInContext('resizeViewport({width:680,height:390}); resizeViewport({width:700,height:375}); resizeViewport({width:700,height:375})',context);
 await vm.runInContext('layoutTask',context);
 assert.deepEqual(resized,[{width:700,height:375}],'A real rotation resizes the rendition exactly once');
 assert.equal(displays.length,displaysBeforeKeyboard,'Leave resize location restoration to EPUB.js instead of displaying twice');
 vm.runInContext('resizeViewport({width:0,height:0})',context);
 assert.equal(resized.length,1,'Ignore transient empty layout dimensions');
 // Exercise the production open command, not a separate copy of its options.
 // Both initial modes must retain a manager that can append adjacent chapters.
 for (const initiallyScrolling of [false, true]) {
   const flowMessages = [], flowTimers = new Map(), flows = [], anchors = [];
   let options; const handlers={};
   const location = {start:{cfi:'saved-anchor',href:'chapter.xhtml',displayed:{page:1,total:4}}};
   const renderer = {
     location, themes:{registerCss(){}}, hooks:{content:{register(){}}}, on:(event,callback)=>{handlers[event]=callback;},
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
     document:{documentElement:{dataset:{},style:{setProperty(){}}},body:{style:{}},getElementById:()=>({style:{},getBoundingClientRect:()=>({left:0,top:0,width:375,height:700})})},
     ePub:()=>publication,
     ResizeObserver:class {observe(){} disconnect(){}},
     setTimeout:callback=>{flowTimers.set(1,callback);return 1;},clearTimeout:id=>flowTimers.delete(id),setInterval:()=>1,clearInterval:()=>{},
   };
   vm.createContext(flowContext);
   vm.runInContext(fs.readFileSync('App/Resources/Reader/reader.js','utf8'),flowContext);
   await flowContext.window.readerCommand({name:'open',value:{url:'fixture.opf',cfi:'saved-anchor',preferences:{scrolling:initiallyScrolling}}});
   assert.equal(options.manager,'continuous','Opening uses adjacent-chapter rendering in either mode');
   assert.equal(options.flow,initiallyScrolling?'scrolled-continuous':'paginated');
   assert.equal(flows.length,0,'Initial setup does not clear the already configured rendition');
   assert.equal(flowMessages.at(-1).kind,'ready');
   assert.equal(anchors.at(-1),'saved-anchor','Opening restores the saved exact location');
   handlers.selected('epubcfi(/6/2!/4/2,/1:0,/1:4)', {window:{getSelection:()=>({toString:()=>'<quoted> & text'})}});
   assert.equal(flowMessages.at(-1).kind,'selectedText');
   assert.equal(flowMessages.at(-1).text,'<quoted> & text','Selection is plain message data');
   assert.equal(flowMessages.at(-2).kind,'selection');
   assert.equal(flowMessages.at(-2).active,true,'A selected range enables selection actions');
   flowContext.document.querySelectorAll=()=>[];
   await flowContext.window.readerCommand({name:'clearSelection'});
   assert.equal(flowMessages.at(-1).kind,'selection');
   assert.equal(flowMessages.at(-1).active,false,'Clearing selection disables selection actions');
   const messageCount=flowMessages.length;
   handlers.selected('invalid', {window:{getSelection:()=>({toString:()=> 'text'})}});
   assert.equal(flowMessages.length,messageCount,'Invalid selection anchor is ignored');
   for (const scrolling of [!initiallyScrolling, initiallyScrolling]) {
     await flowContext.window.readerCommand({name:'preferences',value:{scrolling}});
     const apply=[...flowTimers.values()].at(-1);flowTimers.clear();await apply();await vm.runInContext("layoutTask",flowContext);
     assert.equal(flows.at(-1),scrolling?'scrolled-continuous':'paginated','Mode changes retain continuous chapter flow');
     assert.equal(anchors.at(-1),'saved-anchor','Mode changes restore the exact CFI');
     assert.equal(flowMessages.filter(m=>m.kind==='error').length,0);
   }
 }
 // Inspector reflow must wait for an in-flight turn, and the next turn must
 // wait for EPUB.js's resize redisplay queue instead of touching cleared views.
 const orderContext={window:{webkit:{messageHandlers:{reader:{postMessage(){}}}}},
 document:{documentElement:{dataset:{},style:{setProperty(){}}}},setTimeout:()=>1,clearTimeout(){}};
 vm.createContext(orderContext);
 vm.runInContext(fs.readFileSync('App/Resources/Reader/reader.js','utf8'),orderContext);
 const operations=[]; let finishTurn,finishResize;
 orderContext.mock={location:{start:{cfi:'saved'}},
 next:()=>{operations.push('turn');return operations.filter(x=>x==='turn').length===1?new Promise(r=>finishTurn=r):Promise.resolve();},
 resize:(w,h,cfi)=>operations.push('resize:'+cfi),
 q:{enqueue:()=>new Promise(r=>finishResize=r)},reportLocation:async()=>operations.push('restored')};
 vm.runInContext("rendition=mock;current='saved';viewportSize={width:1000,height:700};pendingViewport={width:660,height:700};pageTransition='instant';requestPagination=()=>{};updatePageInformation=()=>{};invalidatePagination=()=>{};clearChapterSelections=()=>{};",orderContext);
 const before=vm.runInContext("turn('next')",orderContext);
 const resizing=vm.runInContext('queueLayout(undefined,true)',orderContext);
 const after=vm.runInContext("turn('next')",orderContext);
 for(let i=0;i<8;i++)await tick();
 assert.deepEqual(operations,['turn'],'Resize cannot clear views during an active turn');
 finishTurn();await before;for(let i=0;i<8;i++)await tick();
 assert.deepEqual(operations,['turn','resize:saved'],'Next turn waits for internal resize redisplay');
 finishResize();await resizing;await after;
 assert.deepEqual(operations,['turn','resize:saved','restored','turn'],'Resize restoration and turns complete in order without deadlock');
 // Hardware insets belong outside the small chapter/progress bands.
 const chromeNodes={reader:{style:{}},'page-chapter':{style:{}},'page-progress':{style:{}}};
 const previousElementLookup=context.document.getElementById;
 context.document.getElementById=id=>chromeNodes[id];
 vm.runInContext('setPageChrome({enabled:true,showChapter:true,showProgress:true,top:91,bottom:88,safeTop:47,safeBottom:34,textSize:12})',context);
 assert.equal(chromeNodes['page-chapter'].style.top,'47px');
 assert.equal(chromeNodes['page-chapter'].style.height,'44px','Chapter band excludes the notch reservation');
 assert.equal(chromeNodes['page-progress'].style.bottom,'34px');
 assert.equal(chromeNodes['page-progress'].style.height,'54px','Progress band sits above the home indicator');
 context.document.getElementById=previousElementLookup;
 // A resize snapshot must cover frame replacement until restoration/paint completes.
 const snapshots=[], reflowModes=[];
 orderContext.requestAnimationFrame=callback=>callback();
 orderContext.document.startViewTransition=callback=>{
   snapshots.push('capture');
   reflowModes.push(orderContext.document.documentElement.dataset.pageReflow);
   const updateCallbackDone=Promise.resolve().then(callback);
   return {updateCallbackDone,finished:updateCallbackDone,skipTransition(){}};
 };
 orderContext.mock.q.enqueue=async()=>{};
 vm.runInContext('pendingViewport={width:720,height:700}',orderContext);
 await vm.runInContext('queueLayout(undefined,true)',orderContext);
 await tick();
 assert.deepEqual(snapshots,[],'Direct window resizing stays live without a snapshot');
 await orderContext.window.readerCommand({name:'sidebarTransition',value:{phase:'begin',request:'first'}});
 vm.runInContext('pendingViewport={width:700,height:700}',orderContext);
 const held=vm.runInContext('queueLayout(undefined,true)',orderContext);
 for(let i=0;i<8;i++) await tick();
 assert.equal(vm.runInContext('!!sidebarHold',orderContext),true,'Native sidebar hold remains active');
 vm.runInContext('pendingViewport={width:690,height:700};queueLayout(undefined,true)',orderContext);
 await orderContext.window.readerCommand({name:'sidebarTransition',value:{phase:'end',request:'first'}});
 await held;
 await tick();
 assert.deepEqual(snapshots,['capture'],'Explicit sidebar resizing captures the old painted page');
 assert.deepEqual(reflowModes,['viewport'],'Viewport resizing uses the sidebar reflow treatment');
 assert.equal(vm.runInContext('restoring',orderContext),false,'Snapshot resize releases restoration');
 assert.equal(orderContext.document.documentElement.dataset.pageReflow,undefined,'Completed reflow clears snapshot styling');
 vm.runInContext('pendingViewport={width:710,height:700}',orderContext);
 await vm.runInContext('queueLayout(undefined,true)',orderContext);
 assert.equal(snapshots.length,1,'A native sidebar animation cannot restart snapshots for each intermediate width');

 orderContext.mock.display=async()=>{};
 vm.runInContext("latestPreferences={fontSize:20};preferences=p=>{latestPreferences=p;return false}",orderContext);
 await vm.runInContext('queueLayout({fontSize:24})',orderContext);
 await tick();
 assert.deepEqual(reflowModes,['viewport','typography'],'Typography reflow uses the shorter treatment');
 orderContext.window.matchMedia=()=>({matches:true});
 vm.runInContext('pendingViewport={width:740,height:700}',orderContext);
 await vm.runInContext('queueLayout(undefined,true)',orderContext);
 assert.equal(snapshots.length,2,'Reduce Motion uses ordinary layout without a transition snapshot');
 orderContext.window.matchMedia=()=>({matches:false});
 let finishSnapshot;
 await orderContext.window.readerCommand({name:'sidebarTransition',value:{phase:'begin',request:'interrupt'}});
 orderContext.document.startViewTransition=callback=>{
   const updateCallbackDone=Promise.resolve().then(callback);
   return {updateCallbackDone,finished:new Promise(resolve=>finishSnapshot=resolve),skipTransition(){}};
 };
 vm.runInContext('pendingViewport={width:760,height:700}',orderContext);
 const interruptHold=vm.runInContext('queueLayout(undefined,true)',orderContext);
 for(let i=0;i<8;i++)await tick();
 await orderContext.window.readerCommand({name:'sidebarTransition',value:{phase:'end',request:'interrupt'}});
 await interruptHold;
 vm.runInContext('activeTransition={skipTransition(){}}',orderContext);
 finishSnapshot(); await tick();
 assert.equal(orderContext.document.documentElement.dataset.pageReflow,undefined,'Interrupted snapshot cannot disable subsequent page-turn animation');
 // A stale sidebar marker must not turn later direct resizing into snapshots.
 orderContext.document.startViewTransition=callback=>{
   snapshots.push('unexpected');
   const updateCallbackDone=Promise.resolve().then(callback);
   return {updateCallbackDone,finished:updateCallbackDone,skipTransition(){}};
 };
 vm.runInContext('pendingViewport={width:780,height:700}',orderContext);
 await vm.runInContext('queueLayout(undefined,true)',orderContext);
 assert.equal(snapshots.length,2,'Expired sidebar marker leaves direct resizing live');


 // Live inspector reflow reports painted intermediate widths without snapshot holds.
 const liveMessages=[];
 orderContext.window.webkit.messageHandlers.reader.postMessage=m=>liveMessages.push(m);
 const liveTimers=new Map(); let liveTimerID=0; orderContext.setTimeout=(fn,ms)=>{const id=++liveTimerID;liveTimers.set(id,{fn,ms});return id}; orderContext.clearTimeout=id=>liveTimers.delete(id);
 orderContext.document.getElementById=id=>id==='reader'?{getBoundingClientRect:()=>({width:740,height:700})}:null;
 await orderContext.window.readerCommand({name:'sidebarTransition',value:{phase:'begin',request:'live-a',mode:'live'}});
 vm.runInContext('pendingViewport={width:750,height:700}',orderContext);
 await vm.runInContext('queueLayout(undefined,true)',orderContext);
 assert(liveMessages.some(m=>m.kind==='sidebarLayoutReady' && m.request==='live-a' && m.width===750),'Live width is acknowledged before end');
 assert.equal(vm.runInContext('sidebarLive.request',orderContext),'live-a');
 await orderContext.window.readerCommand({name:'sidebarTransition',value:{phase:'begin',request:'live-b',mode:'live'}});
 await orderContext.window.readerCommand({name:'sidebarTransition',value:{phase:'end',request:'live-a'}});
 assert.equal(vm.runInContext('sidebarLive.request',orderContext),'live-b','Stale completion cannot end newer live session');
 await orderContext.window.readerCommand({name:'sidebarTransition',value:{phase:'end',request:'live-b'}});
 assert.equal(vm.runInContext('sidebarLive.request',orderContext),'live-b','Early end hint waits for a real width change');
 vm.runInContext('resizeViewport({width:740,height:700})',orderContext);
 await vm.runInContext('layoutTask',orderContext);
 const quiet=[...liveTimers.values()].filter(x=>x.ms===80).at(-1);
 assert(quiet,'Geometry settlement is scheduled after observed resize'); quiet.fn(); await tick();
 assert.equal(vm.runInContext('sidebarLive',orderContext),null,'Settled geometry ends live session');

 // Obsolete counters must finish before a new publication is allocated.
 let releaseCounter, allocations=0;
 const counterContext={window:{webkit:{messageHandlers:{reader:{postMessage(){}}}}},
   document:{documentElement:{dataset:{},style:{setProperty(){}}}},setTimeout:context.setTimeout,clearTimeout:context.clearTimeout};
 counterContext.ePub=()=>{allocations++;return {ready:Promise.reject(Error('fixture')),destroy(){}};};
 counterContext.ePub.Rendition=function(){};
 counterContext.previousCounter=new Promise(resolve=>releaseCounter=resolve);
 vm.createContext(counterContext);
 vm.runInContext(fs.readFileSync('App/Resources/Reader/reader.js','utf8'),counterContext);
 vm.runInContext('ready=true;publicationURL="fixture";viewportSize={width:1000,height:700};paginationTask=previousCounter;',counterContext);
 const obsoleteCount=vm.runInContext('requestPagination()',counterContext);
 const finalCount=vm.runInContext('viewportSize={width:660,height:700};requestPagination()',counterContext);
 await tick();assert.equal(allocations,0,'Old counter owns resources until cleanup completes');
 releaseCounter();await Promise.all([obsoleteCount,finalCount]);
 assert.equal(allocations,1,'Only newest queued page counter allocates a publication');

 // Hidden WebKit relocations must not replace the last visible scroll position.
 const visibilityMessages=[], visibilityDisplays=[];
 const visibilityContext={window:{webkit:{messageHandlers:{reader:{postMessage:m=>visibilityMessages.push(m)}}}},
   document:{visibilityState:'visible',documentElement:{dataset:{},style:{setProperty(){}}},
     getElementById:()=>({getBoundingClientRect:()=>({width:375,height:700})}),querySelectorAll:()=>[]},
   setTimeout:context.setTimeout,clearTimeout:context.clearTimeout,requestAnimationFrame:fn=>fn()};
 visibilityContext.ePub={CFI:class {compare(a,b){return Number(a)-Number(b)}}};
 visibilityContext.fixtureRendition={location:{start:{cfi:'60',href:'chapter',index:0},end:{cfi:'70'}},
   manager:{},reportLocation:async()=>{},display:async cfi=>{visibilityDisplays.push(cfi);visibilityContext.fixtureRendition.location={start:{cfi:'60',href:'chapter',index:0},end:{cfi:'70'}}}};
 vm.createContext(visibilityContext);
 vm.runInContext(fs.readFileSync('App/Resources/Reader/reader.js','utf8'),visibilityContext);
 vm.runInContext('ready=true;scrolling=true;current="65";rendition=fixtureRendition;book={locations:{percentageFromCfi:()=>0.65}};updatePageInformation=()=>{};refreshNoteMarkers=()=>{};',visibilityContext);
 visibilityContext.document.visibilityState='hidden';
 vm.runInContext('onReaderVisibilityChange();rendition.location={start:{cfi:"0",href:"start",index:0},end:{cfi:"2"}};reportPosition(rendition.location)',visibilityContext);
 assert.equal(vm.runInContext('current',visibilityContext),'65','A hidden relocation must not replace the saved passage');
 assert.equal(visibilityMessages.filter(m=>m.kind==='position').length,0,'No hidden position is persisted');
 visibilityContext.document.visibilityState='visible';
 await vm.runInContext('resumeVisiblePassage(++visibilityGeneration)',visibilityContext);
 assert.deepEqual(visibilityDisplays,['65'],'A displaced visible renderer returns to the saved passage');
 assert.equal(vm.runInContext('current',visibilityContext),'65','The precise passage survives restoration');
 assert.equal(visibilityMessages.filter(m=>m.kind==='position').length,1,'Only the restored position is reported');
 vm.runInContext('rendition.location={start:{cfi:"80",href:"chapter",index:0},end:{cfi:"90"}};reportPosition(rendition.location)',visibilityContext);
 assert.equal(vm.runInContext('current',visibilityContext),'80','Subsequent reading updates the saved position normally');
 vm.runInContext('visibilityAnchor="65";resizeAnchor="65";resizeBoundary="60";cancelVisibilityRestore({type:"keydown",key:"a"})',visibilityContext);
 assert.equal(vm.runInContext('visibilityAnchor',visibilityContext),'65','Unrelated keyboard input cannot abandon the saved passage');
 vm.runInContext('cancelVisibilityRestore({type:"touchmove"})',visibilityContext);
 assert.equal(vm.runInContext('visibilityAnchor',visibilityContext),null,'Deliberate scrolling releases the restore guard');
 assert.equal(vm.runInContext('resizeAnchor',visibilityContext),null,'A deliberate scroll also clears any earlier layout anchor');

 // A second lock during the asynchronous visibility check must invalidate
 // the first resume, without persisting or navigating to a stale viewport.
 let releaseVisibilityReport;
 visibilityContext.slowReport=()=>new Promise(resolve=>{releaseVisibilityReport=resolve});
 visibilityContext.document.visibilityState='hidden';
 vm.runInContext('onReaderVisibilityChange();rendition.location={start:{cfi:"0",href:"start",index:0},end:{cfi:"2"}};rendition.reportLocation=slowReport',visibilityContext);
 visibilityContext.document.visibilityState='visible';
 const priorPositions=visibilityMessages.filter(m=>m.kind==='position').length;
 const priorDisplays=visibilityDisplays.length;
 const interruptedResume=vm.runInContext('resumeVisiblePassage(++visibilityGeneration)',visibilityContext);
 await tick();
 visibilityContext.document.visibilityState='hidden';
 vm.runInContext('onReaderVisibilityChange()',visibilityContext);
 releaseVisibilityReport(); await interruptedResume;
 assert.equal(visibilityMessages.filter(m=>m.kind==='position').length,priorPositions,'A re-locked reader cannot persist an interrupted resume');
 assert.equal(visibilityDisplays.length,priorDisplays,'A re-locked reader cannot navigate after the interrupted report');
 assert.equal(vm.runInContext('visibilityAnchor',visibilityContext),'80','The last visible passage remains available for the next unlock');

 // Once a WebKit display has started it cannot be cancelled. A deliberate
 // seek must run after that display so the chosen destination wins.
 let finishVisibilityDisplay, signalVisibilityDisplay;
 const displayStarted = new Promise(resolve=>{signalVisibilityDisplay=resolve});
 const navigationOrder=[];
 visibilityContext.delayedDisplay=async()=>{navigationOrder.push('restore');signalVisibilityDisplay();await new Promise(resolve=>{finishVisibilityDisplay=resolve})};
 visibilityContext.userSeek=async()=>{navigationOrder.push('seek')};
 visibilityContext.document.visibilityState='visible';
 vm.runInContext('rendition.reportLocation=async()=>{};rendition.display=delayedDisplay;seek=userSeek;scheduleVisibilityRestore(++visibilityGeneration)',visibilityContext);
 await displayStarted;
 const explicitSeek=vm.runInContext('window.readerCommand({name:"seek",value:{cfi:"95"}})',visibilityContext);
 await tick();
 assert.deepEqual(navigationOrder,['restore'],'A user seek waits for an already-started restoration display');
 finishVisibilityDisplay(); await explicitSeek;
 assert.deepEqual(navigationOrder,['restore','seek'],'Explicit navigation wins over the delayed restoration');

 // A user scroll during an uncancellable WebKit display must prevent the
 // follow-up offset correction and its location report.
 let finishAbortedDisplay, signalAbortedDisplay;
 const abortedStarted=new Promise(resolve=>{signalAbortedDisplay=resolve});
 const afterScroll=[];
 visibilityContext.delayedAbortDisplay=async()=>{signalAbortedDisplay();await new Promise(resolve=>{finishAbortedDisplay=resolve})};
 visibilityContext.keepRestore=true;
 visibilityContext.fixtureRendition.display=visibilityContext.delayedAbortDisplay;
 visibilityContext.fixtureRendition.reportLocation=async()=>afterScroll.push('report');
 visibilityContext.fixtureRendition.manager={views:{find:()=>({offset:()=>({top:100}),locationOf:()=>({top:200})})},scrollTo:()=>afterScroll.push('scroll')};
 visibilityContext.bookForAbort={spine:{get:()=>({})}};
 vm.runInContext('book=bookForAbort',visibilityContext);
 const abortedDisplay=vm.runInContext('displayReadingLocation("epubcfi(/6/2!/4/2:3)",()=>keepRestore)',visibilityContext);
 await abortedStarted;
 visibilityContext.keepRestore=false; finishAbortedDisplay();
 assert.equal(await abortedDisplay,false,'A cancelled restoration reports that it did not finish');
 assert.deepEqual(afterScroll,[],'A user scroll stops later correction and stale position reporting');

 console.log('Reader bridge: cancellation, ownership, layout, resize, continuous-flow opening and mode restoration checks passed');
})().catch(e=>{console.error(e);process.exitCode=1});
