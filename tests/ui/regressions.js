// L1 IPC ordering tests run against the actual UI in WebKit. Bridge replies are
// deliberately controlled; Go/disk behavior is covered separately by app tests.
(async()=>{
 const failures=[],passed=[];
 const check=(condition,message)=>{if(!condition)failures.push(message)};
 const incoming=[],consumers=[];
 window.testBridgeReceive=message=>{
  if(message.action==='title')return;
  if(consumers.length)consumers.shift()(message);else incoming.push(message);
 };
 const next=()=>incoming.length?Promise.resolve(incoming.shift()):new Promise(resolve=>consumers.push(resolve));
 const drain=async()=>{for(let i=0;i<8;i++)await Promise.resolve()};
 const reply=async(command,s)=>{window.receive(command.id,s);await drain()};
 const base={path:'/fixtures/100%/source.md',text:'# Original',html:'<h1>Original</h1>',revision:1,theme:'paper',style:'serif',sidebarWidth:235,folder:'/fixtures/100%',files:['/fixtures/100%/source.md','/fixtures/100%/other.md'],openDocuments:['/fixtures/100%/source.md'],recent:[],dirty:false,error:'',canUndo:false,canRedo:false};
 const other={...base,path:'/fixtures/100%/other.md',text:'# Other',html:'<h1>Other</h1>'};
 async function reset(){
  const work=window.nativeAction({action:'open',path:base.path});
  const request=await next();check(request.action==='open','reset must open fixture');await reply(request,base);await work;
 }
 try {
  const startup=await next();check(startup.action==='state','UI must request initial state');await reply(startup,base);
  $('edit').click();$('editor').value='# Accepted draft';$('editor').dispatchEvent(new Event('input'));
  const navigation=window.nativeAction({action:'navigate',path:other.path});
  check($('editor').readOnly,'navigation must lock editor synchronously, before the edit acknowledgement');
  const edit=await next();check(edit.action==='edit'&&edit.text==='# Accepted draft','accepted draft must precede navigation on the bridge');
  await reply(edit,{...base,text:'# Accepted draft',html:'<h1>Accepted draft</h1>'});
  const move=await next();check(move.action==='navigate','navigation must follow accepted edit');
  check($('editor').readOnly,'editor must remain locked while navigation is awaiting its reply');
  $('editor').focus();document.execCommand('insertText',false,'Late input');
  check($('editor').value==='# Accepted draft','WebKit must refuse typing while the navigation reply is pending');
  await reply(move,other);await navigation;
  check(!$('editor').readOnly&&$('editor').value==='# Other','successful navigation must release editor on the new document');
  passed.push('navigation drains accepted edits before switching');

  await reset();$('edit').click();$('editor').value='Retained draft';$('editor').dispatchEvent(new Event('input'));
  const rejected=window.nativeAction({action:'navigate',path:other.path});
  const conflict={...base,text:'Retained draft',html:'<p>Retained draft</p>',dirty:true,error:'External conflict'};
  await reply(await next(),conflict);await reply(await next(),conflict);await rejected;
  check(!$('editor').readOnly&&$('editor').value==='Retained draft'&&!$('error').hidden,'failed navigation must restore editing and preserve the draft');
  passed.push('failed navigation preserves recovery');

  const first=window.nativeAction({action:'navigate',path:other.path});
  const second=window.nativeAction({action:'navigate',path:base.path});
  await reply(await next(),other);await first;
  check($('editor').readOnly,'one completed transition must not unlock another pending transition');
  await reply(await next(),base);await second;
  check(!$('editor').readOnly,'last completed transition must release editing');
  passed.push('overlapping transitions retain the editor lock');
  // Reestablish the conflicting draft for close recovery.
  $('edit').click();$('editor').value='Retained draft';$('editor').dispatchEvent(new Event('input'));
  await reply(await next(),conflict);

  const deniedClose=window.nativeAction({action:'close'});
  check($('editor').readOnly,'close must lock editor before flushing');
  const flushFailure=await next();check(flushFailure.action==='flush','close must flush');
  await reply(flushFailure,conflict);await deniedClose;
  const denied=await next();check(denied.action==='closed'&&denied.ok===false,'dirty close must be refused');
  check(!$('editor').readOnly&&$('editor').value==='Retained draft','refused close must restore editable draft');
  await reset();$('edit').click();$('editor').value='Final accepted edit';$('editor').dispatchEvent(new Event('input'));
  const closing=window.nativeAction({action:'close'});
  const finalEdit=await next();check(finalEdit.action==='edit'&&finalEdit.text==='Final accepted edit','close must drain final input');
  const saved={...base,text:'Final accepted edit',html:'<p>Final accepted edit</p>'};
  await reply(finalEdit,saved);
  const flush=await next();check(flush.action==='flush','flush must follow final edit');await reply(flush,saved);await closing;
  const closed=await next();check(closed.action==='closed'&&closed.ok===true,'clean close must be acknowledged');
  check($('editor').readOnly,'successful close must stay locked until native resumes the window');
  // AppKit explicitly resumes a successfully hidden (rather than quit) window.
  await window.nativeAction({action:'resume'});check(!$('editor').readOnly,'resuming a hidden window must restore editing');
  passed.push('close drains edits, refuses dirty state, and holds the successful-close lock');

  await reset();const file=$('files').children[1];file.focus();file.click();
  const focusMove=await next();await reply(focusMove,other);
  check(document.activeElement===$('files').children[1],'sidebar activation must retain focus on the same file');
  passed.push('sidebar keyboard focus survives activation');

  await reset();$('rendered').innerHTML='<a href="other%20note%25.md">Other</a>';
  let linkError='';const onError=e=>{linkError=e.message;e.preventDefault()};window.addEventListener('error',onError);
  $('rendered').querySelector('a').click();await drain();
  if(linkError){check(false,'relative link in a percent directory throws: '+linkError)}
  else {const link=await next();check(link.action==='navigateLink'&&link.path===base.path&&link.href==='other%20note%25.md','bridge must send URI reference without decoding filesystem directory');await reply(link,other)}
  window.removeEventListener('error',onError);passed.push('relative links preserve URI boundary');

  await reset();$('find').click();$('searchQuery').value='Original';$('searchQuery').dispatchEvent(new Event('input'));
  const search=await next();check(search.action==='search','automatic search must query the bridge');
  const match={path:base.path,line:1,column:3,start:2,end:10,text:'Original',snippet:'# Original',snippetStart:2,snippetEnd:10,before:[],after:[]};
  const result={search:{matches:[match],truncated:false,warnings:[]}};
  await reply(search,result);$('searchForm').requestSubmit();await drain();
  if($('searchPanel').open){const resubmit=await next();check(resubmit.action==='search','Find must rerun search');await reply(resubmit,result);check(document.activeElement===$('searchFiles').children[0],'Find must focus matching files')}
  check($('searchPanel').open,'Find must not open a match or close the modal when results already exist');
  if($('searchPanel').open){$('openMatch').click();await drain();check(!$('searchPanel').open,'Open match must still open the selected result')}
  passed.push('Find searches consistently; Open match opens');

  await reset();check($('preview').getAttribute('aria-pressed')==='true'&&$('edit').getAttribute('aria-pressed')==='false','preview mode must expose pressed state');
  $('edit').click();check($('edit').getAttribute('aria-pressed')==='true'&&$('preview').getAttribute('aria-pressed')==='false','edit mode must update accessible state');
  $('appearance').click();const sepia=document.querySelector('button[data-theme="sepia"]');sepia.click();
  await reply(await next(),{...base,theme:'sepia'});
  check(sepia.getAttribute('aria-pressed')==='true'&&document.querySelector('button[data-theme="paper"]').getAttribute('aria-pressed')==='false','appearance buttons must expose selected state');
  check($('theme').getAttribute('role')==='group'&&!!$('theme').getAttribute('aria-labelledby'),'theme choices must be a named group');
  passed.push('mode and appearance selections expose accessible state');

  // Numerical contrast target from the remediation, computed from actual CSS.
  function luminance(rgb){const c=rgb.match(/[\d.]+/g).slice(0,3).map(Number).map(x=>{x/=255;return x<=.04045?x/12.92:((x+.055)/1.055)**2.4});return .2126*c[0]+.7152*c[1]+.0722*c[2]}
  for(const theme of ['paper','sepia']){
   document.body.dataset.theme=theme;
   const probe=document.createElement('span');probe.style.color='var(--muted)';document.body.append(probe);
   const ink=luminance(getComputedStyle(probe).color);
   for(const surface of ['--bg','--surface']){probe.style.backgroundColor=`var(${surface})`;const bg=luminance(getComputedStyle(probe).backgroundColor);const ratio=(Math.max(ink,bg)+.05)/(Math.min(ink,bg)+.05);check(ratio>=4.5,`${theme} muted text on ${surface} contrast ${ratio.toFixed(2)} is below 4.5`)}
   probe.remove();
  }
  passed.push('Paper and Sepia muted text contrast');
 }catch(e){failures.push(e.stack||String(e))}
 window.webkit.messageHandlers.result.postMessage({checks:passed,failures});
})();
