/* V4.4: verified Discord identity linking via Supabase Auth + PKCE. */
let discordOwner=null,discordIdentity=null,discordAuthUser=null,discordLoadError='',discordActionBusy=false,discordFlash='',discordFlashError=false,registrationBusy=false;
const discordPendingKey=()=>AUTHKEY+'_discord_pkce';
function discordMessage(text,isError=false){discordOwner=session?.user?.id||null;discordFlash=text;discordFlashError=isError;renderAccountExtras()}
async function discordAuthRequest(path,method='GET',body,token){
 const jwt=token||await validToken();if(!jwt)throw new Error('Войдите на сайт заново.');
 const response=await fetch(config.supabaseUrl.replace(/\/$/,'')+'/auth/v1/'+path,{method,headers:{apikey:config.supabaseAnonKey,Authorization:'Bearer '+jwt,'Content-Type':'application/json'},...(body===undefined?{}:{body:JSON.stringify(body)})});
 const result=await response.json().catch(()=>({}));
 if(!response.ok){const code=result.error_code||result.code;if(code==='manual_linking_disabled')throw new Error('Администратор должен включить Manual Linking в Supabase.');if(code==='identity_already_exists'||code==='identity_already_linked')throw new Error('Этот Discord уже привязан к аккаунту. Не создавайте новую привязку: проверьте текущий аккаунт.');throw new Error(result.msg||result.error_description||result.message||'Ошибка авторизации Discord ('+response.status+').')}
 return result;
}
function nativeDiscordIdentity(user){return user?.identities?.find(i=>i.provider==='discord')||null}
async function loadDiscordIdentity(){
 discordIdentity=null;discordAuthUser=null;discordLoadError='';const owner=session?.user?.id||null;if(discordOwner!==owner){discordFlash='';discordFlashError=false;discordOwner=owner}if(!owner||DEMO)return;
 try{const user=await discordAuthRequest('user');if(session?.user?.id!==owner)return;if(user.id!==owner)throw new Error('Сессия изменилась. Войдите на сайт заново.');discordAuthUser=user;discordIdentity=nativeDiscordIdentity(user)}catch(e){if(session?.user?.id===owner)discordLoadError='Не удалось проверить привязку: '+e.message}
}
function discordDisplayName(identity){const d=identity?.identity_data||{};return d.preferred_username||d.user_name||d.name||d.full_name||'Аккаунт Discord'}
function discordProviderId(identity){const d=identity?.identity_data||{};return [d.provider_id,d.sub,identity?.id].find(x=>/^\d{15,22}$/.test(String(x||'')))||''}
function canUnlinkDiscord(user){return !!user?.email_confirmed_at&&Array.isArray(user.identities)&&user.identities.length>=2&&user.identities.some(i=>i.provider==='email')}
function renderAccountExtras(){
 $('#discordContactCard')?.remove();if(!me)return;
 const linked=!DEMO&&!discordLoadError&&discordIdentity,ready=config.discordOAuthEnabled===true,canUnlink=linked&&canUnlinkDiscord(discordAuthUser);
 const badge=DEMO?'Демо':discordLoadError?'Не удалось проверить':linked?'Подтверждён через Discord':'Не привязан';
 const details=linked?`<div class="discord-verified-account"><div class="discord-account-symbol">${icon('user')}</div><div><b>${esc(discordDisplayName(discordIdentity))}</b>${discordProviderId(discordIdentity)?`<p class="fieldhint" data-copyable>Discord ID: ${esc(discordProviderId(discordIdentity))}</p>`:''}<p class="fieldhint">Привязка проверена через Supabase Auth, не введена вручную.</p></div></div>`:`<p class="fieldhint">Подтвердите свой аккаунт в окне Discord. Minecraft-ник, почтовый аккаунт и права на сайте сохранятся.</p>`;
 const notice=DEMO?'В автономном демо настоящий Discord подключить нельзя. Откройте опубликованный HTTPS-сайт с настроенным Discord OAuth.':discordLoadError?'Проверьте соединение. Статус привязки неизвестен — обновите его перед действием.':!ready&&!linked?'Администратор ещё не включил Discord OAuth для сайта. Инструкция находится в архиве: DISCORD_SETUP.md.':linked&&!canUnlink?'Перед отвязкой нужен подтверждённый вход по почте. Нельзя удалить единственный способ входа.':'Имя и ID Discord доступны только вам в личном кабинете. Пароль Discord вводится только на discord.com, не здесь.';
 const card=`<section class="card discord-card" id="discordContactCard"><div class="section-label">СВЯЗАННЫЕ АККАУНТЫ</div><div class="row"><h2>Discord</h2><span class="tag ${linked?'st-ok':'t-pl'}">${badge}</span></div>${details}<p class="fieldhint discord-oauth-notice">${esc(notice)}</p><div class="discord-controls">${linked?`<button class="btn ghost" id="discordUnlink" onclick="unlinkDiscordAccount()" ${canUnlink&&!discordActionBusy?'':'disabled'}>Отвязать Discord</button>`:`<button class="btn" id="discordLink" onclick="linkDiscordAccount()" ${!DEMO&&ready&&!discordLoadError&&!discordActionBusy?'':'disabled'}>${discordActionBusy?'Открываем Discord…':'Привязать Discord'}</button>`}${!DEMO?`<button class="btn ghost" onclick="refreshDiscordIdentity()" ${discordActionBusy?'disabled':''}>Обновить статус</button>`:''}</div><p id="discordStatus" class="${discordFlashError||discordLoadError?'error':'fieldhint'}" role="status" aria-live="polite">${esc(discordFlash||discordLoadError)}</p></section>`;
 $('#cabinetBody .account-hero')?.insertAdjacentHTML('afterend',card);
}
async function refreshDiscordIdentity(){if(discordActionBusy)return;discordFlash='';await loadDiscordIdentity();renderAccountExtras()}
function oauthBase64url(bytes){return btoa(String.fromCharCode(...bytes)).replace(/\+/g,'-').replace(/\//g,'_').replace(/=+$/,'')}
function safeDiscordAuthorizeUrl(value){const url=new URL(value);if(url.protocol!=='https:'||!['discord.com','discordapp.com'].includes(url.hostname)||!['/oauth2/authorize','/api/oauth2/authorize'].includes(url.pathname)||url.username||url.password||(url.port&&url.port!=='443')||!url.searchParams.get('state')||url.searchParams.get('response_type')!=='code')throw new Error('Сервер вернул неподходящий адрес авторизации Discord.');return url.href}
async function linkDiscordAccount(){
 if(DEMO){discordMessage('Демо не выполняет настоящую привязку Discord.');return false}
 if(discordActionBusy)return false;
 if(config.discordOAuthEnabled!==true){discordMessage('Сначала включите Discord OAuth по DISCORD_SETUP.md.',true);return false}
 if(!session?.user?.id){loginModal();return false}
 if(location.protocol!=='https:'&&!['localhost','127.0.0.1'].includes(location.hostname)){discordMessage('Для привязки откройте сайт по HTTPS.',true);return false}
 const owner=session.user.id;discordActionBusy=true;discordFlash='';renderAccountExtras();
 try{
  const user=await discordAuthRequest('user');if(user.id!==owner||session?.user?.id!==owner)throw new Error('Аккаунт изменился. Повторите привязку.');if(nativeDiscordIdentity(user))throw new Error('Discord уже привязан. Сначала обновите статус.');
  const verifier=oauthBase64url(crypto.getRandomValues(new Uint8Array(64))),challenge=oauthBase64url(new Uint8Array(await crypto.subtle.digest('SHA-256',new TextEncoder().encode(verifier))));
  const redirect=new URL(location.origin+location.pathname);redirect.searchParams.set('discord_link','1');
  sessionStorage.setItem(discordPendingKey(),JSON.stringify({verifier,userId:owner,createdAt:Date.now(),redirect:redirect.href}));
  const query=new URLSearchParams({provider:'discord',redirect_to:redirect.href,scopes:'identify email',code_challenge:challenge,code_challenge_method:'s256',skip_http_redirect:'true'});
  const result=await discordAuthRequest('user/identities/authorize?'+query.toString());
  if(session?.user?.id!==owner)throw new Error('Аккаунт изменился. Повторите привязку.');
  const destination=safeDiscordAuthorizeUrl(result.url);location.assign(destination);return true;
 }catch(e){sessionStorage.removeItem(discordPendingKey());discordMessage('Не удалось начать привязку: '+e.message,true);return false}
 finally{discordActionBusy=false;renderAccountExtras()}
}
async function handleDiscordOAuthReturn(){
 const url=new URL(location.href);if(url.searchParams.get('discord_link')!=='1')return false;
 const hash=new URLSearchParams(url.hash.slice(1)),code=url.searchParams.get('code'),failure=url.searchParams.get('error')||hash.get('error');
 let pending;try{pending=JSON.parse(sessionStorage.getItem(discordPendingKey())||'null')}catch{}
 // Remove temporary codes/errors from browser history before loading page content.
 for(const key of ['discord_link','code','error','error_code','error_description'])url.searchParams.delete(key);url.hash='cabinet';history.replaceState(null,'',url.pathname+url.search+url.hash);
 sessionStorage.removeItem(discordPendingKey());discordOwner=session?.user?.id||null;
 try{
  if(DEMO)throw new Error('В демо OAuth недоступен.');
  if(!pending||!Number.isFinite(pending.createdAt)||!/^[A-Za-z0-9_-]{43,128}$/.test(pending.verifier||'')||pending.userId!==session?.user?.id||Date.now()-pending.createdAt>10*60*1000||Date.now()<pending.createdAt)throw new Error('Запрос привязки истёк или открыт в другой вкладке/аккаунте. Начните заново.');
  if(failure){discordFlash=failure==='access_denied'?'Привязка отменена в Discord.':'Discord не завершил авторизацию. Повторите попытку.';discordFlashError=true;return true}
  if(!code||code.length>4096)throw new Error('Discord не вернул код авторизации.');
  const out=await auth('token?grant_type=pkce',{auth_code:code,code_verifier:pending.verifier});
  if(!out.access_token||out.user?.id!==pending.userId||session?.user?.id!==pending.userId)throw new Error('Сессия не совпала с аккаунтом, начавшим привязку. Вход не переключён.');
  const user=await discordAuthRequest('user','GET',undefined,out.access_token);
  if(user.id!==pending.userId||!nativeDiscordIdentity(user))throw new Error('Сервер не подтвердил привязку Discord. Обновите статус в кабинете.');
  storeAuth({access_token:out.access_token,refresh_token:out.refresh_token,expires_in:out.expires_in,expires_at:Math.floor(Date.now()/1000)+out.expires_in,token_type:out.token_type,user});
  discordIdentity=nativeDiscordIdentity(user);discordAuthUser=user;discordFlash='Discord успешно привязан к вашему аккаунту.';discordFlashError=false;
 }catch(e){discordFlash='Не удалось завершить привязку: '+e.message;discordFlashError=true}
 return true;
}
async function unlinkDiscordAccount(){
 if(DEMO||discordActionBusy||!session?.user?.id)return false;
 if(!confirm('Отвязать Discord от вашего аккаунта? Вход по почте и Minecraft-профиль сохранятся.'))return false;
 const owner=session.user.id;discordActionBusy=true;renderAccountExtras();
 try{
  const user=await discordAuthRequest('user'),identity=nativeDiscordIdentity(user);
  if(user.id!==owner||session?.user?.id!==owner)throw new Error('Аккаунт изменился. Обновите страницу.');
  if(!identity)throw new Error('Discord уже не привязан. Обновите статус.');
  if(!canUnlinkDiscord(user))throw new Error('Сначала подтвердите почту. Нельзя удалить единственный способ входа.');
  if(!/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(identity.identity_id||''))throw new Error('Сервер не вернул идентификатор привязки.');
  await discordAuthRequest('user/identities/'+encodeURIComponent(identity.identity_id),'DELETE');
  await loadDiscordIdentity();if(discordLoadError||discordIdentity)throw new Error('Не удалось подтвердить отвязку. Обновите статус.');
  discordFlash='Discord отвязан. Вход по почте и права на сайте сохранены.';discordFlashError=false;return true;
 }catch(e){discordFlash='Не удалось отвязать Discord: '+e.message;discordFlashError=true;return false}
 finally{discordActionBusy=false;renderAccountExtras()}
}
function renderRegistrationNotice(){
 if(!$('#registrationNotice'))return;
 $('#registrationNotice').textContent=DEMO?'ДЕМО: создаётся только локальный профиль в этом браузере. Почта и пароль не сохраняются, настоящего аккаунта нет. Не вводите настоящий пароль.':'Регистрация по почте. Если подтверждение включено, откройте письмо, подтвердите адрес, затем войдите. Пароль обрабатывается Supabase Auth, а не хранится в коде сайта.';
 $('#registerSubmit').textContent=DEMO?'Создать демо-профиль':'Создать аккаунт';
}
async function registerAccount(){
 const form=$('#registrationForm'),status=$('#registrationStatus');if(registrationBusy||busy)return;
 status.className='error';if(session?.user?.id){status.textContent='Вы уже вошли. Сначала выйдите из аккаунта для новой регистрации.';return}
 if(!form.reportValidity())return;
 const nick=$('#rNick').value.trim(),email=$('#rEmail').value.trim(),password=$('#rPass').value;
 if(!/^[A-Za-z0-9_]{2,16}$/.test(nick)){status.textContent='Ник: 2–16 латинских букв, цифр или _.';return}
 if(password.length<8||password.length>128){status.textContent='Пароль должен содержать от 8 до 128 символов.';return}
 if(password!==$('#rConfirm').value){status.textContent='Пароли не совпадают.';return}
 if(S.players.some(p=>p.nick.toLowerCase()===nick.toLowerCase())){status.textContent='Этот игровой ник уже зарегистрирован.';return}
 registrationBusy=true;let accountCreated=false;$('#registerSubmit').disabled=true;status.className='fieldhint';status.textContent='Создаём профиль…';
 try{
  if(DEMO){const player={id:uid(),nick,min:null,head:false};S.players.push(player);localStorage.setItem(KEY,JSON.stringify(S));session={user:{id:player.id}};sessionStorage.setItem(KEY+'_demo',player.id);form.reset();await loadData();go('cabinet');route();toast('Создан локальный демо-профиль. Настоящего аккаунта нет.');return}
  const redirect=location.origin+location.pathname;
  const out=await auth('signup?redirect_to='+encodeURIComponent(redirect),{email,password,data:{nick}});
  $('#rPass').value=$('#rConfirm').value='';
  if(out.access_token){accountCreated=true;storeAuth({...out,expires_at:Math.floor(Date.now()/1000)+out.expires_in});await loadData();form.reset();go('cabinet');route();toast('Аккаунт создан');return}
  status.className='fieldhint';status.textContent='Заявка на регистрацию обработана. Если адрес принят, проверьте письмо подтверждения и папку «Спам», затем войдите. При повторной регистрации используйте вход или восстановление пароля.';
 }catch(e){status.className='error';status.textContent=accountCreated?'Аккаунт создан, но данные не загрузились. Обновите страницу или войдите повторно.':('Не удалось зарегистрироваться: '+e.message)}
 finally{registrationBusy=false;$('#registerSubmit').disabled=false}
}
