'use strict';
const $=id=>document.getElementById(id);
let state={},editing=false,sequence=0,chain=Promise.resolve(),waiting=new Map();
const post=body=>window.webkit.messageHandlers.app.postMessage(body);
window.receive=(id,result)=>{const resolve=waiting.get(id);if(resolve){waiting.delete(id);resolve(result)}};
function rpc(command){return new Promise(resolve=>{const id=++sequence;waiting.set(id,resolve);post({...command,id})})}
function dispatch(command){const task=chain.then(async()=>{const result=await rpc(command);apply(result,command.action);return result});chain=task.catch(e=>{showError(e.message)});return task}
function showError(message){$('error').hidden=!message;$('errorText').textContent=message||''}
function basename(path){return path.split('/').pop()||path}
function recentButton(path){const b=document.createElement('button');b.className='recent-item';const icon=document.createElement('span');icon.className='file-icon';icon.textContent='▤';const details=document.createElement('span');details.className='details';const name=document.createElement('strong');name.textContent=basename(path);const p=document.createElement('small');p.textContent=path;details.append(name,p);const arrow=document.createElement('span');arrow.className='arrow';arrow.textContent='↗';b.append(icon,details,arrow);b.onclick=()=>{closeDialogs();dispatch({action:'open',path})};return b}
function apply(s,action){const oldPath=state.path;state=s;showError(s.error);document.body.dataset.theme=s.theme||'paper';document.body.dataset.style=s.style||'serif';$('style').value=s.style||'serif';$('footTheme').textContent=(s.theme||'paper').replace(/^./,c=>c.toUpperCase());document.querySelectorAll('[data-theme]').forEach(el=>{if(el.tagName==='BUTTON')el.classList.toggle('selected',el.dataset.theme===s.theme)});
 const changed=oldPath!==s.path;if(changed||['undo','redo','reload'].includes(action))$('editor').value=s.text||'';
 if(changed||(['open','new'].includes(action)&&!s.error))editing=false;
 $('welcome').hidden=!!s.path;$('document').hidden=!s.path;$('filename').textContent=basename(s.path||'');$('location').textContent=s.path?s.path.slice(0,s.path.lastIndexOf('/')):'';
 $('rendered').innerHTML=s.html||'';$('undo').disabled=!s.canUndo;$('redo').disabled=!s.canRedo;
 $('status').innerHTML='<i></i>'+(s.dirty?'Unsaved changes':s.path?'All changes saved':'Ready when you are');
 const words=(s.text||'').trim().split(/\s+/).filter(Boolean).length;$('metrics').textContent=s.path?`${words.toLocaleString()} WORDS  ·  ${Math.max(1,Math.ceil(words/220))} MIN READ`:'MARKDOWN, SIMPLY.';
 $('sidebar').hidden=!s.folder;$('folderName').textContent=basename(s.folder||'');$('files').replaceChildren();for(const path of s.files||[]){const b=document.createElement('button');b.textContent=path.slice(s.folder.length+1);b.title=path;b.classList.toggle('selected',path===s.path);b.onclick=()=>dispatch({action:'open',path});$('files').append(b)}
 $('welcomeRecent').replaceChildren();$('recentList').replaceChildren();for(const [i,path] of (s.recent||[]).entries()){if(i<3)$('welcomeRecent').append(recentButton(path));$('recentList').append(recentButton(path))}if(!s.recent?.length)$('recentList').textContent='Your recently opened files will appear here.';
 post({action:'title',title:s.path?`${basename(s.path)} — Markdown Viewer`:'Markdown Viewer'});view();
}
function view(){ $('rendered').hidden=editing;$('editor').hidden=!editing;$('preview').classList.toggle('active',!editing);$('edit').classList.toggle('active',editing);$('modeLabel').textContent=editing?'EDITING':'READING';if(editing){$('editor').style.height='auto';$('editor').style.height=Math.max(400,$('editor').scrollHeight)+'px'}}
function setMode(value){if(!state.path)return;editing=value;view();if(editing)$('editor').focus()}
function closeDialogs(){document.querySelectorAll('dialog[open]').forEach(d=>d.close())}
async function history(action){if(!state.path)return;$('editor').readOnly=true;try{await dispatch({action})}finally{$('editor').readOnly=false;if(editing)$('editor').focus()}}
window.nativeAction=async command=>{switch(command.action){case 'toggle':setMode(!editing);break;case 'recent':closeDialogs();$('recentPanel').showModal();break;case 'undo':case 'redo':await history(command.action);break;case 'close':{const s=await dispatch({action:'flush'});post({action:'closed',ok:!s.dirty&&!s.error});break}default:await dispatch(command)}};
$('editor').addEventListener('input',()=>{const text=$('editor').value;$('status').textContent='Saving…';dispatch({action:'edit',text});view()});
$('editor').addEventListener('beforeinput',event=>{if(event.inputType==='historyUndo'||event.inputType==='historyRedo'){event.preventDefault();history(event.inputType==='historyUndo'?'undo':'redo')}});
$('open').onclick=$('welcomeOpen').onclick=()=>post({action:'dialogOpen'});$('new').onclick=()=>post({action:'dialogNew'});$('copy').onclick=()=>post({action:'dialogSave'});$('recent').onclick=()=>nativeAction({action:'recent'});$('preview').onclick=()=>setMode(false);$('edit').onclick=()=>setMode(true);$('appearance').onclick=()=>{closeDialogs();$('appearancePanel').showModal()};$('undo').onclick=()=>history('undo');$('redo').onclick=()=>history('redo');$('retry').onclick=()=>dispatch({action:'flush'});$('reload').onclick=()=>{if(confirm('Discard your unsaved changes and reload the file from disk?'))dispatch({action:'reload'})};$('closeFolder').onclick=()=>dispatch({action:'closeFolder'});
$('theme').querySelectorAll('button').forEach(b=>b.onclick=()=>dispatch({action:'settings',theme:b.dataset.theme,style:state.style}));$('style').onchange=()=>dispatch({action:'settings',theme:state.theme,style:$('style').value});document.querySelectorAll('.dismiss').forEach(b=>b.onclick=()=>b.closest('dialog').close());
$('rendered').addEventListener('click',event=>{const a=event.target.closest('a');if(!a)return;const href=a.getAttribute('href');if(href?.startsWith('#')){event.preventDefault();const target=document.getElementById('md-'+decodeURIComponent(href.slice(1)));if(target&&$('rendered').contains(target))target.scrollIntoView({behavior:'smooth'})}else if(href&&!/^(https?:|mailto:)/i.test(href)){event.preventDefault();const base=state.path.slice(0,state.path.lastIndexOf('/')+1);dispatch({action:'open',path:decodeURIComponent(base+href.split('#')[0])})}});
dispatch({action:'state'});
