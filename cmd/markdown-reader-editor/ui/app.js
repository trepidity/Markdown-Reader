'use strict';
const $=id=>document.getElementById(id);
let state={},editing=false,sequence=0,chain=Promise.resolve(),waiting=new Map(),editGeneration=0,refreshPending=false;
const post=body=>window.webkit.messageHandlers.app.postMessage(body);
window.receive=(id,result)=>{const resolve=waiting.get(id);if(resolve){waiting.delete(id);resolve(result)}};
function rpc(command){return new Promise(resolve=>{const id=++sequence;waiting.set(id,resolve);post({...command,id})})}
// Capture the editing boundary synchronously, before any queued RPC runs.
// Accepted inputs are already ahead of the transition in the serial queue.
const editorTransitions=new Set(['open','navigate','navigateLink','new','saveAs','closeDocument','reload','undo','redo']);
let editorLocks=0,closing=false;
function updateEditorLock(){$('editor').readOnly=closing||editorLocks>0}
function dispatch(command){
 const locksEditor=editorTransitions.has(command.action);
 if(locksEditor){editorLocks++;updateEditorLock()}
 const task=chain.then(async()=>{
  const generation=editGeneration;
  const result=await rpc(command);
  if(command.action!=='refresh'||generation===editGeneration)apply(result,command.action);
  return result;
 }).finally(()=>{if(locksEditor){editorLocks--;updateEditorLock()}});
 chain=task.catch(e=>{showError(e.message)});
 return task;
}
async function requestClose(){
 if(closing)return;
 closing=true;updateEditorLock();
 try {
  const result=await dispatch({action:'flush'});
  const ok=!result.dirty&&!result.error;
  if(!ok){closing=false;updateEditorLock()}
  // A successful quit remains locked until termination. A hidden window gets
  // an explicit resume from AppKit only after it is no longer accepting input.
  post({action:'closed',ok});
 }catch(error){closing=false;updateEditorLock();showError(error.message);post({action:'closed',ok:false})}
}
function showError(message){$('error').hidden=!message;$('errorText').textContent=message||''}
function basename(path){return path.split('/').pop()||path}
function recentButton(path){const b=document.createElement('button');b.className='recent-item';const icon=document.createElement('span');icon.className='file-icon';icon.textContent='▤';const details=document.createElement('span');details.className='details';const name=document.createElement('strong');name.textContent=basename(path);const p=document.createElement('small');p.textContent=path;details.append(name,p);const arrow=document.createElement('span');arrow.className='arrow';arrow.textContent='↗';b.append(icon,details,arrow);b.onclick=()=>{closeDialogs();dispatch({action:'open',path})};return b}
function apply(s,action){if(action==='search'||s.unchanged)return;const live=action==='refresh';if(live&&!s.reloadedPaths?.includes(state.path)){state.watchError=s.watchError;showError(state.error||s.watchError);if($('searchPanel').open)scheduleSearch();return}const main=document.querySelector('main'),scroll=main.scrollTop,sideScroll=$('sidebar').scrollTop,start=$('editor').selectionStart,end=$('editor').selectionEnd;if(action==='sidebarWidth'){state.sidebarWidth=s.sidebarWidth;if(s.error)showError(s.error);if(!sidebarDrag)resizeSidebar(s.sidebarWidth);return}const oldPath=state.path;state=s;showError(s.error||s.watchError);document.body.dataset.theme=s.theme||'paper';document.body.dataset.style=s.style||'serif';$('style').value=s.style||'serif';$('footTheme').textContent=(s.theme||'paper').replace(/^./,c=>c.toUpperCase());document.querySelectorAll('[data-theme]').forEach(el=>{if(el.tagName==='BUTTON'){const selected=el.dataset.theme===s.theme;el.classList.toggle('selected',selected);el.setAttribute('aria-pressed',String(selected))}});
 const changed=oldPath!==s.path;if(changed||live||['undo','redo','reload'].includes(action))$('editor').value=s.text||'';
 if(changed||(['open','navigate','navigateLink','new'].includes(action)&&!s.error))editing=false;
 $('welcome').hidden=!!s.path;$('document').hidden=!s.path;$('filename').textContent=basename(s.path||'');$('location').textContent=s.path?s.path.slice(0,s.path.lastIndexOf('/')):'';
 $('rendered').innerHTML=s.html||'';$('undo').disabled=!s.canUndo;$('redo').disabled=!s.canRedo;
 $('status').innerHTML='<i></i>'+(s.dirty?'Unsaved changes':s.path?'All changes saved':'Ready when you are');
 const words=(s.text||'').trim().split(/\s+/).filter(Boolean).length;$('metrics').textContent=s.path?`${words.toLocaleString()} WORDS  ·  ${Math.max(1,Math.ceil(words/220))} MIN READ`:'MARKDOWN, SIMPLY.';
 $('sidebar').hidden=!s.folder;$('sidebarDivider').hidden=!s.folder;if(!sidebarDrag)resizeSidebar(s.sidebarWidth);$('folderName').textContent=basename(s.folder||'');updateSidebarFiles(s);
 $('welcomeRecent').replaceChildren();$('recentList').replaceChildren();for(const [i,path] of (s.recent||[]).entries()){if(i<3)$('welcomeRecent').append(recentButton(path));$('recentList').append(recentButton(path))}if(!s.recent?.length)$('recentList').textContent='Your recently opened files will appear here.';
 updateOpenDocuments();if(!$('searchPanel').hidden&&!searchNavigating)scheduleSearch();
 post({action:'title',title:s.path?`${basename(s.path)} — Markdown Reader`:'Markdown Reader'});view();if(live){$('editor').setSelectionRange(start,end);main.scrollTop=scroll;$('sidebar').scrollTop=sideScroll;}
}
function updateSidebarFiles(s){
 const list=$('files'),paths=s.files||[];
 const focusedPath=list.contains(document.activeElement)?document.activeElement.dataset.path:null;
 if(list.children.length!==paths.length||paths.some((path,index)=>list.children[index].dataset.path!==path)){
  list.replaceChildren();
  for(const path of paths){
   const button=document.createElement('button');button.dataset.path=path;
   button.textContent=path.slice(s.folder.length+1);button.title=path;
   button.onclick=()=>dispatch({action:'navigate',path});list.append(button);
  }
  if(focusedPath){const replacement=Array.from(list.children).find(b=>b.dataset.path===focusedPath);(replacement||(s.folder?$('closeFolder'):$('open'))).focus()}
 }
 for(const button of list.children){const selected=button.dataset.path===s.path;button.classList.toggle('selected',selected);if(selected)button.setAttribute('aria-current','page');else button.removeAttribute('aria-current')}
}
function view(){ $('rendered').hidden=editing;$('editor').hidden=!editing;$('preview').classList.toggle('active',!editing);$('edit').classList.toggle('active',editing);$('preview').setAttribute('aria-pressed',String(!editing));$('edit').setAttribute('aria-pressed',String(editing));$('modeLabel').textContent=editing?'EDITING':'READING';if(editing){$('editor').style.height='auto';$('editor').style.height=Math.max(400,$('editor').scrollHeight)+'px'}}
function setMode(value){if(!state.path)return;editing=value;view();if(!editing&&!$('searchPanel').hidden)highlightPreview();if(editing)$('editor').focus()}
function closeDialogs(){document.querySelectorAll('dialog[open]').forEach(d=>{if(d.id==='searchPanel')closeSearch();else d.close()})}
async function history(action){if($('searchPanel').open){if(document.activeElement===$('searchQuery'))document.execCommand(action);return}if(!state.path)return;try{await dispatch({action})}finally{if(editing)$('editor').focus()}}
window.nativeAction=async command=>{switch(command.action){case 'refresh':if(refreshPending||!state.openDocuments?.length)return;refreshPending=true;try{await dispatch(command)}finally{refreshPending=false}break;case 'find':openSearch('current');break;case 'findAll':openSearch(state.folder?'folder':'open');break;case 'findNext':await navigateMatch(1);break;case 'findPrevious':await navigateMatch(-1);break;case 'toggle':setMode(!editing);break;case 'recent':closeDialogs();$('recentPanel').showModal();break;case 'undo':case 'redo':await history(command.action);break;case 'close':await requestClose();break;case 'resume':closing=false;updateEditorLock();break;default:await dispatch(command)}};
$('editor').addEventListener('input',()=>{editGeneration++;const text=$('editor').value;$('status').textContent='Saving…';dispatch({action:'edit',text,path:state.path,revision:state.revision});view()});
$('editor').addEventListener('beforeinput',event=>{if(event.inputType==='historyUndo'||event.inputType==='historyRedo'){event.preventDefault();history(event.inputType==='historyUndo'?'undo':'redo')}});
$('open').onclick=$('welcomeOpen').onclick=()=>post({action:'dialogOpen'});$('new').onclick=()=>post({action:'dialogNew'});$('copy').onclick=()=>post({action:'dialogSave'});$('recent').onclick=()=>nativeAction({action:'recent'});$('preview').onclick=()=>setMode(false);$('edit').onclick=()=>setMode(true);$('appearance').onclick=()=>{closeDialogs();$('appearancePanel').showModal()};$('undo').onclick=()=>history('undo');$('redo').onclick=()=>history('redo');$('retry').onclick=()=>dispatch({action:'flush'});$('reload').onclick=()=>{if(confirm('Discard your unsaved changes and reload the file from disk?'))dispatch({action:'reload'})};$('closeFolder').onclick=()=>dispatch({action:'closeFolder'});
$('theme').querySelectorAll('button').forEach(b=>b.onclick=()=>dispatch({action:'settings',theme:b.dataset.theme,style:state.style}));$('style').onchange=()=>dispatch({action:'settings',theme:state.theme,style:$('style').value});document.querySelectorAll('.dismiss').forEach(b=>b.onclick=()=>b.closest('dialog').close());
$('rendered').addEventListener('click',event=>{const a=event.target.closest('a');if(!a)return;const href=a.getAttribute('href');if(href?.startsWith('#')){event.preventDefault();const target=document.getElementById('md-'+decodeURIComponent(href.slice(1)));if(target&&$('rendered').contains(target))target.scrollIntoView({behavior:'smooth'})}else if(href&&!/^(https?:|mailto:)/i.test(href)){event.preventDefault();dispatch({action:'navigateLink',path:state.path,href})}});
const divider=$('sidebarDivider');
let sidebarDrag=null;
function sidebarMax(){return Math.max(160,Math.min(600,document.querySelector('.workspace').clientWidth-367))}
function resizeSidebar(width){
 const max=sidebarMax();const actual=Math.max(160,Math.min(max,Math.round(width||235)));
 document.body.style.setProperty('--sidebar-width',actual+'px');
 divider.setAttribute('aria-valuemax',String(max));divider.setAttribute('aria-valuenow',String(actual));
 return actual;
}
function saveSidebarWidth(width){dispatch({action:'sidebarWidth',sidebarWidth:width})}
divider.addEventListener('pointerdown',event=>{
 if(event.button!==0||sidebarDrag)return;
 event.preventDefault();divider.focus();
 sidebarDrag={id:event.pointerId,start:Number(divider.getAttribute('aria-valuenow')),offset:event.clientX-$('sidebar').getBoundingClientRect().right};
 divider.setPointerCapture(event.pointerId);document.body.classList.add('resizing-sidebar');
});
divider.addEventListener('pointermove',event=>{
 if(sidebarDrag?.id===event.pointerId)resizeSidebar(event.clientX-$('sidebar').getBoundingClientRect().left-sidebarDrag.offset);
});
function endSidebarDrag(event,cancel){
 if(sidebarDrag?.id!==event.pointerId)return;
 const width=cancel?sidebarDrag.start:Number(divider.getAttribute('aria-valuenow'));
 sidebarDrag=null;document.body.classList.remove('resizing-sidebar');
 if(divider.hasPointerCapture(event.pointerId))divider.releasePointerCapture(event.pointerId);
 resizeSidebar(width);if(!cancel)saveSidebarWidth(width);
}
divider.addEventListener('pointerup',event=>endSidebarDrag(event,false));
divider.addEventListener('pointercancel',event=>endSidebarDrag(event,true));
divider.addEventListener('lostpointercapture',event=>endSidebarDrag(event,true));
divider.addEventListener('dblclick',()=>saveSidebarWidth(resizeSidebar(235)));
divider.addEventListener('keydown',event=>{
 const current=Number(divider.getAttribute('aria-valuenow'));
 const widths={ArrowLeft:current-16,ArrowRight:current+16,Home:160,End:sidebarMax()};
 if(!(event.key in widths))return;
 event.preventDefault();saveSidebarWidth(resizeSidebar(widths[event.key]));
});
window.addEventListener('resize',()=>{resizeSidebar(sidebarDrag?Number(divider.getAttribute('aria-valuenow')):state.sidebarWidth);if(editing)view()});
let searchTimer=null,searchGeneration=0,searchMatches=[],selectedMatch=-1,lastSearch=null,searchNavigating=false;
let searchGroups=[],selectedFile=-1,searchReturnFocus=null;
function updateOpenDocuments(){
 const menu=$('openDocuments');menu.replaceChildren();
 for(const path of state.openDocuments||[]){const option=document.createElement('option');option.value=path;option.textContent=basename(path);option.title=path;menu.append(option)}
 menu.value=state.path||'';menu.hidden=(state.openDocuments||[]).length<2;
 const options=$('searchScope').options;options[0].disabled=!state.path;options[1].textContent=`Open documents (${(state.openDocuments||[]).length})`;options[2].disabled=!state.folder;
}
function openSearch(scope){
 const panel=$('searchPanel');
 if(!panel.open){searchReturnFocus=document.activeElement;closeDialogs();panel.hidden=false;panel.showModal()}
 $('searchScope').value=scope;
 $('searchQuery').placeholder=scope==='current'?'Find in document…':scope==='folder'?'Find in folder…':'Find in open documents…';
 $('searchQuery').focus();$('searchQuery').select();scheduleSearch();
}
function clearHighlights(){
 for(const mark of $('rendered').querySelectorAll('mark.find-highlight')){const parent=mark.parentNode;mark.replaceWith(document.createTextNode(mark.textContent));parent.normalize()}
}
function hideSearch(){clearTimeout(searchTimer);$('searchPanel').close();$('searchPanel').hidden=true}
function closeSearch(){
 searchGeneration++;hideSearch();clearHighlights();
 if(searchReturnFocus?.isConnected)searchReturnFocus.focus();else if(editing)$('editor').focus();else $('find').focus();
}
function emptyResults(message){
 searchMatches=[];searchGroups=[];selectedMatch=-1;selectedFile=-1;
 $('searchFiles').replaceChildren();$('searchResults').replaceChildren();
 const empty=document.createElement('p');empty.className='search-empty';empty.textContent=message;$('searchResults').append(empty);
 $('searchFileCount').textContent='FILES';$('searchMatchTitle').textContent='MATCHES & CONTEXT';
 $('nextMatch').disabled=$('previousMatch').disabled=$('openMatch').disabled=true;
}
function scheduleSearch(){
 clearTimeout(searchTimer);searchGeneration++;emptyResults('Matching text and surrounding lines will appear here.');$('searchWarnings').hidden=true;clearHighlights();
 if($('searchPanel').open){$('searchStatus').textContent=$('searchQuery').value?'Searching…':'Type to find text.';searchTimer=setTimeout(runSearch,200)}
}
async function runSearch(){
 clearTimeout(searchTimer);const generation=++searchGeneration;
 const command={action:'search',query:$('searchQuery').value,scope:$('searchScope').value,matchCase:$('searchCase').checked};
 if(!command.query){lastSearch=null;emptyResults('Type to search your documents.');$('searchStatus').textContent='Type to find text.';$('searchWarnings').hidden=true;return}
 emptyResults('Searching…');$('searchStatus').textContent='Searching…';
 const response=await dispatch(command);if(generation!==searchGeneration||!$('searchPanel').open)return;
 lastSearch=command;
 if(response.error){emptyResults('Try another scope or open a document.');$('searchStatus').textContent=response.error;return}
 searchMatches=response.search?.matches||[];
 const groups=new Map();for(const [index,match] of searchMatches.entries()){if(!groups.has(match.path))groups.set(match.path,[]);groups.get(match.path).push(index)}
 searchGroups=Array.from(groups,([path,indices])=>({path,indices}));
 const files=searchGroups.length;
 $('searchStatus').textContent=`${searchMatches.length}${response.search.truncated?'+':''} ${searchMatches.length===1?'match':'matches'} in ${files} ${files===1?'file':'files'}${response.search.truncated?' · Limit reached; narrow your search':''}`;
 const warnings=response.search.warnings||[];$('searchWarnings').hidden=!warnings.length;$('searchWarnings').textContent=warnings.join('\n');
 $('searchFiles').replaceChildren();$('searchFileCount').textContent=`FILES (${files})`;
 for(const [index,group] of searchGroups.entries()){
  const button=document.createElement('button');button.className='search-file';button.type='button';button.dataset.fileIndex=index;button.setAttribute('role','option');button.tabIndex=-1;button.title=group.path;
  const name=document.createElement('strong');name.textContent=basename(group.path);
  const path=document.createElement('small');path.textContent=state.folder&&group.path.startsWith(state.folder+'/')?group.path.slice(state.folder.length+1):group.path;
  const count=document.createElement('span');count.className='match-count';count.textContent=group.indices.length;
  button.append(name,path,count);button.onclick=()=>selectFile(index,true);$('searchFiles').append(button);
 }
 if(files){selectFile(0,false)}else{emptyResults('No matches. Try different text, a broader scope, or turn off Match case.')}
 $('nextMatch').disabled=$('previousMatch').disabled=$('openMatch').disabled=!searchMatches.length;
}
function selectFile(index,focus){
 if(!searchGroups.length)return;selectedFile=Math.max(0,Math.min(searchGroups.length-1,index));
 const group=searchGroups[selectedFile];
 Array.from($('searchFiles').children).forEach((el,i)=>{el.classList.toggle('selected',i===selectedFile);el.setAttribute('aria-selected',String(i===selectedFile));el.tabIndex=i===selectedFile?0:-1});
 const active=$('searchFiles').children[selectedFile];active.scrollIntoView({block:'nearest'});if(focus)active.focus();
 $('searchMatchTitle').textContent=`${basename(group.path)} · ${group.indices.length} ${group.indices.length===1?'MATCH':'MATCHES'}`;$('searchMatchTitle').title=group.path;
 $('searchResults').replaceChildren();
 for(const index of group.indices){
  const match=searchMatches[index];const button=document.createElement('button');button.type='button';button.className='search-result';button.dataset.matchIndex=index;button.setAttribute('role','option');button.tabIndex=-1;
  const position=document.createElement('strong');position.textContent=`Line ${match.line} · Column ${match.column}`;
  const context=document.createElement('pre');
  if(match.before?.length){const before=document.createElement('span');before.className='match-context';before.textContent=match.before.join('\n')+'\n';context.append(before)}
  context.append(document.createTextNode(match.snippet.slice(0,match.snippetStart)));
  const mark=document.createElement('mark');mark.textContent=match.snippet.slice(match.snippetStart,match.snippetEnd);context.append(mark,document.createTextNode(match.snippet.slice(match.snippetEnd)));
  if(match.after?.length){const after=document.createElement('span');after.className='match-context';after.textContent='\n'+match.after.join('\n');context.append(after)}
  button.append(position,context);button.onclick=()=>selectMatch(index,true);button.ondblclick=()=>revealMatch(index);$('searchResults').append(button);
 }
 selectMatch(group.indices[0],false);
}
function selectMatch(index,focus){
 if(!searchMatches[index])return;selectedMatch=index;
 for(const button of $('searchResults').children){const active=Number(button.dataset.matchIndex)===index;button.classList.toggle('selected',active);button.setAttribute('aria-selected',String(active));button.tabIndex=active?0:-1;if(active){button.scrollIntoView({block:'nearest'});if(focus)button.focus()}}
}
function focusFiles(){if(selectedFile>=0)$('searchFiles').children[selectedFile]?.focus()}
function focusMatches(){if(selectedMatch>=0)selectMatch(selectedMatch,true)}
function highlightPreview(){
 clearHighlights();if(!lastSearch?.query||editing)return [];
 const escaped=lastSearch.query.replace(/[.*+?^${}()|[\]\\]/g,'\\$&');
 let expression;try{expression=new RegExp(escaped,lastSearch.matchCase?'gu':'giu')}catch{return []}
 const walker=document.createTreeWalker($('rendered'),NodeFilter.SHOW_TEXT);const nodes=[];while(walker.nextNode())nodes.push(walker.currentNode);
 let count=0;for(const node of nodes){if(count>=1000)break;const text=node.textContent;expression.lastIndex=0;let match,offset=0;const fragment=document.createDocumentFragment();let found=false;
 while(count<1000&&(match=expression.exec(text))){found=true;fragment.append(document.createTextNode(text.slice(offset,match.index)));const mark=document.createElement('mark');mark.className='find-highlight';mark.textContent=match[0];fragment.append(mark);offset=match.index+match[0].length;count++}
 if(found){fragment.append(document.createTextNode(text.slice(offset)));node.replaceWith(fragment)}
 }
 return Array.from($('rendered').querySelectorAll('mark.find-highlight'));
}
async function revealMatch(index){
 const match=searchMatches[index];if(!match)return;
 const generation=searchGeneration;const query=lastSearch;searchNavigating=true;
 try {
  if(match.path!==state.path){const s=await dispatch({action:'navigate',path:match.path});if(s.error||s.path!==match.path){$('searchStatus').textContent=s.error||'Unable to open document.';return}}
  if(generation!==searchGeneration)return;
  if(state.text.slice(match.start,match.end)!==match.text){if(!$('searchPanel').open)openSearch(query.scope);await runSearch();$('searchStatus').textContent='Document changed; results refreshed. Select the match again.';return}
  selectedMatch=index;hideSearch();lastSearch=query;
  const localMatches=searchMatches.filter(m=>m.path===state.path);const ordinal=localMatches.indexOf(match);const marks=highlightPreview();
  if(!editing&&marks.length===localMatches.length&&marks[ordinal]){marks[ordinal].classList.add('active');marks[ordinal].scrollIntoView({block:'center',behavior:'smooth'});$('preview').focus({preventScroll:true})}
  else {setMode(true);const editor=$('editor');const selectionStart=state.text.slice(0,match.start).replace(/\r\n?/g,'\n').length;const selectionEnd=state.text.slice(0,match.end).replace(/\r\n?/g,'\n').length;editor.setSelectionRange(selectionStart,selectionEnd);const lineHeight=parseFloat(getComputedStyle(editor).lineHeight);const main=document.querySelector('main');main.scrollTop=Math.max(0,editor.offsetTop-main.offsetTop+(match.line-1)*lineHeight-main.clientHeight/2)}
 }finally{searchNavigating=false}
}
async function navigateMatch(direction){
 if($('searchPanel').open){const group=searchGroups[selectedFile];if(!group)return;const current=group.indices.indexOf(selectedMatch);const next=(current+direction+group.indices.length)%group.indices.length;selectMatch(group.indices[next],true);return}
 if(!searchMatches.length){openSearch('current');return}
 const index=(selectedMatch+direction+searchMatches.length)%searchMatches.length;await revealMatch(index);
}
$('searchPanel').addEventListener('cancel',event=>{event.preventDefault();closeSearch()});
$('searchPanel').addEventListener('keydown',event=>{
 if(event.key==='Escape'){event.preventDefault();closeSearch();return}
 const inFiles=event.target.closest('#searchFiles');const inMatches=event.target.closest('#searchResults');
 if(event.target===$('searchQuery')&&event.key==='ArrowDown'){event.preventDefault();focusFiles();return}
 if(!inFiles&&!inMatches)return;
 if(event.key==='ArrowRight'){event.preventDefault();focusMatches();return}
 if(event.key==='ArrowLeft'){event.preventDefault();focusFiles();return}
 if(event.key==='Enter'){event.preventDefault();if(inFiles)focusMatches();else revealMatch(selectedMatch);return}
 if(!['ArrowDown','ArrowUp','Home','End','PageDown','PageUp'].includes(event.key))return;
 event.preventDefault();const direction={ArrowDown:1,ArrowUp:-1,PageDown:5,PageUp:-5}[event.key]||0;
 if(inFiles){selectFile(event.key==='Home'?0:event.key==='End'?searchGroups.length-1:selectedFile+direction,true)}
 else {const indices=searchGroups[selectedFile].indices;const current=indices.indexOf(selectedMatch);const next=event.key==='Home'?0:event.key==='End'?indices.length-1:Math.max(0,Math.min(indices.length-1,current+direction));selectMatch(indices[next],true)}
});
$('find').onclick=()=>openSearch('current');$('closeSearch').onclick=closeSearch;
$('searchQuery').oninput=scheduleSearch;$('searchCase').onchange=scheduleSearch;$('searchScope').onchange=()=>openSearch($('searchScope').value);
$('searchForm').onsubmit=async event=>{event.preventDefault();await runSearch();if($('searchPanel').open)focusFiles()};
$('openMatch').onclick=()=>revealMatch(selectedMatch);$('nextMatch').onclick=()=>navigateMatch(1);$('previousMatch').onclick=()=>navigateMatch(-1);
$('openDocuments').onchange=()=>dispatch({action:'navigate',path:$('openDocuments').value});$('closeDocument').onclick=()=>dispatch({action:'closeDocument'});
dispatch({action:'state'});
