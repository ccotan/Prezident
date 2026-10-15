/* Shared photo fields and resilient navigation. */
function validImageArray(value){return Array.isArray(value)&&value.length<=4&&value.every(s=>typeof s==='string'&&s.length<=2000&&/^https:\/\/\S+$/.test(s)&&!!imageUrl(s))}
function imageFields(id,images=[],label='Изображения',disabled=false){return `<div class="photo-fields"><label for="${id}">${esc(label)} · до 4 фото</label><textarea id="${id}" class="photo-links" rows="2" placeholder="https://example.com/photo.png\nОдна HTTPS-ссылка на строку" ${disabled?'disabled':''} oninput="previewImageFields('${id}')">${esc(images.join('\n'))}</textarea><p class="fieldhint">Прямые ссылки на файлы изображений, по одной на строку. Файлы остаются на внешнем хостинге.</p><div id="${id}Preview" class="photo-preview">${mediaMarkup(images).replaceAll('loading="lazy"','loading="eager"')}</div></div>`}
function readImageFields(id){const values=($('#'+id)?.value||'').split(/\r?\n/).map(s=>s.trim()).filter(Boolean);if(!validImageArray(values)){toast('Добавьте до 4 корректных HTTPS-ссылок (до 2000 символов каждая)');return null}return values}
function previewImageFields(id){const out=$('#'+id+'Preview');if(!out)return;const values=($('#'+id)?.value||'').split(/\r?\n/).map(s=>s.trim()).filter(Boolean);out.innerHTML=validImageArray(values)?mediaMarkup(values).replaceAll('loading="lazy"','loading="eager"'):'<p class="error">Нужно до 4 прямых HTTPS-ссылок на изображения.</p>'}
function showTaxImages(id){const tax=S.taxes.find(t=>t.id===id);if(!tax)return;modal('<div class="h2">Фото бочки № '+esc(tax.num)+'</div>'+mediaMarkup(tax.images||[]))}
function avatarFallback(img){const step=Number(img.dataset.avatarStep||0);if(step===0&&/^[A-Za-z0-9_]{2,16}$/.test(img.dataset.nick||'')){img.dataset.avatarStep='1';img.src='https://minotar.net/helm/'+encodeURIComponent(img.dataset.nick)+'/128.png';img.title=(img.dataset.nick||'Игрок')+' · резервный сервис аватаров'}else{img.onerror=null;img.src='assets/head-fallback.png';img.classList.add('is-fallback');img.title=(img.dataset.nick||'Игрок')+' · скин недоступен'}}
function fitNav(){const nav=$('nav');if(!nav)return;nav.classList.remove('nav-tight','nav-collapsed');if(innerWidth<=980)return;const style=getComputedStyle(nav),children=[...nav.children].filter(e=>getComputedStyle(e).display!=='none'&&getComputedStyle(e).position!=='absolute');const available=nav.clientWidth-parseFloat(style.paddingLeft)-parseFloat(style.paddingRight);const needed=children.reduce((sum,e)=>sum+e.getBoundingClientRect().width,0)+Math.max(0,children.length-1)*parseFloat(style.columnGap||0);if(needed>available+1||nav.scrollWidth>nav.clientWidth+1)nav.classList.add('nav-collapsed')}
let navFitInstalled=false;
function installNavFit(){if(navFitInstalled)return;navFitInstalled=true;addEventListener('resize',()=>requestAnimationFrame(fitNav));document.fonts?.ready.then(fitNav);let width=0;new ResizeObserver(entries=>{const w=entries[0].contentRect.width;if(Math.abs(w-width)>1){width=w;requestAnimationFrame(fitNav)}}).observe($('nav'))}

/* Do not block shortcuts, context menus or editing; only protect UI text. */
const copyableContentSelector='.embed-body,.publication-meta,.case-excerpt,.case-original,.case-message,.reply,.task-text,.task-card h3,.notification-card h3,.notification-card p,input,textarea,[contenteditable="true"],[data-copyable]';
function copyableContainer(node){const el=node?.nodeType===Node.ELEMENT_NODE?node:node?.parentElement;if(!el||el.closest('button,nav,footer'))return null;return el.closest(copyableContentSelector)}
document.addEventListener('selectstart',event=>{if(!copyableContainer(event.target))event.preventDefault()});
document.addEventListener('copy',event=>{
 const focused=document.activeElement;
 if(focused?.matches('input,textarea')||focused?.isContentEditable)return;
 const selection=getSelection();
 if(!selection||selection.isCollapsed){event.preventDefault();return}
 for(let i=0;i<selection.rangeCount;i++){const range=selection.getRangeAt(i),container=copyableContainer(range.commonAncestorContainer);if(!container){event.preventDefault();return}}
});
