'use strict';
let book, rendition, current, ready = false, searchGeneration = 0, scrolling = false, preferenceTimer, restoring = false, pageTransition = 'slide', nativePageTurns = false, pageTapZoneFraction = 0.2;
let sectionLocationCounts = new Map(), observedSectionPages = new Map();
const chapterSnippetCache = new Map();
const send = (kind, value = {}) => window.webkit.messageHandlers.reader.postMessage({kind, ...value});
function preferences(p) {
  if (!rendition) return;
  scrolling = p.scrolling;
  pageTapZoneFraction = Number.isFinite(p.pageTapZoneFraction) ? Math.min(0.3, Math.max(0.1, p.pageTapZoneFraction)) : 0.2;
  pageTransition = ['instant','fade','slide'].includes(p.pageTransition) ? p.pageTransition : 'slide';
  const themes = {light:['#ffffff','#202020'],sepia:['#f4ecd8','#342c20'],dark:['#171717','#dedede']};
  const colors = themes[p.theme] || themes.light;
  document.body.style.background = colors[0];
  rendition.themes.default({'body':{'color':colors[1]+' !important','background':colors[0]+' !important','font-family':p.font+' !important','font-size':p.fontSize+'px !important','line-height':p.lineHeight+' !important','padding-top':'0 !important','padding-bottom':'0 !important','margin-top':'0 !important','margin-bottom':'0 !important','padding-left':p.margin+'px !important','padding-right':p.margin+'px !important'},'a':{'color':'inherit'}});
  rendition.flow(p.scrolling ? 'scrolled-doc' : 'paginated');
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
let viewportSize, viewportObserver, searchPresentation = false;
function setSearchPresentation(active) {
  searchPresentation = !!active;
  const element = document.getElementById('reader');
  if (!element || !viewportSize) return;
  // A native text field's software keyboard changes WebKit's layout viewport,
  // even when SwiftUI ignores its safe area. Keep the hidden document's box
  // fixed until UIKit reports that the keyboard finished hiding.
  element.style.width = active ? viewportSize.width + 'px' : '';
  element.style.height = active ? viewportSize.height + 'px' : '';
}
function resizeViewport(size) {
  const next = {width:Math.floor(size.width), height:Math.floor(size.height)};
  if (searchPresentation || next.width <= 0 || next.height <= 0 || !rendition) return;
  if (viewportSize?.width === next.width && viewportSize?.height === next.height) return;
  viewportSize = next;
  observedSectionPages.clear();
  // EPUB.js already restores the CFI when resize changes the stage. Do not
  // redisplay that boundary CFI a second time; it can map to the preceding page.
  rendition.resize(next.width, next.height);
}
function queueLayout(p, resize = false) {
  if (p || resize) observedSectionPages.clear();
  if (p) pendingPreferences = p;
  pendingResize = pendingResize || resize;
  if (layoutTask) return layoutTask;
  layoutTask = Promise.resolve().then(async () => {
    restoring = true;
    try {
      while (pendingPreferences || pendingResize) {
        const p = pendingPreferences;
        pendingPreferences = undefined; pendingResize = false;
        const anchor = current || rendition.location?.start?.cfi;
        if (p) preferences(p);
        if (anchor) { await rendition.display(anchor); }
      }
    } catch (_) { send('error'); }
    finally {
      restoring = false; layoutTask = undefined;
      if (book?.locations && rendition.location?.start?.cfi) reportPosition(rendition.location);
    }
  });
  return layoutTask;
}
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
    start,
    end: position + 1 < chapters.length ? chapters[position + 1][1] : 1
  }));
}
function estimatedBookPages(location) {
  const section = book.spine.get(location.start.cfi);
  const sectionLocations = sectionLocationCounts.get(section?.index) || 0;
  const displayedPages = location.start.displayed?.total || 0;
  if (!scrolling && sectionLocations >= 1 && displayedPages >= 1) {
    observedSectionPages.set(section.index, displayedPages);
  }
  let locations = 0, pages = 0;
  for (const [index, count] of sectionLocationCounts) {
    const observed = observedSectionPages.get(index);
    if (observed) { locations += count; pages += observed; }
  }
  if (!locations) return 0;
  return Math.max(displayedPages, Math.round(book.locations.length() * pages / locations));
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
async function seek(value) {
  if (value.cfi) { try { await rendition.display(value.cfi); return; } catch (_) {} }
  await rendition.display(book.locations.cfiFromPercentage(Math.min(1,Math.max(0,value.fraction || 0))));
}
async function displayLocation(target) {
  const previous = current || rendition.location?.start?.cfi;
  try {
    await rendition.display(target);
    if (target.startsWith('epubcfi(')) {
      try { rendition.annotations.highlight(target, {}, null, 'search-match', {fill:'#e6b84a','fill-opacity':'0.35'}); }
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
let turnTask = Promise.resolve(), previewAnchor = null, previewing = false;
function clearChapterSelections() {
  for (const frame of document.querySelectorAll('iframe')) frame.contentWindow?.getSelection()?.removeAllRanges();
}
window.readerCanTurn = (x, y) => {
  if (!ready || scrolling || previewing) return false;
  for (const frame of document.querySelectorAll('iframe')) {
    const rect = frame.getBoundingClientRect();
    if (x < rect.left || x >= rect.right || y < rect.top || y >= rect.bottom) continue;
    if (frame.contentWindow?.getSelection()?.toString()) return false;
    const target = frame.contentDocument?.elementFromPoint(x - rect.left, y - rect.top);
    if (target?.closest('a,button,input,select,textarea')) return false;
  }
  return true;
};
const nextPaint = () => new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve)));
function turn(direction, preview = false) {
  // WebKit captures both rendered pages; EPUB.js only advances once between snapshots.
  // Keep the next gesture queued until both surfaces have finished moving.
  turnTask = turnTask.catch(() => {}).then(async () => {
    await layoutTask;
    if (scrolling) return;
    const advance = () => direction === 'next' ? rendition.next() : rendition.prev();
    if (nativePageTurns || pageTransition === 'instant' || window.matchMedia?.('(prefers-reduced-motion: reduce)').matches || typeof document.startViewTransition !== 'function') {
      await advance();
      clearChapterSelections();
      if (nativePageTurns) {
        // EPUB.js can settle its relocation promise before WebKit paints the
        // new frame. The native incoming snapshot must see that new frame.
        await nextPaint();
        send(preview ? 'previewReady' : 'turned',{direction});
      }
      return;
    }
    document.documentElement.dataset.pageTurn = direction;
    document.documentElement.dataset.pageStyle = pageTransition;
    try { await document.startViewTransition(advance).finished; }
    finally { delete document.documentElement.dataset.pageTurn; delete document.documentElement.dataset.pageStyle; }
  });
  return turnTask;
}
function reportPosition(location) {
  if (restoring || previewing || !location?.start?.cfi) return;
  current = location.start.cfi;
  const displayed = location.start.displayed || {};
  send('position',{cfi:current,href:location.start.href,fraction:book.locations.percentageFromCfi(current),chapterPage:displayed.page || 0,chapterPageCount:displayed.total || 0,bookPageEstimate:estimatedBookPages(location)});
}
window.readerCommand = async ({name,value}) => {
  try {
    switch(name) {
      case 'open':
        nativePageTurns = !!value.nativeGestures;
        send('stage',{label:'Loading publication…'});
        book = ePub(value.url, {openAs:'opf'});
        book.on('openFailed', () => send('error'));
        await book.ready;
        viewportObserver?.disconnect();
        const readerElement = document.getElementById('reader');
        const bounds = readerElement.getBoundingClientRect();
        viewportSize = {width:Math.max(1, Math.floor(bounds.width)), height:Math.max(1, Math.floor(bounds.height))};
        // Numeric dimensions disable EPUB.js's window-resize listener. Keyboard
        // focus may resize the window without changing the document's layout box.
        rendition = book.renderTo('reader',{...viewportSize,resizeOnOrientationChange:false,allowScriptedContent:false,allowPopups:false,flow:value.preferences.scrolling?'scrolled-doc':'paginated'});
        // Strip active and remote content before any chapter is rendered.
        book.spine.hooks.content.register((document) => {
          document.querySelectorAll('script,object,embed,iframe,form,base').forEach(node => node.remove());
          document.querySelectorAll('*').forEach(node => Array.from(node.attributes).forEach(attr => {
            if (/^on/i.test(attr.name) || ((/^(src|href|xlink:href|poster|action)$/i).test(attr.name) && /^(https?:|\/\/|javascript:)/i.test(attr.value))) node.removeAttribute(attr.name);
          }));
        });
        rendition.hooks.content.register(contents => {
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
        preferences(value.preferences);
        send('stage',{label:'Preparing reading positions…'});
        book.locations.pause = 1;
        await book.locations.generate(1024);
        send('stage',{label:'Laying out chapter…'});
        await rendition.display();
        await seek(value);
        ready = true;
        rendition.on('relocated', reportPosition);
        const contents = flatten((await book.loaded.navigation).toc);
        send('toc',{items:contents});
        send('chapters',{items:chapterRanges(contents)});
        current = rendition.location?.start?.cfi;
        reportPosition(rendition.location);
        viewportObserver = new ResizeObserver(entries => {
          for (const entry of entries) resizeViewport(entry.contentRect);
        });
        viewportObserver.observe(readerElement);
        send('ready');
        break;
      case 'gesture': {
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
        if (value.action === 'tap') await pageTap(value.x);
        else if (!scrolling && (value.action === 'next' || value.action === 'previous')) {
          if (nativePageTurns) send('swipe',{direction:value.action});
          else await turn(value.action);
        }
        break;
      }
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
            current = anchor;
            send('turnCancelled');
          }
        } else send('turnCancelled');
        break;
      case 'clearSelection': clearChapterSelections(); break;
      case 'location': await layoutTask; await displayLocation(value); break;
      case 'seek': await layoutTask; await seek(value); break;
      case 'preferences': {
        clearTimeout(preferenceTimer);
        preferenceTimer = setTimeout(() => queueLayout(value), 180);
        break;
      }
      case 'searchPresentation': setSearchPresentation(value); break;
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
