'use strict';
let book, rendition, current, ready = false, searchGeneration = 0, scrolling = false, preferenceTimer, restoring = false, pageTransition = 'slide', nativePageTurns = false, pageTapZoneFraction = 0.2;
let nativeReflowBridge = false, reflowSequence = 0;
let sectionLocationCounts = new Map(), observedSectionPages = new Map();
const chapterSnippetCache = new Map();
const send = (kind, value = {}) => window.webkit.messageHandlers.reader.postMessage({kind, ...value});
// A page is one visible reader spread. Count a separate sandboxed rendition;
// never move the live reader or use character percentages as page indices.
let paginationTimer;
let layoutPages = [], paginationGeneration = 0, paginationTask, paginationKey, latestPreferences, publicationURL;
let navigationTitles = new Map(), publicationTitle = '';
function chapterTitleFor(index) {
  const fallback = (typeof book?.package?.metadata?.title === 'string' ? book.package.metadata.title.trim() : '') || publicationTitle;
  if (!Number.isInteger(index)) return fallback;
  let best = -1, title = '';
  for (const [section, candidate] of navigationTitles) {
    if (section <= index && section > best && candidate) { best = section; title = candidate; }
  }
  return title || fallback;
}
let savedHighlights = new Set();
let savedHighlightDetails = new Map();
let searchHighlights = new Set();
let selectionObserved = new WeakSet();
let sidebarHold = null, sidebarLive = null, sidebarReadyRequest = null, sidebarLayoutHealthy = true;
function scheduleSidebarLayoutReady(request) {
  if (!request) return;
  // Never await from release: layout can itself be waiting for the hold.
  Promise.resolve().then(async () => {
    if (layoutTask) await layoutTask;
    if (sidebarReadyRequest !== request || sidebarHold || sidebarLive || !sidebarLayoutHealthy) return;
    const transition = activeReflowTransition;
    if (transition) await transition.finished.catch(() => {});
    if (sidebarReadyRequest !== request || sidebarHold || sidebarLive || layoutTask || activeReflowTransition || !sidebarLayoutHealthy) return;
    await nextPaint();
    if (sidebarReadyRequest !== request || sidebarHold || sidebarLive || layoutTask || activeReflowTransition || pendingResize || pendingPreferences || !sidebarLayoutHealthy) return;
    if (Number.isFinite(viewportSize?.width) && viewportSize.width > 0)
      send('sidebarLayoutReady',{request,width:viewportSize.width,settled:true});
  }).catch(() => {});
}
function releaseSidebarHold(request) {
  const hold = sidebarHold;
  if (!hold || (request && request !== hold.request)) return;
  sidebarHold = null; clearTimeout(hold.timer); hold.resolve();
  scheduleSidebarLayoutReady(hold.request);
}
function beginSidebarHold(request) {
  if (sidebarLive) { clearTimeout(sidebarLive.timer); clearTimeout(sidebarLive.quietTimer); sidebarLive = null; }
  sidebarReadyRequest = request;
  releaseSidebarHold();
  let resolve;
  const done = new Promise(r => { resolve = r; });
  const hold = {request, done, resolve, timer:null};
  // Recovery only: an omitted native completion must never block navigation.
  hold.timer = setTimeout(() => releaseSidebarHold(request), 2500);
  sidebarHold = hold;
}
function endSidebarLive(request) {
  if (!sidebarLive || (request && sidebarLive.request !== request)) return;
  const ended = sidebarLive.request;
  clearTimeout(sidebarLive.timer); clearTimeout(sidebarLive.quietTimer); sidebarLive = null;
  scheduleSidebarLayoutReady(ended);
  if (!layoutTask) schedulePagination();
}
function beginSidebarLive(request) {
  sidebarReadyRequest = request;
  releaseSidebarHold();
  if (sidebarLive) { clearTimeout(sidebarLive.timer); clearTimeout(sidebarLive.quietTimer); }
  const session = {request, timer:null, quietTimer:null, endRequested:false, sawResize:false, observed:null};
  // A missing native completion must not defer pagination forever.
  session.timer = setTimeout(() => endSidebarLive(request), 2500);
  sidebarLive = session;
  invalidatePagination();
}
function scheduleLiveSettlement() {
  const session = sidebarLive;
  if (!session || !session.endRequested || !session.sawResize) return;
  clearTimeout(session.quietTimer);
  session.quietTimer = setTimeout(() => {
    if (sidebarLive !== session) return;
    const rect = document.getElementById('reader')?.getBoundingClientRect();
    const measured = rect && {width:Math.floor(rect.width),height:Math.floor(rect.height)};
    if (layoutTask || pendingResize || pendingPreferences || !sidebarLayoutHealthy ||
        !measured || measured.width !== viewportSize?.width || measured.height !== viewportSize?.height) {
      scheduleLiveSettlement(); return;
    }
    endSidebarLive(session.request);
  }, 80);
}
function requestSidebarLiveEnd(request) {
  if (!sidebarLive || sidebarLive.request !== request) return;
  sidebarLive.endRequested = true;
  scheduleLiveSettlement();
}
async function reportLiveSidebarWidth(request) {
  if (!request || sidebarLive?.request !== request) return;
  await nextPaint();
  if (sidebarLive?.request === request && sidebarReadyRequest === request && Number.isFinite(viewportSize?.width) && viewportSize.width > 0)
    send('sidebarLayoutReady',{request,width:viewportSize.width,settled:false});
}
let selectionPoll, lastPolledSelection = '', lastSelectionContext = '';
// Publication iframes deliberately disallow scripts, so callbacks registered
// inside them are not reliable. The trusted reader frame can inspect the
// selected range without enabling any publication scripts.
function selectionContext(range, text) {
  try {
    const block = range.commonAncestorContainer.nodeType === 3 ? range.commonAncestorContainer.parentElement : range.commonAncestorContainer;
    const prefix = range.cloneRange(); prefix.selectNodeContents(block); prefix.setEnd(range.startContainer,range.startOffset);
    return excerptWindow(block.textContent || text,prefix.toString().length,Math.min(text.length,256)).slice(0,1024);
  } catch (_) { return text.slice(0,1024); }
}
function pollSelection() {
  if (!rendition || !ready) return;
  let result;
  for (const contents of rendition.getContents()) {
    const frame = Array.from(document.querySelectorAll('iframe')).find(item => item.contentDocument === contents.document);
    if (!frame) continue;
    const rect = frame.getBoundingClientRect();
    if (rect.bottom <= 0 || rect.top >= viewportSize.height || rect.right <= 0 || rect.left >= viewportSize.width) continue;
    const selection = contents.window?.getSelection();
    if (!selection || selection.rangeCount !== 1 || selection.isCollapsed) continue;
    const text = selection.toString().trim();
    if (!text || text.length > 16384) continue;
    try {
      const cfi = contents.cfiFromRange(selection.getRangeAt(0));
      if (typeof cfi === 'string' && cfi.startsWith('epubcfi(') && cfi.endsWith(')') && cfi.length <= 8192) result = {cfi,text,context:JSON.stringify([current,cfi,text]) === lastPolledSelection ? lastSelectionContext : selectionContext(selection.getRangeAt(0),text)};
    } catch (_) { /* Keep unrepresentable ranges selectable without annotating. */ }
    if (result) break;
  }
  const key = result ? JSON.stringify([current, result.cfi, result.text]) : '';
  if (key === lastPolledSelection) return;
  const wasActive = !!lastPolledSelection;
  lastPolledSelection = key; lastSelectionContext = result?.context || '';
  if (result) { if (!wasActive) send('selection',{active:true}); send('selectedText',result); }
  else if (wasActive) send('selection',{active:false});
}
function reportSelectionState() {
  const active = Array.from(document.querySelectorAll('iframe')).some(frame => {
    const rect = frame.getBoundingClientRect();
    return rect.bottom > 0 && rect.top < viewportSize.height && frame.contentWindow?.getSelection()?.toString();
  });
  send('selection',{active});
}
function observeSelection(contents) {
  if (!contents?.document || selectionObserved.has(contents.document)) return;
  selectionObserved.add(contents.document);
  contents.document.addEventListener('selectionchange', reportSelectionState);
}
const annotationColors = {yellow:'#e6b84a',green:'#65b879',blue:'#69a6df',pink:'#e88aaf',purple:'#af8add'};
function setSavedHighlights(items) {
  const next = new Map();
  for (const item of (Array.isArray(items) ? items : []).slice(0,10000)) {
    const cfi = typeof item === 'string' ? item : item?.cfi;
    if (typeof cfi !== 'string' || cfi.length > 8192 || !cfi.startsWith('epubcfi(') || !cfi.endsWith(')')) continue;
    next.set(cfi,{cfi,id: typeof item?.id === 'string' && /^[0-9a-f-]{36}$/i.test(item.id) ? item.id : null,
      color: Object.hasOwn(annotationColors,item?.color) ? item.color : 'yellow',
      style:item?.style === 'underline' ? 'underline' : 'highlight',hasNote:item?.hasNote === true});
  }
  for (const [cfi, old] of savedHighlightDetails) if (!next.has(cfi) || JSON.stringify(old) !== JSON.stringify(next.get(cfi))) {
    try { rendition.annotations.remove(cfi,old.style); } catch (_) {}
  }
  for (const [cfi, detail] of next) if (JSON.stringify(savedHighlightDetails.get(cfi)) !== JSON.stringify(detail)) {
    try {
      if (searchHighlights.has(cfi)) { rendition.annotations.remove(cfi,'highlight'); searchHighlights.delete(cfi); }
      const color = annotationColors[detail.color];
      if (detail.style === 'underline') rendition.annotations.underline(cfi,{},null,'saved-underline',{'stroke':color,'stroke-opacity':'0.9','stroke-width':'2'});
      else rendition.annotations.highlight(cfi,{},null,'saved-highlight',{fill:color,'fill-opacity':'0.35'});
    } catch (_) {}
  }
  savedHighlightDetails = next; savedHighlights = new Set(next.keys());
  refreshNoteMarkers();
}
function visibleAnnotationRects(cfi) {
  try {
    const range = rendition?.getRange?.(cfi);
    if (!range) return [];
    const frame = Array.from(document.querySelectorAll('iframe')).find(frame => frame.contentDocument === range.startContainer.ownerDocument);
    const reader = document.getElementById('reader');
    if (!frame || !reader) return [];
    const bounds = frame.getBoundingClientRect(), content = reader.getBoundingClientRect();
    // All coordinates are viewport coordinates, including the native header
    // inset. Clip to both the visible reader and the owning publication frame.
    const clip = {left:Math.max(0,content.left,bounds.left),top:Math.max(0,content.top,bounds.top),
      right:Math.min(window.innerWidth,content.right,bounds.right),bottom:Math.min(window.innerHeight,content.bottom,bounds.bottom)};
    return Array.from(range.getClientRects()).map(rect => ({left:Math.max(rect.left+bounds.left,clip.left),
      top:Math.max(rect.top+bounds.top,clip.top),right:Math.min(rect.right+bounds.left,clip.right),
      bottom:Math.min(rect.bottom+bounds.top,clip.bottom)})).filter(rect => rect.right > rect.left && rect.bottom > rect.top);
  } catch (_) { return []; }
}

function activateAnnotationAt(x,y) {
  const badge = document.elementFromPoint?.(x,y)?.closest?.('.reader-note-marker');
  if (badge) { send('annotationActivated',{id:badge.dataset.annotation}); return true; }
  for (const [cfi,detail] of savedHighlightDetails) {
    if (detail.id && visibleAnnotationRects(cfi).some(rect => x >= rect.left && x <= rect.right && y >= rect.top && y <= rect.bottom)) {
      send('annotationActivated',{id:detail.id}); return true;
    }
  }
  return false;
}
function refreshNoteMarkers() {
  if (!document.createElement) return;
  document.querySelectorAll('.reader-note-marker').forEach(node=>node.remove());
  const page = document.getElementById('page'), reader = document.getElementById('reader');
  if (!page || !reader) return;
  const pageBounds = page.getBoundingClientRect(), content = reader.getBoundingClientRect();
  const left = Math.max(0, content.left), right = Math.min(window.innerWidth,content.right);
  const top = Math.max(0,content.top), bottom = Math.min(window.innerHeight,content.bottom);
  const columns = scrolling ? 1 : Math.max(1, Math.min(2, rendition?.manager?.layout?.divisor || 1));
  const width = (right-left)/columns, occupied = Array.from({length:columns},()=>[]), size=24;
  if (width < size || bottom-top < size) return;
  for (const [cfi,detail] of savedHighlightDetails) {
    if (!detail.id || !detail.hasNote) continue;
    const rect = visibleAnnotationRects(cfi)[0];
    if (!rect) continue;
    const column = Math.max(0,Math.min(columns-1,Math.floor(((rect.left+rect.right)/2-left)/width)));
    let y = Math.max(top,Math.min(bottom-size,rect.top));
    // Resolve collisions independently in each page's margin. Try downward,
    // then upward so a bottom-line note remains reachable within the reader.
    const available = candidate => candidate >= top && candidate+size <= bottom && occupied[column].every(other=>Math.abs(other-candidate)>=size);
    if (!available(y)) {
      const original = y;
      let found = false;
      for (let step=size; step < bottom-top; step+=size) {
        if (available(original+step)) { y=original+step; found=true; break; }
        if (available(original-step)) { y=original-step; found=true; break; }
      }
      if (!found) continue;
    }
    occupied[column].push(y);
    const button=document.createElement('button');
    button.className='reader-note-marker';button.dataset.annotation=detail.id;button.type='button';button.textContent='✎';
    button.setAttribute('aria-label','Edit note');button.title='Edit note';
    button.style.left=(left+(column+1)*width-size-2-pageBounds.left)+'px';
    button.style.right='auto'; button.style.top=(y-pageBounds.top)+'px';
    button.addEventListener('click',()=>send('annotationActivated',{id:detail.id}));
    page.appendChild(button);
  }
}

let pageChrome = {enabled:false};
function setPageChrome(value = {}) {
  pageChrome = {...value};
  const reader = document.getElementById?.('reader');
  const header = document.getElementById?.('page-chapter');
  const footer = document.getElementById?.('page-progress');
  if (!reader || !header || !footer) return;
  const top = value.enabled ? Math.max(0, value.top || 0) : 0;
  const bottom = value.enabled ? Math.max(0, value.bottom || 0) : 0;
  reader.style.top = top + 'px'; reader.style.bottom = bottom + 'px';
  reader.style.height = `calc(100% - ${top + bottom}px)`;
  reader.style.maskImage = value.softEdges ? 'linear-gradient(to bottom, transparent, black 8px, black calc(100% - 8px), transparent)' : '';
  reader.style.webkitMaskImage = reader.style.maskImage;
  const safeTop = value.enabled ? Math.min(top, Math.max(0, value.safeTop || 0)) : 0;
  const safeBottom = value.enabled ? Math.min(bottom, Math.max(0, value.safeBottom || 0)) : 0;
  header.style.top = safeTop + 'px'; footer.style.bottom = safeBottom + 'px';
  header.style.height = (top - safeTop) + 'px'; footer.style.height = (bottom - safeBottom) + 'px';
  header.style.fontSize = footer.style.fontSize = Math.max(12, value.textSize || 12) + 'px';
  header.hidden = !value.enabled || !value.showChapter;
  footer.hidden = !value.enabled || !value.showProgress;
}
function pageInformation(location) {
  const start = location?.start;
  if (!start) return {chapter:'',progress:''};
  const divisor = rendition.manager?.layout?.divisor || 1;
  const page = Math.ceil((start.displayed?.page || 0) / divisor);
  const total = Math.ceil((start.displayed?.total || 0) / divisor);
  return {chapter:chapterTitleFor(start.index),
          progress:total > 0 && page > 0 ? `${Math.max(0,total-page)} ${total-page===1?'page':'pages'} left in chapter` : 'Chapter pages unavailable'};
}
function updatePageInformation(location) {
  const info = pageInformation(location);
  const header = document.getElementById?.('page-chapter'), footer = document.getElementById?.('page-progress');
  if (header) (document.getElementById?.('chapter-title') || header).textContent = info.chapter;
  if (footer) footer.textContent = info.progress;
}
function insideContent(x,y) {
  const rect = document.getElementById?.('reader')?.getBoundingClientRect();
  return !rect || (x >= rect.left && x < rect.left+rect.width && y >= rect.top && y < rect.top+rect.height);
}
function paginationSignature(p = latestPreferences) {
  return JSON.stringify([viewportSize?.width, viewportSize?.height, p?.font, p?.fontSize, p?.lineHeight, p?.margin, p?.scrolling, p?.originalFormatting]);
}
function invalidatePagination() {
  clearTimeout(paginationTimer); paginationTimer = undefined;
  ++paginationGeneration;
  layoutPages = []; paginationKey = undefined;
  send('pagination', {pages:0, chapters:[]});
}
function paginationPosition(location) {
  if (scrolling || !layoutPages.length) return {bookPage:0, bookPageCount:0};
  const divisor = rendition.manager?.layout?.divisor || 1;
  const localPage = Math.ceil((location.start.displayed?.page || 1) / divisor);
  const index = layoutPages.findIndex(page => page.sectionIndex === location.start.index && page.localPage === localPage);
  return {bookPage:index < 0 ? 0 : index + 1, bookPageCount:layoutPages.length};
}
function sanitizePublication(document) {
  document.querySelectorAll('script,object,embed,iframe,form,base').forEach(node => node.remove());
  document.querySelectorAll('*').forEach(node => Array.from(node.attributes).forEach(attr => {
    if (/^on/i.test(attr.name) || ((/^(src|href|xlink:href|poster|action)$/i).test(attr.name) && /^(https?:|\/\/|javascript:)/i.test(attr.value))) node.removeAttribute(attr.name);
  }));
}
function isFixedLayout(target) {
  return target.book?.package?.metadata?.layout === 'pre-paginated' || target.book?.displayOptions?.fixedLayout === 'true' || target.manager?.layout?.name === 'pre-paginated';
}
const readerThemeStyles = new WeakMap();
function setReaderTheme(target, p) {
  const themes = {light:['#ffffff','#202020'],sepia:['#f4ecd8','#342c20'],dark:['#171717','#dedede']};
  const colors = themes[p.theme] || themes.light;
  const fixed = isFixedLayout(target);
  const original = fixed || p.originalFormatting === true;
  const font = ['Georgia','-apple-system','Palatino'].includes(p.font) ? p.font : 'Georgia';
  const number = (value, fallback, min, max) => Number.isFinite(value) ? Math.max(min,Math.min(max,value)) : fallback;
  const css = fixed ? '/* Fixed-layout composition is authored by the book. */' :
    `body { color:${colors[1]} !important; background:${colors[0]} !important;` +
    (original ? '' : `font-family:${font} !important; font-size:${number(p.fontSize,20,14,36)}px !important; line-height:${number(p.lineHeight,1.6,1.2,2.2)} !important; padding:0 ${number(p.margin,24,8,64)}px !important; margin-top:0 !important; margin-bottom:0 !important;`) +
    `} a { color:inherit; }` + (original ? '' : ` body,p,li,blockquote,h1,h2,h3,h4,h5,h6 { font-family:${font} !important; } p,li,blockquote { font-size:1em !important; line-height:${number(p.lineHeight,1.6,1.2,2.2)} !important; }`);
  // EPUB.js registerRules appends on every update; replacing a named CSS
  // stylesheet removes the old typography rules when switching modes.
  let state = readerThemeStyles.get(target);
  if (!state) {
    state = {css}; readerThemeStyles.set(target, state);
    // EPUB.js injects rule/URL themes into new views but omits serialized
    // themes. Install the current stylesheet as each content view opens.
    target.hooks?.content?.register(contents => contents.addStylesheetCss(state.css, 'default'));
  }
  state.css = css;
  target.themes.registerCss('default', css);
  return colors;
}
async function waitForAssets(view) {
  const document = view.contents.document;
  await document.fonts?.ready;
  await Promise.all(Array.from(document.images).map(image => image.complete ? Promise.resolve() : new Promise(resolve => {
    image.addEventListener('load', resolve, {once:true}); image.addEventListener('error', resolve, {once:true});
  })));
  view.expand();
}
function schedulePagination() {
  clearTimeout(paginationTimer);
  if (sidebarLive) { paginationTimer = undefined; return; }
  // Live text layout stays responsive; whole-book counting waits for a pause.
  paginationTimer = setTimeout(() => { paginationTimer = undefined; requestPagination(); }, 350);
}
function requestPagination() {
  if (sidebarLive || scrolling || !ready || !publicationURL || (typeof ePub === 'undefined' || typeof ePub.Rendition !== 'function')) return;
  const key = paginationSignature();
  if (key === paginationKey) return paginationTask;
  paginationKey = key;
  const generation = ++paginationGeneration, p = {...latestPreferences}, size = {...viewportSize};
  layoutPages = [];
  send('pagination', {pages:0, chapters:[]});
  const precedingPagination = paginationTask;
  const task = (async () => {
    let counterBook, counter, host;
    try {
      // Never allocate a second offscreen publication while the old counter
      // is still releasing its frames. Stale queued requests allocate nothing.
      await precedingPagination?.catch(() => {});
      if (generation !== paginationGeneration) return;
      counterBook = ePub(publicationURL, {openAs:'opf'});
      await withPaginationTimeout(counterBook.ready);
      if (generation !== paginationGeneration) return;
      counterBook.spine.hooks.content.register(sanitizePublication);
      host = document.createElement('div');
      host.setAttribute('aria-hidden','true'); host.inert = true;
      Object.assign(host.style, {position:'fixed',left:'-100000px',top:'0',width:size.width+'px',height:size.height+'px',visibility:'hidden',pointerEvents:'none'});
      document.body.appendChild(host);
      counter = new ePub.Rendition(counterBook, {...size,manager:'default',flow:'paginated',resizeOnOrientationChange:false,allowScriptedContent:false,allowPopups:false});
      counter.attachTo(host);
      await withPaginationTimeout(counter.started);
      counter.manager.viewSettings.forceEvenPages = rendition.manager.viewSettings.forceEvenPages;
      setReaderTheme(counter, p);
      const pages = [];
      for (const section of counterBook.spine.spineItems.filter(section => section.linear)) {
        if (generation !== paginationGeneration) return;
        await withPaginationTimeout(counter.display(section.href));
        const view = counter.manager.views.find(section);
        await withPaginationTimeout(waitForAssets(view));
        if (generation !== paginationGeneration) return;
        const layout = counter.manager.layout;
        if (view.settings.axis !== 'horizontal' || layout.name === 'pre-paginated') throw Error('Unsupported page map');
        const count = layout.count(view.width()).spreads;
        for (let page = 0; page < count; page++) {
          pages.push({sectionIndex:section.index,href:section.href,localPage:page+1});
          if (page % 12 === 0) { await paginationYield(); if (generation !== paginationGeneration) return; }
        }
        section.unload();
        await paginationYield();
      }
      if (generation !== paginationGeneration) return;
      layoutPages = pages;
      const chapters = [];
      for (let i = 0; i < pages.length; i++) {
        if (i && pages[i].sectionIndex === pages[i-1].sectionIndex) continue;
        chapters.push({number:chapters.length+1,href:pages[i].href,title:navigationTitles.get(pages[i].sectionIndex) || `Section ${chapters.length+1}`,start:i/Math.max(1,pages.length-1),end:1});
        if (chapters.length > 1) chapters[chapters.length-2].end = chapters.at(-1).start;
      }
      send('pagination', {pages:pages.length,chapters});
      reportPosition(rendition.location);
    } catch (error) {
      if (generation === paginationGeneration) { layoutPages = []; send('pagination', {pages:0,chapters:[],failed:true}); }
    } finally {
      counter?.destroy(); host?.remove(); counterBook?.destroy();
    }
  })();
  paginationTask = task;
  return task;
}
const paginationYield = () => new Promise(resolve => setTimeout(resolve, 0));
function withPaginationTimeout(task) {
  let timer;
  return Promise.race([task, new Promise((_, reject) => { timer = setTimeout(() => reject(Error('Pagination timeout')), 15000); })]).finally(() => clearTimeout(timer));
}
async function seekLayoutPage(page) {
  const generation = paginationGeneration;
  await paginationTask;
  if (generation !== paginationGeneration || scrolling || !layoutPages.length) return;
  const target = layoutPages[Math.min(layoutPages.length-1, Math.max(0, Math.round(page)))];
  await rendition.display(target.href);
  const manager = rendition.manager;
  const view = manager.views.find(book.spine.get(target.href));
  if (!view || generation !== paginationGeneration) return;
  await waitForAssets(view);
  await nextPaint();
  if (generation !== paginationGeneration) return;
  // Screen destinations use the current layout's exact spread offset. A text
  // CFI can resolve to an earlier column when its range spans a page boundary.
  manager.moveTo({left:(target.localPage - 1) * manager.layout.delta,top:0}, view.width());
  await rendition.reportLocation();
}

function preferences(p) {
  if (!rendition) return;
  const requestedScrolling = p.scrolling ?? scrolling;
  const changedFlow = scrolling !== requestedScrolling;
  latestPreferences = {...p};
  scrolling = requestedScrolling;
  if (p.pageChrome) setPageChrome(p.pageChrome);
  pageTapZoneFraction = Number.isFinite(p.pageTapZoneFraction) ? Math.min(0.3, Math.max(0.1, p.pageTapZoneFraction)) : 0.2;
  pageTransition = p.pageTransition === 'curl' ? 'fade' : ['instant','fade','slide'].includes(p.pageTransition) ? p.pageTransition : 'slide';
  const colors = setReaderTheme(rendition, p);
  document.documentElement.style.setProperty('--reader-paper', colors[0]);
  document.body.style.background = colors[0];
  document.body.style.color = colors[1];
  if (changedFlow) rendition.flow(scrolling ? 'scrolled-continuous' : 'paginated');
  refreshChapterBreaks();
  return changedFlow;
}
function pageTapAction(x) {
  const rect = document.getElementById?.('reader')?.getBoundingClientRect();
  const fraction = rect?.width > 0 ? (x - rect.left) / rect.width : NaN;
  if (!ready || scrolling || !Number.isFinite(fraction) || fraction < 0 || fraction > 1) return 'controls';
  if (fraction < pageTapZoneFraction) return 'previous';
  if (fraction > 1 - pageTapZoneFraction) return 'next';
  return 'controls';
}
async function pageTap(x) {
  const action = pageTapAction(x);
  if (action === 'controls') send('toggleControls');
  else if (nativePageTurns) send('swipe', {direction:action});
  else await turn(action);
}
// One layout operation owns relocation suppression at a time. Requests arriving
// during display are coalesced and applied before reporting positions resumes.
let layoutTask, pendingPreferences, pendingResize = false;
let viewportSize, viewportObserver, pendingViewport, searchPresentation = false;
// Preserve the last visible passage while WebKit is hidden or resuming.
let visibilityAnchor = null, visibilityGeneration = 0, visibilityTask = Promise.resolve();
function scheduleVisibilityRestore(generation) {
  // A display already in flight cannot be cancelled by WebKit. Serialize
  // restorations so an older display cannot finish after a newer one.
  visibilityTask = visibilityTask.catch(() => {}).then(() => resumeVisiblePassage(generation));
}
function cancelVisibilityRestore(event) {
  if (event?.type === 'keydown' && !['ArrowDown','ArrowUp','PageDown','PageUp','Home','End',' '].includes(event.key)) return;
  if (!visibilityAnchor || document.visibilityState === 'hidden') return;
  visibilityAnchor = null; visibilityGeneration++;
  rebaseResizeAnchor();
}
async function resumeVisiblePassage(generation) {
  const anchor = visibilityAnchor;
  if (!anchor || !ready || !scrolling || document.visibilityState === 'hidden') return;
  try {
    await layoutTask;
    await turnTask;
    if (generation !== visibilityGeneration || document.visibilityState === 'hidden') return;
    const bounds = document.getElementById('reader')?.getBoundingClientRect();
    if (!bounds || bounds.width <= 0 || bounds.height <= 0) return;
    await withPaginationTimeout(rendition.reportLocation());
    await nextPaint();
    if (generation !== visibilityGeneration || document.visibilityState === 'hidden') return;
    const parser = new ePub.CFI();
    const containsAnchor = location => location?.start?.cfi && location?.end?.cfi &&
      parser.compare(location.start.cfi, anchor) <= 0 && parser.compare(anchor, location.end.cfi) <= 0;
    if (!containsAnchor(rendition.location)) {
      const applied = await withPaginationTimeout(displayReadingLocation(anchor,
        () => generation === visibilityGeneration && document.visibilityState !== 'hidden'));
      if (!applied) return;
      await withPaginationTimeout(rendition.reportLocation());
      await nextPaint();
    }
    if (generation !== visibilityGeneration || document.visibilityState === 'hidden') return;
    if (!containsAnchor(rendition.location)) throw Error('The saved passage is unavailable');
    // Keep the precise passage, not the start of its newly rendered viewport.
    resizeAnchor = anchor; resizeBoundary = rendition.location.start.cfi;
    visibilityAnchor = null;
    reportPosition(rendition.location);
  } catch (_) {
    // Keep the saved passage; deliberate navigation releases the guard.
  }
}
function onReaderVisibilityChange() {
  if (!ready || !scrolling) return;
  if (document.visibilityState === 'hidden') {
    if (!visibilityAnchor) visibilityAnchor = current || rendition?.location?.start?.cfi || null;
    visibilityGeneration++;
  } else if (visibilityAnchor) {
    const generation = ++visibilityGeneration;
    scheduleVisibilityRestore(generation);
  }
}
document.addEventListener?.('visibilitychange', onReaderVisibilityChange);
for (const event of ['touchmove', 'wheel', 'keydown'])
  document.addEventListener?.(event, cancelVisibilityRestore, {capture:true, passive:true});
// The reader's precise passage survives geometry changes; EPUB.js reports
// the start of the newly aligned spread, which is a different location.
let resizeAnchor = null, resizeBoundary = null, resizeOrigin = null;
function rebaseResizeAnchor() { resizeAnchor = null; resizeBoundary = null; resizeOrigin = null; }
function rememberResizeOrigin() {
  const start = rendition?.location?.start, manager = rendition?.manager;
  if (resizeOrigin || resizeAnchor || scrolling || !start?.href || !start.displayed?.page || !manager?.layout) return;
  const divisor = manager.layout.divisor || 1;
  resizeOrigin = {signature:paginationSignature(), href:start.href,
                  page:Math.floor((start.displayed.page - 1) / divisor),
                  total:start.displayed.total, divisor, delta:manager.layout.delta};
}
async function restoreResizeOrigin() {
  if (!resizeAnchor || !resizeOrigin || resizeOrigin.signature !== paginationSignature() || scrolling) return;
  const origin = resizeOrigin, manager = rendition.manager;
  let restored = false;
  try {
    // Reset the continuous manager to the beginning of the chapter, just as
    // seekLayoutPage does, before applying a chapter-relative spread offset.
    await withPaginationTimeout(rendition.display(origin.href));
    const section = book.spine.get(origin.href), view = section && manager?.views?.find(section);
    if (!view || !manager.layout?.delta) throw Error('Original spread unavailable');
    await withPaginationTimeout(waitForAssets(view));
    await nextPaint();
    await withPaginationTimeout(rendition.reportLocation());
    const start = rendition.location?.start;
    if (!Number.isInteger(origin.total) || start?.href !== origin.href ||
        start?.displayed?.total !== origin.total || (manager.layout.divisor || 1) !== origin.divisor ||
        manager.layout.delta !== origin.delta) throw Error('Original layout no longer matches');
    manager.moveTo({left:origin.page * manager.layout.delta,top:0}, view.width());
    await withPaginationTimeout(rendition.reportLocation());
    const location = rendition.location, parser = new ePub.CFI();
    restored = !!location?.start?.cfi && !!location?.end?.cfi &&
      parser.compare(location.start.cfi, resizeAnchor) <= 0 && parser.compare(resizeAnchor, location.end.cfi) <= 0;
  } catch (_) { /* Fall back to the stable passage, never a stale spread. */ }
  if (!restored) {
    await withPaginationTimeout(rendition.display(resizeAnchor));
    await withPaginationTimeout(rendition.reportLocation());
  }
}

async function setSearchPresentation(active) {
  searchPresentation = !!active;
  const element = document.getElementById('reader');
  if (!element || !viewportSize) return;
  // A native text field's software keyboard changes WebKit's layout viewport,
  // even when SwiftUI ignores its safe area. Keep the hidden document's box
  // fixed until UIKit reports that the keyboard finished hiding.
  element.style.width = active ? viewportSize.width + 'px' : '';
  if (active) element.style.height = viewportSize.height + 'px';
  else {
    setPageChrome(pageChrome);
    await layoutTask;
    await nextPaint();
    if (!searchPresentation) {
      clearChapterSelections();
      if (ready && rendition?.location && book?.locations) reportPosition(rendition.location);
      send('readerRevealed');
    }
  }
}
function resizeViewport(size) {
  const next = {width:Math.floor(size.width), height:Math.floor(size.height)};
  if (searchPresentation || next.width <= 0 || next.height <= 0 || !rendition) return;
  if (sidebarLive) {
    const previous = sidebarLive.observed || viewportSize;
    if (!previous || previous.width !== next.width || previous.height !== next.height) {
      sidebarLive.sawResize = true; sidebarLive.observed = next;
      scheduleLiveSettlement();
    }
  }
  if (pendingViewport || viewportSize?.width !== next.width || viewportSize?.height !== next.height) {
    pendingViewport = next;
    queueLayout(undefined, true);
  }
  if (visibilityAnchor && document.visibilityState !== 'hidden') {
    const generation = ++visibilityGeneration;
    scheduleVisibilityRestore(generation);
  }
}
function queueLayout(p, resize = false) {
  if (p) p = {...latestPreferences,...p};
  if (p || resize) observedSectionPages.clear();
  if (p && paginationSignature(p) !== paginationSignature()) invalidatePagination();
  if (p) pendingPreferences = p;
  pendingResize = pendingResize || resize;
  if (layoutTask) return layoutTask;
  const precedingTurn = turnTask;
  sidebarLayoutHealthy = false;
  layoutTask = Promise.resolve().then(async () => {
    await precedingTurn.catch(() => {});
    restoring = true;
    if (!nativePageTurns) document.documentElement.dataset.layoutBusy = 'true';
    try {
      const applyLayout = async () => {
      if (previewAnchor) {
        const anchor = previewAnchor;
        await withPaginationTimeout(rendition.display(anchor));
        previewAnchor = null; previewing = false; current = resizeAnchor || anchor;
        send('turnCancelled');
      }
      while (pendingPreferences || pendingResize) {
        const p = pendingPreferences, size = pendingViewport;
        let reflowRequest = null;
        pendingPreferences = undefined; pendingResize = false; pendingViewport = undefined;
        if (size && (size.width !== viewportSize?.width || size.height !== viewportSize?.height)) {
          rememberResizeOrigin();
          invalidatePagination(); viewportSize = size;
          // EPUB.js restores its own CFI once. Do not redisplay a boundary CFI.
          const anchor = resizeAnchor || current || rendition.location?.start?.cfi;
          if (anchor) resizeAnchor = anchor;
          if (nativeReflowBridge && !scrolling) {
            reflowRequest = String(++reflowSequence);
            send('reflowBegin', {request:reflowRequest});
          }
          rendition.resize(size.width,size.height,anchor);
          // resize() clears views and enqueues an internal CFI redisplay. Wait
          // for that queue before another resize or page command touches views.
          if (rendition.q?.enqueue) await withPaginationTimeout(rendition.q.enqueue(() => {}));
          if (rendition.reportLocation) await withPaginationTimeout(rendition.reportLocation());
          resizeBoundary = rendition.location?.start?.cfi || null;
        }
        const relayout = p && paginationSignature(p) !== paginationSignature();
        // Preserve a paginated passage even when the first change is font or
        // spacing rather than a geometry change. Scroll-mode transitions keep
        // their existing flow behavior.
        if (relayout && !scrolling && !(p.scrolling ?? scrolling) && !resizeAnchor) {
          rememberResizeOrigin();
          resizeAnchor = current || rendition.location?.start?.cfi || null;
        }
        const anchor = resizeAnchor || current || rendition.location?.start?.cfi;
        const flowChanged = p ? preferences(p) : false;
        if (flowChanged) rebaseResizeAnchor();
        if (anchor && relayout && !flowChanged) { await withPaginationTimeout(rendition.display(anchor)); }
        if (resizeAnchor && relayout) {
          if (rendition.reportLocation) await withPaginationTimeout(rendition.reportLocation());
          resizeBoundary = rendition.location?.start?.cfi || null;
        }
        if (size || relayout) {
          await restoreResizeOrigin();
          if (resizeAnchor) resizeBoundary = rendition.location?.start?.cfi || null;
        }
        if (reflowRequest) {
          // The native afterScreenUpdates capture confirms paint and refreshes
          // its image asynchronously. Do not delay or wait for native decoration.
          const measured = document.getElementById('reader')?.getBoundingClientRect();
          if (measured && Math.floor(measured.width) === viewportSize.width && Math.floor(measured.height) === viewportSize.height)
            send('reflowPainted', {request:reflowRequest,width:viewportSize.width,height:viewportSize.height,
                                 viewWidth:window.innerWidth,viewHeight:window.innerHeight});
        }
        if (size && sidebarLive) await reportLiveSidebarWidth(sidebarLive.request);
      }
      };
      if (!sidebarLive && ((pendingResize && sidebarHold) || (pendingPreferences && paginationSignature(pendingPreferences) !== paginationSignature())) && !nativePageTurns && !window.matchMedia?.('(prefers-reduced-motion: reduce)').matches && typeof document.startViewTransition === 'function') {
        activeTransition?.skipTransition();
        delete document.documentElement.dataset.pageTurn;
        delete document.documentElement.dataset.pageStyle;
        // Only explicit sidebar changes hold the previous page. Direct window
        // resizing remains live; neither path stretches rendered text.
        document.documentElement.dataset.pageReflow = pendingResize ? 'viewport' : 'typography';
        const holdSidebar = !!(pendingResize && sidebarHold);
        const transition = document.startViewTransition(async () => {
          if (holdSidebar) {
            // Keep the captured page while native geometry settles, then lay
            // out only the latest observed width. Turns release this wait.
            while (sidebarHold) await sidebarHold.done;
          }
          await applyLayout();
          await nextPaint();
        }); activeTransition = transition; activeReflowTransition = transition;
        transition.finished.catch(() => {}).finally(() => {
          if (activeReflowTransition === transition) {
            activeReflowTransition = null; delete document.documentElement.dataset.pageReflow;
          }
          if (activeTransition === transition) activeTransition = null;
        });
        await withPaginationTimeout(transition.updateCallbackDone);
      } else { await applyLayout(); }
      sidebarLayoutHealthy = true;
    } catch (_) { send('error'); }
    finally {
      restoring = false; layoutTask = undefined;
      if (sidebarLayoutHealthy) scheduleSidebarLayoutReady(sidebarReadyRequest);
      scheduleLiveSettlement();
      delete document.documentElement.dataset.layoutBusy;
      schedulePagination();
      if (book?.locations && rendition.location?.start?.cfi) reportPosition(rendition.location);
    }
  });
  return layoutTask;
}
let previewPreferences;
let searchTask = Promise.resolve();
function sectionIsDisplayed(section) {
  const views = rendition.views?.();
  const displayed = Array.isArray(views) ? views : views?.displayed?.() || [];
  return displayed.some(view => view.section === section);
}
function excerptWindow(text, matchStart, matchLength) {
  let start = Math.max(0, matchStart - 90);
  let end = Math.min(text.length, matchStart + matchLength + 190);
  // Move the edges to whitespace so excerpts never begin or end mid-word.
  while (start > 0 && start < matchStart && !/\s/.test(text[start - 1])) start++;
  while (end < text.length && !/\s/.test(text[end])) end++;
  const excerpt = text.slice(start, end).replace(/\s+/g, ' ').trim();
  return (start > 0 ? '… ' : '') + excerpt + (end < text.length ? ' …' : '');
}
async function searchExcerpt(result) {
  try {
    const range = await book.getRange(result.cfi);
    const block = range.startContainer.parentElement?.closest('p,blockquote,li,div') || range.startContainer;
    const prefix = range.cloneRange();
    prefix.selectNodeContents(block);
    prefix.setEnd(range.startContainer, range.startOffset);
    return excerptWindow(block.textContent || '', prefix.toString().length, range.toString().length);
  } catch (_) {
    return (result.excerpt || '').replace(/\s+/g, ' ').trim();
  }
}
async function searchPublication(value, generation) {
  const items = [];
  try {
    for (const section of book.spine.spineItems) {
      if (generation !== searchGeneration) return;
      const owned = !section.document;
      try {
        await section.load(book.load.bind(book));
        if (generation !== searchGeneration) return;
        for (const result of section.find(value.query)) {
          if (items.length >= 200 || generation !== searchGeneration) break;
          const title = await searchExcerpt(result);
          if (generation !== searchGeneration) return;
          items.push({id:result.cfi,title,context:flatten(book.navigation?.toc || []).find(chapter => chapter.id.split('#')[0] === section.href)?.title || 'Section ' + (section.index + 1)});
        }
      } finally {
        // Never unload a section already present or now displayed by the reader.
        if (owned && !sectionIsDisplayed(section)) section.unload();
      }
      if (items.length >= 200) break;
    }
    if (generation === searchGeneration) send('results',{items,id:value.id});
  } catch (_) { if (generation === searchGeneration) send('searchError',{id:value.id}); }
}
function flatten(items) { return items.flatMap(item => [{id:item.href,title:item.label.trim()}, ...flatten(item.subitems || [])]); }
function chapterRanges(items) {
  const count = book.locations.length();
  if (!count) return [];
  sectionLocationCounts = new Map();
  observedSectionPages.clear();
  const sectionStarts = new Map();
  for (let index = 0; index < count; index++) {
    const section = book.spine.get(book.locations.cfiFromLocation(index));
    if (section) {
      sectionLocationCounts.set(section.index, (sectionLocationCounts.get(section.index) || 0) + 1);
      if (!sectionStarts.has(section.index)) {
        sectionStarts.set(section.index, book.locations.percentageFromLocation(index));
      }
    }
  }
  const named = new Map();
  for (const item of items) {
    const section = book.spine.get(item.id);
    if (section && sectionStarts.has(section.index) && !named.has(section.index)) {
      named.set(section.index, item.title);
    }
  }
  const entries = [...sectionStarts].sort((a, b) => a[0] - b[0]);
  const starts = entries.filter(([index]) => named.has(index));
  const chapters = starts.length ? starts : entries;
  return chapters.map(([index, start], position) => ({
    number: position + 1,
    title: named.get(index) || `Section ${position + 1}`,
    href:book.spine.get(index)?.href,
    start,
    end: position + 1 < chapters.length ? chapters[position + 1][1] : 1
  }));
}
async function chapterSnippet(value) {
  const section = book.spine.get(book.locations.cfiFromPercentage(Math.min(1, Math.max(0, value.fraction))));
  if (!section) return;
  let snippet = chapterSnippetCache.get(section.index);
  if (snippet === undefined) {
    const owned = !section.document;
    try {
      const document = await section.load(book.load.bind(book));
      const paragraph = [...document.querySelectorAll('p,blockquote')]
        .map(node => (node.textContent || '').replace(/\s+/g, ' ').trim())
        .find(text => text.length >= 30);
      snippet = paragraph ? paragraph.slice(0, 110) : '';
      chapterSnippetCache.set(section.index, snippet);
    } finally {
      if (owned && !sectionIsDisplayed(section)) section.unload();
    }
  }
  send('chapterSnippet', {number:value.number, text:snippet});
}
let positioning = 0;
async function displayReadingLocation(target, isCurrent = () => true) {
  if (!scrolling || typeof target !== 'string' || !target.startsWith('epubcfi(')) {
    await rendition.display(target);
    return isCurrent();
  }
  positioning++;
  try {
    await rendition.display(target);
    if (!isCurrent()) return false;
    await nextPaint();
    if (!isCurrent()) return false;
    const manager = rendition.manager, section = book?.spine?.get?.(target);
    const view = section && manager?.views?.find?.(section);
    const sectionTop = view?.offset?.().top, targetTop = view?.locationOf?.(target).top;
    if (Number.isFinite(sectionTop) && Number.isFinite(targetTop) && typeof manager?.scrollTo === 'function') {
      manager.scrollTo(0, Math.max(0, sectionTop + targetTop), true);
      await nextPaint();
      if (!isCurrent()) return false;
    }
  } finally { positioning--; }
  await rendition.reportLocation();
  await nextPaint();
  return isCurrent();
}
async function seek(value) {
  if (value.cfi) { try { await displayReadingLocation(value.cfi); return; } catch (_) {} }
  await displayReadingLocation(book.locations.cfiFromPercentage(Math.min(1,Math.max(0,value.fraction || 0))));
}
async function displayLocation(target) {
  const previous = current || rendition.location?.start?.cfi;
  try {
    await displayReadingLocation(target);
    if (target.startsWith('epubcfi(') && !savedHighlights.has(target) && !searchHighlights.has(target)) {
      try { rendition.annotations.highlight(target, {}, null, 'search-match', {fill:'#e6b84a','fill-opacity':'0.35'}); searchHighlights.add(target); }
      catch (_) { /* A highlight failure must not invalidate a successful jump. */ }
    }
    return;
  } catch (_) {
    // Some EPUB navigation entries point at an anchor the renderer cannot
    // resolve. A chapter-start fallback is preferable to losing the reader.
    let section;
    try { section = book.spine.get(target.split('#')[0]); } catch (_) {}
    if (section?.href && section.href !== target) {
      try { await rendition.display(section.href); return; } catch (_) {}
    }
  }
  if (previous && previous !== target) {
    try { await rendition.display(previous); } catch (_) {}
  }
  send('navigationError');
}
let activeTransition, activeReflowTransition;
let turnTask = Promise.resolve(), previewAnchor = null, previewing = false;
function clearChapterSelections() {
  for (const frame of document.querySelectorAll('iframe')) frame.contentWindow?.getSelection()?.removeAllRanges();
  lastPolledSelection = ''; lastSelectionContext = '';
  send('selection',{active:false});
}
window.readerCanTurn = (x, y) => {
  if (!ready || scrolling || previewing || !insideContent(x,y)) return false;
  for (const frame of document.querySelectorAll('iframe')) {
    const rect = frame.getBoundingClientRect();
    if (x < rect.left || x >= rect.right || y < rect.top || y >= rect.bottom) continue;
    if (frame.contentWindow?.getSelection()?.toString()) return false;
    const target = frame.contentDocument?.elementFromPoint(x - rect.left, y - rect.top);
    if (target?.closest('a,button,input,select,textarea')) return false;
  }
  return true;
};
// WebKit may suspend animation frames beneath a native snapshot or in an
// occluded window. Rendering must not wait indefinitely for visibility.
const nextPaint = () => new Promise(resolve => {
  let finished = false;
  const complete = () => { if (!finished) { finished = true; clearTimeout(timeout); resolve(); } };
  const timeout = setTimeout(complete, 80);
  requestAnimationFrame(() => requestAnimationFrame(complete));
});
function turn(direction, preview = false, request = null) {
  // WebKit captures both rendered pages; EPUB.js only advances once between snapshots.
  // Serialize rendering only. Native decoration never blocks the next input.
  releaseSidebarHold();
  activeTransition?.skipTransition();
  const precedingLayout = layoutTask;
  turnTask = turnTask.catch(() => {}).then(async () => {
    activeTransition?.skipTransition();
    await precedingLayout;
    if (scrolling) return;
    const before = rendition.location?.start?.cfi;
    const advance = async () => {
      await withPaginationTimeout(direction === 'next' ? rendition.next() : rendition.prev());
      const after = rendition.location?.start?.cfi;
      if (!preview && before && after && after !== before) rebaseResizeAnchor();
      updatePageInformation(rendition.location);
    };
    if (preview || nativePageTurns || pageTransition === 'instant' || window.matchMedia?.('(prefers-reduced-motion: reduce)').matches || typeof document.startViewTransition !== 'function') {
      await advance();
      clearChapterSelections();
      if (preview || nativePageTurns) {
        // EPUB.js can settle its relocation promise before WebKit paints the
        // new frame. The native incoming snapshot must see that new frame.
        await nextPaint();
        send(preview ? 'previewReady' : 'turned',{direction,request,changed:!preview || rendition.location?.start?.cfi !== previewAnchor});
      }
      return;
    }
    document.documentElement.dataset.pageTurn = direction;
    document.documentElement.dataset.pageStyle = pageTransition;
    const transition = document.startViewTransition(advance); activeTransition = transition;
    // Serialize layout only; a new input can interrupt decorative settling.
    transition.finished.catch(() => {}).finally(() => {
      if (activeTransition !== transition) return;
      activeTransition = null;
      delete document.documentElement.dataset.pageTurn; delete document.documentElement.dataset.pageStyle;
    });
    await withPaginationTimeout(transition.updateCallbackDone);
  });
  return turnTask;
}
function refreshChapterBreaks() {
  const views = rendition?.views?.();
  for (const view of Array.isArray(views) ? views : views?.displayed?.() || []) {
    const element = view.element;
    if (!element) continue;
    let divider = element.querySelector('.reader-chapter-break');
    const visible = scrolling && view.section.index !== book.spine.first().index;
    element.style.marginTop = visible ? '44px' : '';
    if (!visible) { divider?.remove(); continue; }
    if (!divider) { divider = document.createElement('div'); divider.className = 'reader-chapter-break'; element.prepend(divider); }
    const title = navigationTitles.get(view.section.index) || 'Next section';
    divider.textContent = title; divider.setAttribute('role','separator'); divider.setAttribute('aria-label',title);
  }
}
function reportPosition(location) {
  if (restoring || previewing || positioning || document.visibilityState === 'hidden' || visibilityAnchor || !location?.start?.cfi) return;
  if (resizeAnchor && resizeBoundary && location.start.cfi !== resizeBoundary) rebaseResizeAnchor();
  current = resizeAnchor || location.start.cfi;
  updatePageInformation(location);
  refreshNoteMarkers();
  const displayed = location.start.displayed || {};
  send('position',{cfi:current,href:location.start.href,fraction:book.locations.percentageFromCfi(current),chapterTitle:chapterTitleFor(location.start.index),chapterPage:Math.ceil((displayed.page || 0)/(rendition.manager?.layout?.divisor || 1)),chapterPageCount:Math.ceil((displayed.total || 0)/(rendition.manager?.layout?.divisor || 1)),...paginationPosition(location)});
}
// A separate renderer prepares real adjacent pages. It has no persistence,
// search, native gestures or full-book pagination work.
let snapshotTask = Promise.resolve(), snapshotRunning = false, snapshotPending = null;
function queueSnapshot(value) {
  return new Promise(resolve => {
    // Obsolete waiting work is discarded before it can load another chapter.
    if (snapshotPending) snapshotPending.resolve();
    snapshotPending = {value,resolve};
    if (snapshotRunning) return;
    snapshotRunning = true;
    snapshotTask = (async () => {
      while (snapshotPending) {
        const job = snapshotPending; snapshotPending = null;
        try { await renderSnapshot(job.value); }
        catch (_) { send('snapshotError',{request:job.value.request}); }
        finally { job.resolve(); }
      }
      snapshotRunning = false;
    })();
  });
}
window.readerSnapshotOrigin = () => {
  if (!ready || scrolling || restoring || !rendition.location?.start) return null;
  const start = rendition.location.start, divisor = rendition.manager.layout.divisor || 1;
  const regions = [];
  for (const frame of document.querySelectorAll('iframe')) {
    const rect = frame.getBoundingClientRect();
    if (rect.bottom <= 0 || rect.top >= viewportSize.height || rect.right <= 0 || rect.left >= viewportSize.width) continue;
    for (const link of frame.contentDocument?.querySelectorAll('a,button,input,select,textarea') || []) {
      for (const box of link.getClientRects()) regions.push({x:rect.left+box.left,y:rect.top+box.top,width:box.width,height:box.height});
    }
  }
  return {regions,cfi:start.cfi,href:start.href,page:Math.floor(((start.displayed?.page || 1)-1)/divisor),size:{...viewportSize},hostSize:{width:window.innerWidth,height:window.innerHeight},chrome:{...pageChrome}};
};
// An unchanged preview is not proof of a publication boundary: an adjacent
// spine may still be loading. Only classify an end when the known linear
// spine and the reported edge of the current spread both establish it.
function snapshotIsBookBoundary(source, direction, spineItems) {
  const sections = Array.isArray(spineItems) ? spineItems.filter(section => section.linear) : [];
  if (!sections.length || !source?.start || !source?.end) return false;
  if (direction === 'previous') {
    const page = source.start.displayed?.page;
    return source.start.index === sections[0].index && Number.isFinite(page) && page === 1;
  }
  if (direction === 'next') {
    const {page, total} = source.end.displayed || {};
    return source.end.index === sections[sections.length - 1].index && Number.isFinite(page) &&
      Number.isFinite(total) && total > 0 && page >= total;
  }
  return false;
}
async function renderSnapshot(value) {
  setPageChrome(value.origin.chrome || value.preferences.pageChrome || {});
  if (!book) {
    book = ePub(value.url, {openAs:'opf'});
    await withPaginationTimeout(book.ready);
    book.spine.hooks.content.register(sanitizePublication);
    rendition = book.renderTo('reader', {...value.origin.size,manager:'continuous',flow:'paginated',resizeOnOrientationChange:false,allowScriptedContent:false,allowPopups:false});
    await withPaginationTimeout(rendition.started);
    // display is queued behind stage attachment; started alone is earlier.
    await withPaginationTimeout(rendition.display(value.origin.href));
    rendition.manager.viewSettings.forceEvenPages = true;
    navigationTitles = new Map();
    for (const item of flatten((await book.loaded.navigation).toc)) {
      const section = book.spine.get(item.id);
      if (section && !navigationTitles.has(section.index)) navigationTitles.set(section.index,item.title);
    }
  }
  viewportSize = {...value.origin.size};
  setSavedHighlights(value.highlights);
  rendition.resize(viewportSize.width, viewportSize.height);
  const colors = setReaderTheme(rendition, {...value.preferences,scrolling:false});
  document.documentElement.style.setProperty('--reader-paper', colors[0]);
  document.body.style.background = colors[0]; document.body.style.color = colors[1];
  await withPaginationTimeout(rendition.display(value.origin.href));
  let view = rendition.manager.views.find(book.spine.get(value.origin.href));
  await withPaginationTimeout(waitForAssets(view));
  await nextPaint();
  rendition.manager.moveTo({left:value.origin.page * rendition.manager.layout.delta,top:0},view.width());
  await rendition.reportLocation();await nextPaint();
  const source = await rendition.currentLocation();
  if (value.direction === 'next') await rendition.next(); else await rendition.prev();
  await nextPaint();
  for (const view of rendition.manager.views.displayed()) await withPaginationTimeout(waitForAssets(view));
  await rendition.reportLocation();await nextPaint();
  const destination = await rendition.currentLocation();
  updatePageInformation(destination); await nextPaint();
  const exists = destination.start.index !== source.start.index || destination.start.displayed.page !== source.start.displayed.page;
  const boundary = !exists && snapshotIsBookBoundary(source, value.direction, book.spine.spineItems);
  for (const section of book.spine.spineItems) if (section.document && !sectionIsDisplayed(section)) section.unload();
  send('snapshotReady',{request:value.request,direction:value.direction,exists,boundary,cfi:destination.start.cfi,href:destination.start.href,section:destination.start.index,displayed:destination.start.displayed});
}

window.readerCommand = async ({name,value}) => {
  try {
    if (['next', 'previous', 'location', 'seek', 'layoutPage'].includes(name)) {
      cancelVisibilityRestore();
      // Let any uncancellable restore display finish before navigating to the
      // place explicitly chosen by the reader.
      await visibilityTask;
    }
    switch(name) {
      case 'open':
        visibilityAnchor = null; visibilityGeneration++;
        publicationTitle = typeof value.title === 'string' ? value.title.trim().slice(0,1024) : '';
        rebaseResizeAnchor();
        clearInterval(selectionPoll); selectionPoll = undefined; lastPolledSelection = ''; lastSelectionContext = ''; sidebarReadyRequest = null; releaseSidebarHold(); endSidebarLive(); sidebarLayoutHealthy = true;
        invalidatePagination();
        savedHighlights = new Set(); savedHighlightDetails = new Map(); refreshNoteMarkers();
        searchHighlights = new Set();
        selectionObserved = new WeakSet();
        publicationURL = value.url;
        ready = false;
        nativePageTurns = !!value.nativeGestures;
        nativeReflowBridge = value.nativeReflowBridge === true && !nativePageTurns;
        ++reflowSequence;
        send('stage',{label:'Loading publication…'});
        book = ePub(value.url, {openAs:'opf'});
        book.on('openFailed', () => send('error'));
        await book.ready;
        viewportObserver?.disconnect();
        setPageChrome(value.preferences.pageChrome || {});
        const readerElement = document.getElementById('reader');
        const bounds = readerElement.getBoundingClientRect();
        viewportSize = {width:Math.max(1, Math.floor(bounds.width)), height:Math.max(1, Math.floor(bounds.height))};
        // Numeric dimensions disable EPUB.js's window-resize listener. Keyboard
        // focus may resize the window without changing the document's layout box.
        // The continuous manager appends adjacent spine sections as the reader
        // scrolls. Keep it for both flows so mode changes preserve one rendition,
        // its hooks, and exact CFI instead of reverting to single-chapter scrolling.
        rendition = book.renderTo('reader',{...viewportSize,manager:'continuous',resizeOnOrientationChange:false,allowScriptedContent:false,allowPopups:false,flow:value.preferences.scrolling?'scrolled-continuous':'paginated'});
        await rendition.started;
        send('publicationLayout',{fixed:isFixedLayout(rendition)});
        // Start each chapter on a complete spread in wide paginated layouts.
        // Continuous scrolling ignores this horizontal-column setting.
        if (rendition.manager?.viewSettings) rendition.manager.viewSettings.forceEvenPages = true;
        // Strip active and remote content before any chapter is rendered.
        book.spine.hooks.content.register(sanitizePublication);
        rendition.hooks.content.register(contents => {
          for (const event of ['touchmove', 'wheel', 'keydown'])
            contents.document?.addEventListener(event, cancelVisibilityRestore, {capture:true, passive:true});
          observeSelection(contents);
          if (nativePageTurns) return; // iOS recognizes swipes on WKWebView's scroll view.
          let start;
          contents.document.addEventListener('touchstart', e => { if (e.touches.length === 1 && !e.target.closest('a,button,input,select,textarea')) start = {x:e.touches[0].clientX,y:e.touches[0].clientY}; else start = null; }, {passive:true});
          contents.document.addEventListener('touchcancel', () => { start = null; }, {passive:true});
          contents.document.addEventListener('touchend', e => {
            if (!start || scrolling || contents.window.getSelection()?.toString()) return;
            const touch = e.changedTouches[0], dx = touch.clientX-start.x, dy = touch.clientY-start.y;
            start = null;
            if (Math.abs(dx)>60 && Math.abs(dx)>Math.abs(dy)*1.5) {
              const direction = dx<0 ? 'next' : 'previous';
              window.readerCommand({name:direction});
            }
          }, {passive:true});
          // Taps use native recognizers on both platforms. Sandboxed publication
          // frames must never require scripts enabled to navigate or show controls.
        });
        scrolling = !!value.preferences.scrolling;
        preferences(value.preferences);
        send('stage',{label:'Preparing reading positions…'});
        book.locations.pause = 1;
        await book.locations.generate(1024);
        send('stage',{label:'Laying out chapter…'});
        await rendition.display();
        await seek(value);
        ready = true;
        clearInterval(selectionPoll); lastPolledSelection = ''; lastSelectionContext = '';
        selectionPoll = setInterval(pollSelection, 200);
        rendition.on('relocated', reportPosition);
        rendition.on('rendered', refreshChapterBreaks);
        rendition.on('selected', (cfi, contents) => {
          const selection = contents?.window?.getSelection();
          const text = selection?.toString()?.trim();
          if (typeof cfi === 'string' && cfi.startsWith('epubcfi(') && cfi.endsWith(')') && cfi.length <= 8192 && text && text.length <= 16384) {
            observeSelection(contents);
            send('selection',{active:true});
            const context = selection.rangeCount === 1 ? selectionContext(selection.getRangeAt(0),text) : text.slice(0,1024);
            send('selectedText', {cfi, text, context});
          }
        });
        const contents = flatten((await book.loaded.navigation).toc);
        send('toc',{items:contents});
        navigationTitles = new Map();
        for (const item of contents) { const section = book.spine.get(item.id); if (section && !navigationTitles.has(section.index)) navigationTitles.set(section.index, item.title); }
        send('chapters',{items:chapterRanges(contents)});
        refreshChapterBreaks();
        current = rendition.location?.start?.cfi;
        reportPosition(rendition.location);
        viewportObserver = new ResizeObserver(entries => {
          for (const entry of entries) resizeViewport(entry.contentRect);
        });
        viewportObserver.observe(readerElement);
        send('ready');
        requestPagination();
        break;
      case 'gesture': {
        if ((value.action === 'tap' || value.action === 'pointerTap') && document.elementFromPoint?.(value.x,value.y)?.closest?.('.reader-note-marker') && activateAnnotationAt(value.x,value.y)) return;
        if (!insideContent(value.x,value.y)) { if (value.action === 'tap' || value.action === 'pointerTap') send('toggleControls'); return; }
        const frames = Array.from(document.querySelectorAll('iframe'));
        for (const frame of frames) {
          const rect = frame.getBoundingClientRect();
          if (value.x < rect.left || value.x >= rect.right || value.y < rect.top || value.y >= rect.bottom) continue;
          const selection = frame.contentWindow?.getSelection();
          if (selection?.toString()) {
            if (value.action === 'tap') selection.removeAllRanges();
            return;
          }
          const target = frame.contentDocument?.elementFromPoint(value.x - rect.left, value.y - rect.top);
          if (target?.closest('a,button,input,select,textarea')) return;
        }
        if ((value.action === 'tap' || value.action === 'pointerTap') && activateAnnotationAt(value.x,value.y)) return;
        if (value.action === 'pointerTap') send('toggleControls');
        else if (value.action === 'tap') await pageTap(value.x);
        else if (!scrolling && (value.action === 'next' || value.action === 'previous')) {
          if (nativePageTurns) {
            const request = {direction:value.action};
            if (value.queue === true) {
              if (typeof value.queueRequest !== 'string') return;
              request.queue = true; request.queueRequest = value.queueRequest;
            }
            send('swipe',request);
          }
          else await turn(value.action);
        }
        break;
      }
      case 'pageChrome': setPageChrome(value); updatePageInformation(rendition?.location); break;
      case 'snapshot':
        await queueSnapshot(value);
        break;
      case 'nativeTurn':
        if (value.direction === 'next' || value.direction === 'previous') await turn(value.direction, false, value.request);
        break;
      case 'next': await turn('next'); break;
      case 'previous': await turn('previous'); break;
      case 'previewTurn': {
        if (previewAnchor || !ready || scrolling) break;
        previewAnchor = rendition.location?.start?.cfi || current;
        if (!previewAnchor) break;
        previewing = true;
        try { await turn(value, true); }
        catch (error) { previewAnchor = null; previewing = false; throw error; }
        break;
      }
      case 'commitTurn':
        if (previewAnchor) {
          await turnTask;
          previewAnchor = null;
          previewing = false;
          rebaseResizeAnchor();
          reportPosition(rendition.location);
        }
        break;
      case 'cancelTurn':
        if (previewAnchor) {
          await turnTask;
          const anchor = previewAnchor;
          try { await rendition.display(anchor); await nextPaint(); }
          finally {
            previewAnchor = null;
            previewing = false;
            current = resizeAnchor || anchor;
            send('turnCancelled');
          }
        } else send('turnCancelled');
        break;
      case 'commitHighlightSelection': {
        if (typeof value?.request !== 'string' || !/^[0-9a-f-]{36}$/i.test(value.request)) break;
        pollSelection();
        if (lastPolledSelection) {
          const [,cfi,text] = JSON.parse(lastPolledSelection);
          send('highlighterSelectionCommitted',{request:value.request,cfi,text,context:lastSelectionContext});
        }
        break;
      }
      case 'clearSelection': clearChapterSelections(); break;
      case 'savedHighlights': setSavedHighlights(value); send('highlightsUpdated'); break;
      case 'location': await layoutTask; rebaseResizeAnchor(); await displayLocation(value); break;
      case 'annotationLocation': {
        await layoutTask;
        rebaseResizeAnchor();
        const previous = current || rendition.location?.start?.cfi;
        try {
          if (typeof value !== 'string' || !value.startsWith('epubcfi(') || !value.endsWith(')')) throw new Error('Invalid anchor');
          await rendition.display(value);
        } catch (_) {
          if (previous) { try { await rendition.display(previous); } catch (_) {} }
          send('navigationError');
        }
        break;
      }
      case 'seek': await layoutTask; rebaseResizeAnchor(); await seek(value); break;
      case 'layoutPage': await layoutTask; rebaseResizeAnchor(); await seekLayoutPage(value); break;
      case 'preferences': {
        previewPreferences = value;
        // Throttle instead of debounce: a sustained drag keeps updating the
        // book, while serialized layout coalesces edits that arrive mid-reflow.
        if (!preferenceTimer) preferenceTimer = setTimeout(() => {
          preferenceTimer = undefined;
          const p = previewPreferences; previewPreferences = undefined;
          queueLayout(p);
        }, 80);
        break;
      }
      case 'sidebarTransition':
        if (typeof value?.request === 'string' && value.request.length <= 64) {
          if (value.phase === 'begin') {
            if (value.mode === 'live') beginSidebarLive(value.request); else beginSidebarHold(value.request);
          } else if (value.phase === 'end') {
            releaseSidebarHold(value.request); requestSidebarLiveEnd(value.request);
          }
        }
        break;
      case 'searchPresentation': await setSearchPresentation(value); break;
      case 'cancelSearch': ++searchGeneration; break;
      case 'chapterSnippet': await chapterSnippet(value); break;
      case 'search': {
        const generation = ++searchGeneration;
        searchTask = searchTask.then(() => searchPublication(value, generation));
        await searchTask; break;
      }
    }
  } catch (_) { if (name === 'search') send('searchError',{id:value.id}); else if (name !== 'chapterSnippet') send('error'); }
};
send('boot');
