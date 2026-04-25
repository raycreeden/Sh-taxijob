'use strict';

const COLORS={celeste:{r:80,g:180,b:255,name:'Celeste'},naranja:{r:255,g:160,b:60,name:'Naranja'},verde:{r:63,g:185,b:80,name:'Verde'},rojo:{r:248,g:81,b:73,name:'Rojo'},amarillo:{r:247,g:201,b:72,name:'Amarillo'},blanco:{r:240,g:240,b:240,name:'Blanco'},violeta:{r:160,g:100,b:220,name:'Violeta'},rosa:{r:220,g:100,b:160,name:'Rosa'},negro:{r:20,g:20,b:20,name:'Negro'}};
const PANELS=['ubicaciones','vehiculos','salarios','viajes_config','invitar','empresa','viajes_realizados','empleados','alertas_config'];
const PANEL_LABELS={ubicaciones:'Ubicaciones',vehiculos:'Vehículos',salarios:'Salarios',viajes_config:'Viajes Config',invitar:'Invitar',empresa:'Cuenta Empresa',viajes_realizados:'Viajes Realizados',empleados:'Empleados',alertas_config:'Alertas Config'};

let countdownMs=60000;
let myTripId=null;     // como taxista
let myTripTip=0;
let selectedTip=0;
let canChangeWp=true;
let activeTripsCached={};

const state={open:false,vmenuOpen:false,modalOpen:false,currentLocType:null,data:null};

function postNui(a,d={}){
  return fetch(`https://sh-taxijob/${a}`,{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(d)}).then(r=>r.json()).catch(()=>{});
}

/* ══ NOTIFY ══ */
const ICONS={success:'fa-check-circle',error:'fa-times-circle',info:'fa-info-circle',warning:'fa-exclamation-triangle'};
function showNotify({type='info',title='',message='',duration=5000}){
  const c=document.getElementById('notify-container');
  const el=document.createElement('div');
  el.className=`notify-item ${type}`;el.style.setProperty('--dur',`${duration/1000}s`);
  el.innerHTML=`<span class="notify-icon"><i class="fas ${ICONS[type]||ICONS.info}"></i></span><div><p class="notify-title">${title}</p><p class="notify-msg">${message}</p></div>`;
  c.appendChild(el);
  el.addEventListener('animationend',e=>{if(e.animationName==='nOut')el.remove();});
  setTimeout(()=>el.remove(),duration+600);
}

/* ══ TRIP NOTIFY (violeta, centro pantalla) ══ */
// Teclas del config (fijas, no configurables desde la tablet)
const CFG_HOTKEYS={
  1:'O', 2:'I', 3:'U', 4:'J', 5:'-', 6:'I', 7:'O'
};

function showTripNotify(trip){
  const c=document.getElementById('trip-notify-container');
  const el=document.createElement('div');
  el.className='trip-notify';el.id=`tn-${trip.id}`;
  // El que está en el tope de la lista es el "latest"
  latestTripId=trip.id;
  const acceptKey=CFG_HOTKEYS[6]||'I';
  const ignoreKey=CFG_HOTKEYS[7]||'O';
  el.innerHTML=`
    <div class="trip-notify-top">
      <div class="trip-notify-title"><i class="fas fa-taxi"></i> Ciudadano solicita taxi</div>
    </div>
    <div class="trip-notify-zones">
      <div><strong>Desde:</strong> ${trip.fromZone||'Zona desconocida'}</div>
      <div><strong>Hacia:</strong> ${trip.toZone||'Zona desconocida'}</div>
    </div>
    <div class="trip-notify-price"><i class="fas fa-dollar-sign"></i> Base: $${trip.basePrice}</div>
    <div class="trip-notify-actions">
      <button class="btn-accept-trip" onclick="acceptFromNotify(${trip.id})">
        <kbd>${acceptKey}</kbd> <i class="fas fa-check"></i> Aceptar
      </button>
      <button class="btn-dismiss-trip" onclick="dismissTripNotify(${trip.id})">
        <kbd>${ignoreKey}</kbd> Ignorar
      </button>
    </div>`;
  c.appendChild(el);
  setTimeout(()=>{if(el.parentNode)el.remove();}, alertasLocal.tripNotifyDur || 20000);
}
let latestTripId=null;
window.acceptFromNotify=id=>{postNui('acceptTrip',{tripId:id});dismissTripNotify(id);};
window.dismissTripNotify=id=>{
  const el=document.getElementById(`tn-${id}`);if(el)el.remove();
  if(latestTripId===id) latestTripId=null;
};

/* ══ TABLET ══ */
function openTablet(d={}){
  state.open=true;countdownMs=d.msToNext??60000;
  _isOwnerGlobal = d.isOwner === true;
  document.getElementById('tablet-overlay').classList.remove('hidden');
  setTab('dashboard');updateDutyUI(d.onDuty===true,d.msToNext);
}
function closeTablet(){
  state.open=false;document.getElementById('tablet-overlay').classList.add('hidden');postNui('closeTablet');
}
document.querySelectorAll('.nav-btn').forEach(b=>b.addEventListener('click',()=>setTab(b.dataset.tab)));
function setTab(id){
  document.querySelectorAll('.nav-btn').forEach(b=>b.classList.toggle('active',b.dataset.tab===id));
  document.querySelectorAll('.tab-panel').forEach(p=>p.classList.toggle('active',p.id===`panel-${id.replace('-','_')}`||p.id===`panel-${id}`));
  if(id==='servicio') postNui('getServiceLogs');
  if(id==='viajes-realizados') postNui('getTripHistory');
  if(id==='empresa') postNui('getSocietyData');
  if(id==='nivel') postNui('getMyXP');
  if(id==='alertas-config') postNui('getAlertasConfig');
}

(function patchSetTabAlertas(){
  const _orig = window.setTab;
  if(typeof _orig === 'function') {
    window.setTab = function(id){
      _orig(id);
      if(id === 'alertas-config') {
        postNui('getAlertasConfig');
        // Sincronizar UI con el estado local actual mientras llega la respuesta
        syncAlertasUI(null);
      }
    };
  }
})();

/* ══ DUTY ══ */
function updateDutyUI(on,ms){
  const btn=document.getElementById('btn-duty');
  const lbl=document.getElementById('duty-label');
  const dot=document.getElementById('duty-dot');
  const st=document.getElementById('stat-duty-status');
  const banner=document.getElementById('duty-banner');
  const bannerTxt=document.getElementById('duty-banner-text');
  const reqBanner=document.getElementById('duty-required-banner');
  btn.classList.toggle('on-duty',on);
  lbl.textContent=on?'Finalizar Servicio':'Iniciar Servicio';
  btn.querySelector('i').className=on?'fas fa-stop-circle':'fas fa-play-circle';
  dot.classList.toggle('on',on);
  if(st) st.textContent=on?'En Servicio':'Fuera de Servicio';
  if(banner) banner.className='duty-banner '+(on?'on':'off');
  if(bannerTxt) bannerTxt.textContent=on?'En Servicio':'Fuera de Servicio';
  if(reqBanner) reqBanner.classList.toggle('hidden',on);
  if(ms!==undefined) countdownMs=ms;
  updateCountdownDisplay(on);
  renderRadioWarn();
}
document.getElementById('btn-duty').addEventListener('click',()=>postNui('toggleDuty'));

function updateCountdownDisplay(on){
  const el=document.getElementById('stat-next-salary');
  if(!el) return;
  if(!on){el.textContent='—';return;}
  const m=Math.floor(countdownMs/60000);
  const s=Math.floor((countdownMs%60000)/1000);
  el.textContent=`${m}m ${String(s).padStart(2,'0')}s`;
}

/* ══ DATA ══ */
function updateTabletData(d){
  state.data=d;
  _isOwnerGlobal = d.isOwner === true;
  if(d.companyName) setCompanyNameUI(d.companyName);
  renderDashboard(d);renderEmployees(d);renderSalaries(d);
  renderLocations(d);renderVehicleConfig(d);renderInvite(d);
  renderTrips(d.activeTrips||[]);
  renderTripConfig(d.tripConfig);
  renderPermissions(d.permissions,d.grades,d.isOwner,d.canEdit||{});
  if(d.markerCfg) syncMarkerUI(d.markerCfg);
  if(d.serviceLogs) renderServiceLogs(d.serviceLogs);
  if(d.hotkeys) renderHotkeys(d.hotkeys,d.canEditHotkeys);
  if(d.myXp) renderXP(d.myXp,d.levels);
  updateDutyUI(d.onDuty===true,d.msToNext);
  renderCanEdit(d.canEdit||{});
  if(d.activeTrips) d.activeTrips.forEach(t=>activeTripsCached[t.id]=t);
  // Re-render radio panels with updated state/permissions
  renderRadioWarn();
  renderRadioChannels(null);
  renderRadioDuty(null);
        if(d.alertasCfg) applyAlertasConfig(d.alertasCfg);
       if(d.alertasCfg) syncAlertasUI(d.alertasCfg);
}

function renderCanEdit(canEdit){
  document.getElementById('salary-no-perm').classList.toggle('hidden',canEdit.salarios!==false);
  document.getElementById('loc-no-perm').classList.toggle('hidden',canEdit.ubicaciones!==false);
  document.getElementById('veh-no-perm').classList.toggle('hidden',canEdit.vehiculos!==false);
  document.getElementById('viajes-no-perm').classList.toggle('hidden',canEdit.viajes_config!==false);
  document.getElementById('invite-no-perm').classList.toggle('hidden',canEdit.invitar!==false);
  document.getElementById('permisos-no-owner').classList.toggle('hidden',state.data&&state.data.isOwner);

  const empWarn=document.getElementById('empresa-perm-warn');
  const empContent=document.getElementById('empresa-content');
  const canEmpresa=canEdit.empresa||state.data?.isOwner;
  if(empWarn) empWarn.classList.toggle('hidden',canEmpresa);
  if(empContent) empContent.style.pointerEvents=canEmpresa?'':'none';
  // viajes_realizados
  const vrWarn=document.getElementById('viajes-realizados-perm-warn');
  const vrContent=document.getElementById('viajes-realizados-content');
  const canVR=canEdit.viajes_realizados||state.data?.isOwner;
  if(vrWarn) vrWarn.classList.toggle('hidden',canVR);
  if(vrContent) vrContent.style.display=canVR?'':'none';
       // alertas_config
       const acWarn    = document.getElementById('alertas-no-perm');
       const acContent = document.getElementById('alertas-content');
       const canAC     = canEdit.alertas_config || state.data?.isOwner;
       if(acWarn)    acWarn.classList.toggle('hidden', !!canAC);
       if(acContent) acContent.style.pointerEvents = canAC ? '' : 'none';
}

/* DASHBOARD */
function renderDashboard(d){
  const emps=d.employees||[];
  document.getElementById('stat-online').textContent=emps.filter(e=>e.online).length;
  document.getElementById('stat-onduty').textContent=(d.onDutyList||[]).length;
  document.getElementById('stat-trips').textContent=(d.activeTrips||[]).length;
  document.getElementById('stat-myrole').textContent=d.isOwner?'Propietario':'Miembro';
}

/* EMPLOYEES */
function renderEmployees(d){
  const all=d.employees||[];
  const online=all.filter(e=>e.online);
  const duty=d.onDutyList||[];
  const offline=all.filter(e=>!e.online);
  document.getElementById('badge-online').textContent=online.length;
  document.getElementById('badge-duty').textContent=duty.length;
  document.getElementById('badge-offline').textContent=offline.length;
  const gOpts=(d.grades||[]).map(g=>`<option value="${g.grade}">${g.label}</option>`).join('');
  renderEmpList('emp-panel-online',online,d,gOpts,false);
  renderEmpList('emp-panel-duty',duty,d,gOpts,false);
  renderEmpList('emp-panel-offline',offline,d,gOpts,true);
  // Los nombres offline vienen directamente del server (guardados en sh_taxijob_members)
}

function renderEmpList(cid,list,d,gOpts,isOffline){
  const c=document.getElementById(cid);
  if(!list.length){c.innerHTML=`<p class="empty-msg">${isOffline?'Sin empleados offline.':cid.includes('duty')?'Nadie en servicio.':'Nadie online.'}</p>`;return;}
  c.innerHTML=list.map(emp=>{
    const ini=(((emp.name||'').split(' ').map(w=>w[0]||'').join('').toUpperCase().slice(0,2))||'?');
    const ownerTag=emp.isOwner?`<span class="owner-tag"><i class="fas fa-crown" style="font-size:8px"></i></span>`:'';
    const dutyTag=emp.onDuty?`<span class="duty-tag">● servicio</span>`:'';
    const offTag=isOffline?`<span class="offline-tag">Offline</span>`:'';
    const canM=d.isOwner&&!emp.isOwner&&!isOffline&&emp.id;
    const displayName=emp.name||`CID:${(emp.cid||'').slice(0,10)}...`;
    return `<div class="emp-card${isOffline?' offline-row':''}" id="ec-${cid}-${emp.id||emp.cid}">
      <div class="emp-row" ${canM?`onclick="toggleEmpCard('ec-${cid}-${emp.id||emp.cid}')"`:''}> 
        <div class="emp-avatar">${ini}</div>
        <div class="emp-info"><p class="emp-name">${displayName}</p><p class="emp-sub">${emp.gradeLabel}</p></div>
        ${ownerTag}${dutyTag}${offTag}
        ${emp.id?`<span class="emp-id">ID ${emp.id}</span>`:''}
        ${canM?'<i class="fas fa-chevron-down chevron"></i>':''}
      </div>
      ${canM?`<div class="emp-expand"><div class="emp-expand-row">
        <select class="sh-select" id="gsel-${cid}-${emp.id}" style="flex:1">${gOpts}</select>
        <button class="btn-primary btn-sm" onclick="saveGrade('${cid}',${emp.id})"><i class="fas fa-save"></i></button>
        <button class="btn-danger btn-sm" onclick="fireEmp(${emp.id},'${displayName.replace(/'/g,'').slice(0,20)}')"><i class="fas fa-user-times"></i></button>
      </div></div>`:''}
    </div>`;
  }).join('');
}
window.toggleEmpCard=id=>{const c=document.getElementById(id);if(c)c.classList.toggle('expanded');};
window.saveGrade=(cid,id)=>{const s=document.getElementById(`gsel-${cid}-${id}`);if(!s)return;postNui('changeGrade',{targetId:id,newGrade:parseInt(s.value)});document.getElementById(`ec-${cid}-${id}`)?.classList.remove('expanded');};
window.fireEmp=(id,name)=>{postNui('fireEmployee',{targetId:id});document.querySelectorAll(`[id^="ec-"][id$="-${id}"]`).forEach(el=>el.remove());showNotify({type:'info',title:'Despedido',message:`${name} removido.`});};

document.querySelectorAll('.emp-tab-btn').forEach(b=>b.addEventListener('click',()=>{
  const t=b.dataset.et;
  document.querySelectorAll('.emp-tab-btn').forEach(x=>x.classList.toggle('active',x.dataset.et===t));
  document.getElementById('emp-panel-online').classList.toggle('hidden',t!=='online');
  document.getElementById('emp-panel-duty').classList.toggle('hidden',t!=='duty');
  document.getElementById('emp-panel-offline').classList.toggle('hidden',t!=='offline');
}));

/* SALARIES */
function renderSalaries(d){
  document.getElementById('salary-interval-input').value=d.interval||1;
  const list=document.getElementById('grades-salary-list');
  const g=d.grades||[];
  if(!g.length){list.innerHTML='<p class="empty-msg">Sin rangos.</p>';return;}
  list.innerHTML=[...g].reverse().map(gr=>`
    <div class="grade-salary-row">
      <div class="grade-info"><p class="grade-name">${gr.label}</p><p class="grade-sub">Grado ${gr.grade} — $${gr.salary}</p></div>
      <div class="grade-edit"><input type="number" value="${gr.salary}" min="0" data-grade="${gr.grade}" class="salary-inp"/><button class="btn-primary btn-sm ssal" data-grade="${gr.grade}">OK</button></div>
    </div>`).join('');
  list.querySelectorAll('.ssal').forEach(btn=>{
    btn.addEventListener('click',()=>{
      const grade=parseInt(btn.dataset.grade);
      const amount=parseInt(list.querySelector(`.salary-inp[data-grade="${grade}"]`).value);
      if(isNaN(amount)||amount<0){showNotify({type:'error',title:'Error',message:'Monto inválido.'});return;}
      postNui('updateSalary',{grade,amount});showNotify({type:'success',title:'Guardado',message:`Grado ${grade}: $${amount}.`});
    });
  });
}

/* LOCATIONS */
function renderLocations(d){
  const l=d.locations||{};
  const fmt=v=>v?`X:${v.x.toFixed(1)} Y:${v.y.toFixed(1)} Z:${v.z.toFixed(1)} H:${(v.heading||0).toFixed(1)}`:'—';
  ['stash','clothing','spawn','spawnpoint'].forEach(k=>{
    const el=document.getElementById(`loc-${k}-coords`);
    if(el) el.textContent=fmt(l[k]);
  });
}

/* VEHICLES */
let vehiclePurchases={};  // cache de vehículos comprados

function renderVehicleConfig(d){
  const list=document.getElementById('vehicle-config-list');
  const vehs=d.vehicles||[];
  if(!vehs.length){list.innerHTML='<p class="empty-msg">Sin vehículos.</p>';return;}
  
  // Actualizar cache desde server si viene
  if(d.vehiclePurchases) Object.assign(vehiclePurchases, d.vehiclePurchases);
  
  list.innerHTML=vehs.map(v=>{
    const isPurchased=vehiclePurchases[v.model]===true;
    const price=v.price||0;
    const priceStr=price===0?'Gratis':('$'+price);
    const buyBtn=isPurchased
      ?`<span class="purchase-badge purchased"><i class=""></i> Comprado</span>`
      :`<button class="btn-buy-vehicle" onclick="buyVehicle('${v.model}',${price})"><i class="fas fa-shopping-cart"></i> Comprar ${priceStr}</button>`;
    return `<div class="vehicle-card">
      <i class="fas fa-taxi"></i>
      <p class="veh-label">${v.label}</p>
      <p class="veh-model">${v.model}</p>
      <span class="veh-level-tag">Nivel ${v.minLevel||0}+</span>
      <div class="veh-purchase-section">${buyBtn}</div>
    </div>`;
  }).join('');
}

window.buyVehicle=(model,price)=>{
  postNui('buyVehicle',{model:model});
};

/* TRIPS DISPATCH */
function renderTrips(trips){
  activeTripsCached={};
  const container=document.getElementById('trips-active-panel');
  if(!trips||!trips.length){container.innerHTML='<p class="empty-msg">Sin viajes activos.</p>';return;}
  trips.forEach(t=>{activeTripsCached[t.id]=t;});
  container.innerHTML=trips.map(t=>buildTripCard(t)).join('');
}

function buildTripCard(t){
  const isMyTrip=(myTripId===t.id);
  const statusLabel=t.status==='waiting'?'Esperando':'En curso';
  const driverInfo=t.driverName?`<p class="trip-driver-info"><i class="fas fa-user"></i> ${t.driverName}</p>`:'';
  const actions=t.status==='waiting'
    ?`<button class="btn-trip-accept" onclick="acceptTrip(${t.id})"><i class="fas fa-check"></i> Aceptar</button>
       <button class="btn-trip-cancel" onclick="cancelTrip(${t.id})"><i class="fas fa-times"></i> Cancelar</button>`
    :isMyTrip
      ?`<button class="btn-trip-finish" onclick="finishTrip(${t.id})"><i class="fas fa-flag-checkered"></i> Finalizar</button>
         <button class="btn-trip-cancel" onclick="cancelTrip(${t.id})"><i class="fas fa-times"></i> Cancelar</button>`
      :`<span style="font-size:12px;color:#718096">Viaje en curso por otro taxista</span>`;
  return `<div class="trip-card mb12" id="trip-card-${t.id}">
    <div class="trip-card-header">
      <span class="trip-id">#${t.id}</span>
      <span class="trip-status-badge ${t.status}">${statusLabel}</span>
    </div>
    <div class="trip-zones">
      <div class="trip-zone-row">📍 <strong>Desde:</strong> ${t.fromZone||'Desconocido'}</div>
      <div class="trip-zone-row">🏁 <strong>Hacia:</strong> ${t.toZone||'Desconocido'}</div>
    </div>
    ${driverInfo}
    <div class="trip-actions">${actions}</div>
  </div>`;
}

window.acceptTrip=id=>{postNui('acceptTrip',{tripId:id});};
window.cancelTrip=id=>{postNui('cancelTrip',{tripId:id});};
window.finishTrip=id=>{postNui('finishTrip',{tripId:id});};

/* TRIP CONFIG */
function renderTripConfig(tc){
  if(!tc) return;
  document.getElementById('tc-base').value=tc.basePrice||1500;
  document.getElementById('tc-perunit').value=tc.pricePerUnit||70;
  document.getElementById('tc-meters').value=tc.unitMeters||40;
  const tips=tc.tips||[500,1000,2000,5000];
  ['tip1','tip2','tip3','tip4'].forEach((k,i)=>{
    const el=document.getElementById(`tc-${k}`);if(el)el.value=tips[i]||0;
  });
}

document.getElementById('btn-save-trip-config').addEventListener('click',()=>{
  const cfg={
    basePrice:parseInt(document.getElementById('tc-base').value),
    pricePerUnit:parseInt(document.getElementById('tc-perunit').value),
    unitMeters:parseInt(document.getElementById('tc-meters').value),
    tips:[
      parseInt(document.getElementById('tc-tip1').value),
      parseInt(document.getElementById('tc-tip2').value),
      parseInt(document.getElementById('tc-tip3').value),
      parseInt(document.getElementById('tc-tip4').value),
    ]
  };
  postNui('updateTripConfig',cfg);showNotify({type:'success',title:'Guardado',message:'Configuración de viajes actualizada.'});
});
document.getElementById('btn-save-tips').addEventListener('click',()=>{
  const cfg={
    basePrice:parseInt(document.getElementById('tc-base').value)||1500,
    pricePerUnit:parseInt(document.getElementById('tc-perunit').value)||70,
    unitMeters:parseInt(document.getElementById('tc-meters').value)||40,
    tips:[
      parseInt(document.getElementById('tc-tip1').value)||500,
      parseInt(document.getElementById('tc-tip2').value)||1000,
      parseInt(document.getElementById('tc-tip3').value)||2000,
      parseInt(document.getElementById('tc-tip4').value)||5000,
    ]
  };
  postNui('updateTripConfig',cfg);showNotify({type:'success',title:'Guardado',message:'Propinas actualizadas.'});
});

/* PERMISSIONS */
let permsCache={};  // espejo del estado guardado en el server (panel_perms.json)

function renderPermissions(perms,grades,isOwner,canEdit){
  const container=document.getElementById('perms-grid');
  if(!isOwner){container.innerHTML='';return;}
  if(!grades||!grades.length){container.innerHTML='<p class="empty-msg">Sin rangos.</p>';return;}

  // Cuando el server manda perms (desde JSON), SIEMPRE sobreescribimos el cache completo.
  // El JSON es la fuente de verdad — nunca bloqueamos su carga con flags dirty.
  if(perms){
    // Limpiar todo el cache anterior (incluyendo flags _dirty_)
    permsCache={};
    Object.keys(perms).forEach(k=>{
      const sk=String(k);
      permsCache[sk]={};
      Object.keys(perms[k]).forEach(panel=>{
        permsCache[sk][panel]=!!perms[k][panel];
      });
    });
  }

  const eligibleGrades=grades.filter(g=>!g.isOwner&&g.grade<=4);

  // Si el contenedor ya tiene las tarjetas construidas, solo actualizar los checkboxes
  if(container.querySelectorAll('.perm-grade-card').length===eligibleGrades.length){
    eligibleGrades.forEach(g=>{
      const sk=String(g.grade);
      const gp=permsCache[sk]||{};
      PANELS.forEach(panel=>{
        const cb=container.querySelector(`input[data-grade="${g.grade}"][data-panel="${panel}"]`);
        if(cb) cb.checked=gp[panel]===true;
      });
    });
    return;
  }

  // Primera vez (o reconstrucción): construir el HTML completo
  container.innerHTML=eligibleGrades.map(g=>{
    const sk=String(g.grade);
    const gp=permsCache[sk]||{};
    const panelRows=PANELS.map(panel=>{
      const checked=gp[panel]===true?'checked':'';
      return `<div class="perm-item">
        <span class="perm-item-label">${PANEL_LABELS[panel]}</span>
        <label class="toggle-switch">
          <input type="checkbox" ${checked} data-grade="${g.grade}" data-panel="${panel}" onchange="updatePerm(this)"/>
          <span class="toggle-slider"></span>
        </label>
      </div>`;
    }).join('');
    return `<div class="perm-grade-card">
      <div class="perm-grade-header"><i class="fas fa-user-tag"></i> ${g.label} (Grado ${g.grade})</div>
      <div class="perm-panels">${panelRows}</div>
    </div>`;
  }).join('');
}

window.updatePerm=function(el){
  const grade=parseInt(el.dataset.grade);
  const panel=el.dataset.panel;
  const allowed=el.checked;
  const sk=String(grade);
  // Actualizar cache local para feedback visual inmediato
  if(!permsCache[sk]) permsCache[sk]={};
  permsCache[sk][panel]=allowed;
  // Enviar al server → guarda en panel_perms.json → broadcast permissionsUpdated
  postNui('updatePermission',{grade,panel,allowed});
};

/* HOTKEYS */
// Nombres de los 5 slots de la interfaz del civil
const HOTKEY_SLOT_LABELS=[
  'Propina opción 1 (civil)','Propina opción 2 (civil)','Propina opción 3 (civil)',
  'Propina opción 4 (civil)','Cambiar destino (civil)','Aceptar viaje rápido (taxista)'
];

let hotkeysCached=[];

function renderHotkeys(hotkeys, canEdit){
  hotkeysCached=hotkeys||[];
  const grid=document.getElementById('hotkeys-grid');
  const warn=document.getElementById('hotkeys-perm-warn');
  const form=document.getElementById('hotkeys-form');
  if(!grid||!form) return;
  if(!canEdit){
    if(warn) warn.classList.remove('hidden');
    form.classList.add('hidden');
    return;
  }
  if(warn) warn.classList.add('hidden');
  form.classList.remove('hidden');
  const slots=Array.from({length:6},(_,i)=>{
    const existing=hotkeys.find(h=>h.slot===i+1)||{slot:i+1,label:HOTKEY_SLOT_LABELS[i]||'Botón '+(i+1),key:String(i+1)};
    return existing;
  });
  grid.innerHTML=slots.map(s=>`
    <div class="hotkey-row">
      <span class="hotkey-action">${HOTKEY_SLOT_LABELS[s.slot-1]||'Botón '+s.slot}</span>
      <span class="hotkey-label" style="font-size:11px;color:#718096">Etiqueta:</span>
      <input class="sh-input-sm hk-label-input" data-slot="${s.slot}" type="text" maxlength="32" value="${s.label||''}" placeholder="Texto del botón" style="flex:1;background:rgba(0,0,0,.4);border:1px solid rgba(255,255,255,.1);border-radius:7px;color:#e2e8f0;padding:6px 10px;font-size:12px;outline:none"/>
      <span class="hotkey-label" style="font-size:11px;color:#718096;margin-left:8px">Tecla:</span>
      <input class="hotkey-input hk-key-input" data-slot="${s.slot}" maxlength="1" value="${s.key||String(s.slot)}" placeholder="${s.slot}"/>
    </div>`).join('');
  // Capturar tecla al hacer focus
  grid.querySelectorAll('.hk-key-input').forEach(inp=>{
    inp.addEventListener('keydown',function(e){
      e.preventDefault();
      const k=e.key.length===1?e.key.toUpperCase():(e.key==='Escape'?'':e.key.slice(0,3).toUpperCase());
      if(k) this.value=k;
    });
  });
}

document.getElementById('btn-save-hotkeys')?.addEventListener('click',()=>{
  const rows=document.querySelectorAll('#hotkeys-grid .hotkey-row');
  const data=Array.from(rows).map(row=>{
    const slot=parseInt(row.querySelector('.hk-key-input').dataset.slot);
    const key=row.querySelector('.hk-key-input').value.trim().slice(0,8);
    const label=row.querySelector('.hk-label-input').value.trim().slice(0,64);
    return {slot,key,label};
  });
  postNui('saveHotkeys',{hotkeys:data});
});

/* HOTKEY ACTION HANDLER */
function handleHotkeySlot(slot){
  // Los 4 primeros slots son propinas, el 5 es cambiar destino
  const tipBtns=document.querySelectorAll('#ct-tip-buttons .tip-btn');
  if(slot>=1&&slot<=4){
    if(tipBtns[slot-1]){
      tipBtns[slot-1].click();
    }
  } else if(slot===5){
    const changeBtn=document.getElementById('btn-change-dest');
    if(changeBtn&&!changeBtn.classList.contains('hidden')&&!changeBtn.disabled){
      changeBtn.click();
    }
  }
}

/* INVITE */
function renderInvite(d){
  const g=d.grades||[];
  document.getElementById('invite-grade-select').innerHTML=g.map(gr=>`<option value="${gr.grade}">${gr.label}</option>`).join('');
}

/* VIAJES REALIZADOS */
function renderTripHistory(trips){
  const list=document.getElementById('trip-history-list');
  if(!trips||!trips.length){list.innerHTML='<p class="empty-msg">Sin viajes registrados aún.</p>';return;}
  list.innerHTML=trips.map(t=>{
    const date=new Date((t.finished_at||0)*1000);
    const dateStr=`${String(date.getDate()).padStart(2,'0')}/${String(date.getMonth()+1).padStart(2,'0')} ${String(date.getHours()).padStart(2,'0')}:${String(date.getMinutes()).padStart(2,'0')}`;
    const meters=t.meters>=1000?`${(t.meters/1000).toFixed(1)} km`:`${t.meters||0} m`;
    return `<div class="trip-hist-card">
      <div class="trip-hist-top">
        <span class="trip-hist-driver"><i class="fas fa-user"></i> ${t.driver_name||'Desconocido'}</span>
        <span class="trip-hist-date">${dateStr}</span>
      </div>
      <div class="trip-hist-amounts">
        <div class="trip-hist-row">
          <span class="trip-hist-label"><i class="fas fa-building"></i> Ingreso a sociedad</span>
          <span class="trip-hist-val green">$${t.trip_cost||0}</span>
        </div>
        <div class="trip-hist-row">
          <span class="trip-hist-label"><i class="fas fa-hand-holding-usd"></i> Propina recibida</span>
          <span class="trip-hist-val ${(t.tip||0)>0?'yellow':'muted'}">$${t.tip||0}</span>
        </div>
        <div class="trip-hist-row">
          <span class="trip-hist-label"><i class="fas fa-road"></i> Distancia</span>
          <span class="trip-hist-val">${meters}</span>
        </div>
      </div>
    </div>`;
  }).join('');
}

/* CUENTA EMPRESA */
function renderSocietyData(data){
  if(!data) return;
  const bal=document.getElementById('empresa-balance');
  if(bal) bal.textContent='$'+(data.balance||0).toLocaleString();
  const logList=document.getElementById('empresa-log-list');
  if(!logList) return;
  const logs=data.logs||[];
  if(!logs.length){logList.innerHTML='<p class="empty-msg">Sin movimientos.</p>';return;}
  const typeIcon={trip:'fa-taxi',deposit:'fa-arrow-up',withdraw:'fa-arrow-down',bonus:'fa-gift'};
  const typeColor={trip:'green',deposit:'green',withdraw:'red',bonus:'yellow'};
  logList.innerHTML=logs.map(l=>{
    const d=new Date((l.created_at||0)*1000);
    const ds=`${String(d.getDate()).padStart(2,'0')}/${String(d.getMonth()+1).padStart(2,'0')} ${String(d.getHours()).padStart(2,'0')}:${String(d.getMinutes()).padStart(2,'0')}`;
    const amt=l.amount||0;
    const sign=amt>=0?'+':'';
    return `<div class="empresa-log-row">
      <span class="empresa-log-icon ${typeColor[l.type]||''}"><i class="fas ${typeIcon[l.type]||'fa-circle'}"></i></span>
      <div class="empresa-log-info">
        <p class="empresa-log-desc">${l.description||'—'}</p>
        <p class="empresa-log-by">${l.done_by||'Sistema'} · ${ds}</p>
      </div>
      <span class="empresa-log-amt ${amt>=0?'green':'red'}">${sign}$${Math.abs(amt).toLocaleString()}</span>
    </div>`;
  }).join('');
}

// Botones empresa
document.getElementById('btn-empresa-deposit')?.addEventListener('click',()=>{
  const amt=parseInt(document.getElementById('empresa-deposit-amt')?.value);
  if(!amt||amt<=0){showNotify({type:'error',title:'Error',message:'Ingresá un monto válido.'});return;}
  postNui('societyDeposit',{amount:amt});
  document.getElementById('empresa-deposit-amt').value='';
});
document.getElementById('btn-empresa-withdraw')?.addEventListener('click',()=>{
  const amt=parseInt(document.getElementById('empresa-withdraw-amt')?.value);
  if(!amt||amt<=0){showNotify({type:'error',title:'Error',message:'Ingresá un monto válido.'});return;}
  postNui('societyWithdraw',{amount:amt});
  document.getElementById('empresa-withdraw-amt').value='';
});
document.getElementById('btn-empresa-bonus')?.addEventListener('click',()=>{
  const id=parseInt(document.getElementById('empresa-bonus-id')?.value);
  const amt=parseInt(document.getElementById('empresa-bonus-amt')?.value);
  if(!id||!amt||amt<=0){showNotify({type:'error',title:'Error',message:'Completá ID y monto.'});return;}
  postNui('societyBonus',{targetId:id,amount:amt});
  document.getElementById('empresa-bonus-id').value='';
  document.getElementById('empresa-bonus-amt').value='';
});

/* SERVICE LOGS */
function fmtTime(sec){const d=new Date(sec*1000);return `${String(d.getHours()).padStart(2,'0')}:${String(d.getMinutes()).padStart(2,'0')} hs`;}
function fmtDuration(sec){
  if(!sec||sec<=0) return '0 seg';
  const h=Math.floor(sec/3600),m=Math.floor((sec%3600)/60),s=sec%60;
  const parts=[];
  if(h>0) parts.push(h+' hora'+(h!==1?'s':''));
  if(m>0) parts.push(m+' minuto'+(m!==1?'s':''));
  if(s>0||!parts.length) parts.push(s+' seg');
  return parts.join(' ');
}
function renderServiceLogs(logs){
  const list=document.getElementById('service-log-list');
  if(!logs||!logs.length){list.innerHTML='<p class="empty-msg">Sin registros.</p>';return;}
  list.innerHTML=logs.map(log=>{
    const isStart=log.action==='start';
    const timeStr=fmtTime(log.log_time||0);
    const durStr=(log.duration&&log.duration>0)?`<p class="log-duration"><i class="fas fa-clock"></i> ${fmtDuration(log.duration)} en servicio</p>`:'';
    return `<div class="log-entry ${log.action}">
      <div class="log-icon"><i class="fas ${isStart?'fa-play':'fa-stop'}"></i></div>
      <div><p class="log-name">${log.player_name}</p>
        <p class="log-detail">${isStart?`Inicia servicio a las ${timeStr}`:`Finaliza servicio a las ${timeStr}`}</p>
        ${durStr}</div></div>`;
  }).join('');
}
function prependLogEntry(log){
  const list=document.getElementById('service-log-list');
  const empty=list.querySelector('.empty-msg');if(empty)empty.remove();
  const isStart=log.action==='start';
  const timeStr=fmtTime(log.time||0);
  const durStr=(log.duration&&log.duration>0)?`<p class="log-duration"><i class="fas fa-clock"></i> ${fmtDuration(log.duration)} en servicio</p>`:'';
  const el=document.createElement('div');
  el.className=`log-entry ${log.action}`;
  el.innerHTML=`<div class="log-icon"><i class="fas ${isStart?'fa-play':'fa-stop'}"></i></div>
    <div><p class="log-name">${log.name}</p>
      <p class="log-detail">${isStart?`Inicia servicio a las ${timeStr}`:`Finaliza servicio a las ${timeStr}`}</p>
      ${durStr}</div>`;
  list.insertBefore(el,list.firstChild);
}
document.getElementById('btn-refresh-log').addEventListener('click',()=>postNui('getServiceLogs'));
document.getElementById('btn-refresh-trip-history')?.addEventListener('click',()=>postNui('getTripHistory'));
document.getElementById('btn-clear-trip-history')?.addEventListener('click',()=>{
  // Usar modal interno — confirm() congela la UI en FiveM
  showConfirmModal('¿Limpiar historial de viajes?','Esta acción borra todos los registros.',()=>{
    postNui('clearTripHistory');
    document.getElementById('trip-history-list').innerHTML='<p class="empty-msg">Historial limpiado.</p>';
  });
});

/* XP */
function renderXP(xpData,levels){
  if(!xpData) return;
  const lvl=xpData.level||0;
  const xp=xpData.xp||0;
  document.getElementById('xp-level-badge').textContent=lvl;
  const curLvlData=levels&&levels[lvl]?levels[lvl]:{label:'Nivel '+lvl,xpRequired:0};
  const nextLvlData=levels&&levels[lvl+1]?levels[lvl+1]:null;
  document.getElementById('xp-level-name').textContent=curLvlData.label;
  const nextXp=nextLvlData?nextLvlData.xpRequired:xp;
  const curXpReq=curLvlData.xpRequired||0;
  const pct=nextLvlData?Math.min(100,Math.round(((xp-curXpReq)/(nextXp-curXpReq))*100)):100;
  document.getElementById('xp-label').textContent=nextLvlData?`${xp} / ${nextXp} XP`:`${xp} XP (Nivel máximo)`;
  document.getElementById('xp-bar-fill').style.width=pct+'%';
  // Lista de niveles
  const list=document.getElementById('levels-list');
  if(levels){
    list.innerHTML=Object.entries(levels).sort((a,b)=>parseInt(a[0])-parseInt(b[0])).map(([lNum,lData])=>{
      const isCurrent=parseInt(lNum)===lvl;
      return `<div class="level-row ${isCurrent?'level-current':''}">
        <div class="level-num">${lNum}</div>
        <div class="level-info"><p class="level-name">${lData.label}</p><p class="level-xp">${lData.xpRequired} XP requerida</p></div>
        ${isCurrent?'<span style="font-size:11px;color:#9f7aea">← actual</span>':''}
      </div>`;
    }).join('');
  }
}

/* MARKER */
function syncMarkerUI(cfg){
  const mt=document.getElementById('marker-type-select');
  const mc=document.getElementById('marker-color-select');
  const sxy=document.getElementById('marker-scalexy');
  const sz=document.getElementById('marker-scalez');
  if(mt) mt.value=cfg.markerType??1;
  if(mc){const k=Object.entries(COLORS).find(([_,v])=>v.name===cfg.colorName)?.[0];if(k)mc.value=k;}
  if(sxy){sxy.value=cfg.scaleXY??1.5;document.getElementById('sxy-val').textContent=parseFloat(cfg.scaleXY??1.5).toFixed(1);}
  if(sz){sz.value=cfg.scaleZ??0.5;document.getElementById('sz-val').textContent=parseFloat(cfg.scaleZ??0.5).toFixed(1);}
}
document.getElementById('marker-scalexy').addEventListener('input',function(){document.getElementById('sxy-val').textContent=parseFloat(this.value).toFixed(1);});
document.getElementById('marker-scalez').addEventListener('input',function(){document.getElementById('sz-val').textContent=parseFloat(this.value).toFixed(1);});
document.getElementById('btn-save-marker').addEventListener('click',()=>{
  const mt=parseInt(document.getElementById('marker-type-select').value);
  const ck=document.getElementById('marker-color-select').value;
  const col=COLORS[ck]||COLORS.celeste;
  const sxy=parseFloat(document.getElementById('marker-scalexy').value);
  const sz=parseFloat(document.getElementById('marker-scalez').value);
  postNui('updateMarkerConfig',{markerType:mt,colorName:col.name,r:col.r,g:col.g,b:col.b,a:160,scaleXY:sxy,scaleZ:sz});
  showNotify({type:'success',title:'Markers actualizados',message:'Aplicado a todos los puntos.'});
});

/* LOC BUTTONS */
[['stash','btn-stash-here','btn-stash-manual'],['clothing','btn-clothing-here','btn-clothing-manual'],
 ['spawn','btn-spawn-here','btn-spawn-manual'],['spawnpoint','btn-spawnpoint-here','btn-spawnpoint-manual']
].forEach(([lt,hId,mId])=>{
  document.getElementById(hId).addEventListener('click',()=>{postNui('setLocationHere',{locType:lt});showNotify({type:'success',title:'Movido',message:'Ubicación actualizada.'});});
  document.getElementById(mId).addEventListener('click',()=>{state.currentLocType=lt;openModal('Coords — '+lt);});
});

document.getElementById('btn-save-interval').addEventListener('click',()=>{
  const v=parseInt(document.getElementById('salary-interval-input').value);
  if(isNaN(v)||v<1){showNotify({type:'error',title:'Error',message:'Mínimo 1 min.'});return;}
  postNui('updateSalaryInterval',{interval:v});showNotify({type:'success',title:'Guardado',message:`Pago cada ${v} min.`});
});

document.getElementById('btn-invite-id').addEventListener('click',()=>{
  const id=parseInt(document.getElementById('invite-id-input').value);
  const grade=parseInt(document.getElementById('invite-grade-select').value);
  if(isNaN(id)||id<1){showNotify({type:'error',title:'Error',message:'ID inválido.'});return;}
  postNui('inviteById',{targetId:id,grade});document.getElementById('invite-id-input').value='';
});
document.getElementById('btn-invite-nearby').addEventListener('click',()=>{
  postNui('inviteNearby',{grade:parseInt(document.getElementById('invite-grade-select').value)});
});

document.getElementById('btn-close-tablet').addEventListener('click',closeTablet);

/* MODAL */
function openModal(title){
  state.modalOpen=true;document.getElementById('modal-title').textContent=title;
  ['modal-x','modal-y','modal-z','modal-heading'].forEach(id=>document.getElementById(id).value='');
  document.getElementById('modal-overlay').classList.remove('hidden');
}
function closeModal(){
  state.modalOpen=false;state.currentLocType=null;
  document.getElementById('modal-overlay').classList.add('hidden');
}
document.getElementById('btn-close-modal').addEventListener('click',closeModal);
document.getElementById('btn-modal-cancel').addEventListener('click',closeModal);
document.getElementById('btn-modal-confirm').addEventListener('click',()=>{
  const x=parseFloat(document.getElementById('modal-x').value);
  const y=parseFloat(document.getElementById('modal-y').value);
  const z=parseFloat(document.getElementById('modal-z').value);
  const h=parseFloat(document.getElementById('modal-heading').value)||0;
  if(isNaN(x)||isNaN(y)||isNaN(z)){showNotify({type:'error',title:'Error',message:'Completá X, Y, Z.'});return;}
  postNui('setLocationManual',{locType:state.currentLocType,x,y,z,heading:h});
  showNotify({type:'success',title:'Guardado',message:'Coordenadas actualizadas.'});closeModal();
});

/* VEHICLE MENU */
function openVehicleMenu(vehicles,hasCar,playerLevel,purchaseData){
  state.vmenuOpen=true;
  const list=document.getElementById('vmenu-list');
  const lvl=playerLevel||0;
  const purchases=purchaseData||{};
  list.innerHTML=(vehicles||[]).map(v=>{
    const minLvl=v.minLevel||0;
    const levelLocked=lvl<minLvl;
    const isPurchased=purchases[v.model]===true;
    const notPurchased=!isPurchased;
    const locked=levelLocked||notPurchased;
    const lockReason=levelLocked?`Nivel ${minLvl}`:notPurchased?'No comprado':'';
    return `<div class="vmenu-item${locked?' locked':''}" ${!locked?`onclick="spawnFromMenu('${v.model}')"`:''}> 
      <div class="vmenu-item-icon"><i class="fas fa-taxi"></i></div>
      <div class="vmenu-item-info"><p class="vmenu-item-label">${v.label}</p><p class="vmenu-item-model">${v.model}</p></div>
      <span class="vmenu-level-tag">${locked?`<i class="fas fa-lock"></i> ${lockReason}`:'Disponible'}</span>
    </div>`;
  }).join('');
  document.getElementById('vehicle-menu-overlay').classList.remove('hidden');
}
function closeVehicleMenu(){
  state.vmenuOpen=false;document.getElementById('vehicle-menu-overlay').classList.add('hidden');postNui('closeVehicleMenu');
}
window.spawnFromMenu=model=>{postNui('spawnVehicle',{model});closeVehicleMenu();};
document.getElementById('btn-close-vmenu').addEventListener('click',closeVehicleMenu);
document.getElementById('btn-store-veh').addEventListener('click',()=>{postNui('storeCurrentVehicle');closeVehicleMenu();});

/* ══ CLIENT TRIP UI ══ */
let clientTripTip=0;
let clientTripPending=false;  // hay viaje activo como civil
let clientHotkeys=[];   // hotkeys recibidos del server

function showClientTripUI(data){
  clientTripTip=0;canChangeWp=true;clientTripPending=true;
  if(data.hotkeys) clientHotkeys=data.hotkeys;
  const overlay=document.getElementById('client-trip-overlay');
  overlay.classList.remove('hidden');
  const ct=document.getElementById('ct-cost');
  ct.textContent='$'+(data.basePrice||0);
  document.getElementById('ct-total').textContent='$'+(data.basePrice||0);
  document.getElementById('ct-meters').textContent='0 m';
  document.getElementById('ct-tip').textContent='$0';
  const tipBtns=document.getElementById('ct-tip-buttons');
  const tips=data.tips||[500,1000,2000,5000];
  // Mostrar tecla configurada junto a cada botón de propina
  tipBtns.innerHTML=tips.map((t,i)=>{
    const slot=i+1;
    const k=CFG_HOTKEYS[slot]||'';
    const keyHint=k?`<kbd>${k}</kbd> `:'';
    return `<button class="tip-btn" data-amount="${t}" onclick="selectTip(${t})">${keyHint}$${t}</button>`;
  }).join('');
  // Botón cambiar destino con tecla del config
  const destKey=CFG_HOTKEYS[5]||'';
  const changeBtn=document.getElementById('btn-change-dest');
  if(changeBtn){
    changeBtn.innerHTML=`<i class="fas fa-map-marker-alt"></i> Cambiar destino (1 vez)${destKey?` <kbd>${destKey}</kbd>`:''}`;
    changeBtn.classList.remove('hidden');
  }
}

window.selectTip=function(amount){
  clientTripTip=amount;
  document.querySelectorAll('.tip-btn').forEach(b=>b.classList.toggle('selected',parseInt(b.dataset.amount)===amount));
  document.getElementById('ct-tip').textContent='$'+amount;
  const curCost=parseInt((document.getElementById('ct-cost').textContent||'$0').replace('$',''))||0;
  document.getElementById('ct-total').textContent='$'+(curCost+amount);
  // Confirmación visual
  const tipInfo=document.getElementById('ct-tip-info');
  if(tipInfo) tipInfo.textContent=amount>0?`Vas a dejar $${amount} de propina al finalizar el viaje.`:'Sin propina.';
  postNui('leaveTip',{amount});
};

document.getElementById('btn-change-dest').addEventListener('click',()=>{
  if(!canChangeWp){showNotify({type:'error',title:'Sin cambios',message:'Solo se puede cambiar el destino una vez.'});return;}
  postNui('changeWaypoint');
  canChangeWp=false;
  document.getElementById('btn-change-dest').classList.add('hidden');
});

/* ══ DRIVER TRIP ACTIVE (en dashboard) ══ */
function showDriverTripActive(trip){
  myTripId=trip.id; myTripTip=0;
  const d=document.getElementById('active-trip-dashboard');
  d.classList.remove('hidden');
  document.getElementById('atrip-dest').textContent=trip.toZone||'Desconocido';
  document.getElementById('atrip-cost').textContent='$'+trip.basePrice;
  document.getElementById('atrip-meters').textContent='0 m';
  document.getElementById('atrip-tip').textContent='$0';
  // Botones del dashboard
  document.getElementById('btn-finish-trip').onclick=()=>postNui('finishTrip',{tripId:myTripId});
  document.getElementById('btn-cancel-active-trip').onclick=()=>postNui('cancelTrip',{tripId:myTripId});
}

/* ══ ESC ══ */
function handleEscape(){
  if(state.modalOpen){closeModal();return;}
  if(state.vmenuOpen){closeVehicleMenu();return;}
  if(state.open){closeTablet();return;}
  // UI del civil — el Lua ya cerró el focus, solo escondemos
  const cto=document.getElementById('client-trip-overlay');
  if(cto&&!cto.classList.contains('hidden')){
    cto.classList.add('hidden');
    postNui('closeClientUI');
  }
}

/* ══ COMPANY NAME ══ */
let _isOwnerGlobal = false;
let _myNoteCid = null; // citizenid del jugador actual
const notesCache = {}; // cid → entry

function initCompanyName(){
  const display = document.getElementById('company-name-display');
  const editBtn = document.getElementById('btn-edit-company-name');
  if(!display || !editBtn) return;
  display.addEventListener('click', () => {
    if(!_isOwnerGlobal) return;
    openEditCompanyModal(display.textContent.trim());
  });
  editBtn.addEventListener('click', () => openEditCompanyModal(display.textContent.trim()));
}

function setCompanyNameUI(name){
  const display = document.getElementById('company-name-display');
  const editBtn = document.getElementById('btn-edit-company-name');
  if(display) display.textContent = name || 'Taxi Corp';
  if(editBtn) editBtn.classList.toggle('hidden', !_isOwnerGlobal);
  if(display) display.classList.toggle('editable', _isOwnerGlobal);
}

function openEditCompanyModal(current){
  const existing = document.getElementById('edit-company-overlay');
  if(existing) existing.remove();
  const el = document.createElement('div');
  el.id = 'edit-company-overlay';
  el.innerHTML = `<div class="edit-company-box">
    <h4><i class="fas fa-taxi"></i> Cambiar nombre de la empresa</h4>
    <input id="edit-company-input" type="text" maxlength="64" value="${(current||'').replace(/"/g,'&quot;')}" placeholder="Taxi Corp"/>
    <div class="edit-company-btns">
      <button class="btn-outline" id="edit-company-cancel">Cancelar</button>
      <button class="btn-primary" id="edit-company-save"><i class="fas fa-save"></i> Guardar</button>
    </div>
  </div>`;
  document.body.appendChild(el);
  const inp = document.getElementById('edit-company-input');
  inp.focus(); inp.select();
  document.getElementById('edit-company-cancel').onclick = () => el.remove();
  document.getElementById('edit-company-save').onclick = () => {
    const name = inp.value.trim();
    if(!name){ showNotify({type:'error',title:'Error',message:'El nombre no puede estar vacío.'}); return; }
    postNui('setCompanyName', {name});
    el.remove();
  };
  el.addEventListener('click', e => { if(e.target===el) el.remove(); });
  inp.addEventListener('keydown', e => { if(e.key==='Enter') document.getElementById('edit-company-save').click(); if(e.key==='Escape') el.remove(); });
}

/* ══ NOTAS ══ */
function initNotes(){
  const inp = document.getElementById('my-note-input');
  const charEl = document.getElementById('note-char');
  if(inp && charEl){
    inp.addEventListener('input', () => { charEl.textContent = inp.value.length; });
  }
  const btnSave = document.getElementById('btn-save-note');
  if(btnSave) btnSave.addEventListener('click', () => {
    const text = (document.getElementById('my-note-input').value||'').trim();
    if(!text){ showNotify({type:'error',title:'Vacía',message:'Escribí algo antes de guardar.'}); return; }
    postNui('saveNote', {note: text});
    showNotify({type:'success',title:'Guardado',message:'Tu nota fue guardada.'});
  });
  const btnDel = document.getElementById('btn-delete-note');
  if(btnDel) btnDel.addEventListener('click', () => {
    postNui('deleteNote', {targetCid: null});  // null = borra la propia
    document.getElementById('my-note-input').value = '';
    document.getElementById('note-char').textContent = '0';
    showNotify({type:'info',title:'Eliminada',message:'Tu nota fue eliminada.'});
  });
  const btnPlace = document.getElementById('btn-place-board');
  if(btnPlace) btnPlace.addEventListener('click', () => {
    const text = (document.getElementById('my-note-input').value||'').trim();
    if(!text){ showNotify({type:'error',title:'Vacía',message:'Guardá una nota primero.'}); return; }
    postNui('placeBoardNote', {note: text});
    showNotify({type:'success',title:'Pizarra','message':'Nota colocada en el mundo.'});
  });
  const btnRemove = document.getElementById('btn-remove-board');
  if(btnRemove) btnRemove.addEventListener('click', () => {
    postNui('removeBoardNote');
    showNotify({type:'info',title:'Pizarra',message:'Nota quitada del mundo.'});
  });
}

function renderNotes(rows){
  const list = document.getElementById('notes-list');
  if(!list) return;
  if(rows) rows.forEach(r => { notesCache[r.citizenid] = r; });
  const all = Object.values(notesCache);
  if(!all.length){ list.innerHTML='<p class="empty-msg">Sin notas aún.</p>'; return; }
  all.sort((a,b)=>(b.updated_at||0)-(a.updated_at||0));
  const myCid = state.data && state.data.myCid;
  const isOwnerOrBoss = _isOwnerGlobal || (state.data && (state.data.myGrade||0) >= 3);
  list.innerHTML = all.map(n => {
    const d = n.updated_at ? new Date(n.updated_at*1000).toLocaleString('es-AR',{day:'2-digit',month:'2-digit',hour:'2-digit',minute:'2-digit'}) : '';
    const canDelete = isOwnerOrBoss || (myCid && n.citizenid === myCid);
    const delBtn = canDelete
      ? `<button class="note-card-del" onclick="deleteNoteCard('${n.citizenid}')" title="Eliminar nota"><i class="fas fa-trash"></i></button>`
      : '';
    return `<div class="note-card" id="note-card-${n.citizenid}">
      <div class="note-card-header">
        <span class="note-card-author"><i class="fas fa-user"></i> ${n.player_name||'?'}</span>
        <div style="display:flex;align-items:center;gap:8px">
          <span class="note-card-date">${d}</span>
          ${delBtn}
        </div>
      </div>
      <p class="note-card-text">${escHtml(n.note||'')}</p>
    </div>`;
  }).join('');
}

window.deleteNoteCard = function(cid){
  postNui('deleteNote', {targetCid: cid});
  // Optimistic UI — se confirma vía noteDeleted broadcast
  const card = document.getElementById(`note-card-${cid}`);
  if(card) card.style.opacity = '0.4';
};

function escHtml(s){ return s.replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;').replace(/"/g,'&quot;'); }

function applyNoteUpdate(entry){
  notesCache[entry.citizenid] = entry;
  renderNotes(null);
}
function applyNoteDelete(cid){
  delete notesCache[cid];
  renderNotes(null);
}

// Cuando se abre la pestaña notas, pedir lista fresca
const _origSetTab = window.setTab;
document.querySelectorAll('.nav-btn').forEach(b => b.addEventListener('click', () => {
  if(b.dataset.tab === 'notas') postNui('getNotes');
}));

/* ══ NUI MESSAGES ══ */
// ── Modal de confirmación (sin confirm() que congela FiveM) ──
function showConfirmModal(title, msg, onConfirm){
  const existing=document.getElementById('sh-confirm-modal');
  if(existing) existing.remove();
  const el=document.createElement('div');
  el.id='sh-confirm-modal';
  el.style.cssText='position:fixed;inset:0;background:rgba(0,0,0,.6);z-index:9000;display:flex;align-items:center;justify-content:center;';
  el.innerHTML=`<div style="background:#0b0f18;border:1px solid rgba(255,255,255,.12);border-radius:14px;padding:24px 28px;width:340px;text-align:center;">
    <p style="font-size:15px;font-weight:700;color:#f7fafc;margin-bottom:8px;">${title}</p>
    <p style="font-size:13px;color:#718096;margin-bottom:20px;">${msg}</p>
    <div style="display:flex;gap:10px;justify-content:center;">
      <button id="sh-confirm-no" style="background:transparent;border:1px solid rgba(255,255,255,.1);border-radius:9px;color:#a0aec0;padding:9px 22px;cursor:pointer;font-size:13px;">Cancelar</button>
      <button id="sh-confirm-yes" style="background:#fc8181;border:none;border-radius:9px;color:#fff;padding:9px 22px;cursor:pointer;font-size:13px;font-weight:600;">Confirmar</button>
    </div>
  </div>`;
  document.body.appendChild(el);
  document.getElementById('sh-confirm-yes').onclick=()=>{el.remove();onConfirm();};
  document.getElementById('sh-confirm-no').onclick=()=>el.remove();
}

window.addEventListener('message',e=>{
  const m=e.data;if(!m||!m.action)return;
  switch(m.action){
    case 'openTablet':         openTablet({isOwner:m.isOwner,onDuty:m.onDuty,msToNext:m.msToNext});break;
    case 'closeTablet':        if(state.open)closeTablet();break;
    case 'updateTabletData':   updateTabletData(m.data);break;
    case 'permissionsUpdated': {
      // El server confirmó guardado en panel_perms.json — sincronizar cache completo
      if(m.permissions && state.data){
        // Reemplazar cache completo con los datos confirmados del servidor (JSON)
        permsCache={};
        Object.keys(m.permissions).forEach(k=>{
          const sk=String(k);
          permsCache[sk]={};
          Object.keys(m.permissions[k]).forEach(panel=>{
            permsCache[sk][panel]=!!m.permissions[k][panel];
          });
        });
        // Guardar en state.data para que reaperturas de tablet usen estos valores
        state.data.permissions = m.permissions;
        if(state.data.isOwner){
          // Siempre re-renderizar: actualiza checkboxes con el cache nuevo
          renderPermissions(null, state.data.grades, state.data.isOwner, state.data.canEdit||{});
        }
      }
    }break;
    case 'vehiclePurchased':   vehiclePurchases[m.model]=true;renderVehicleConfig(state.data);break;
    case 'updateVehiclePurchases': vehiclePurchases=m.purchases||{};if(state.vmenuOpen)openVehicleMenu(state.vmenuVehicles,state.vmenuHasCar,state.vmenuLevel,vehiclePurchases);break;
    case 'dutyState':          updateDutyUI(m.onDuty,m.msToNext);break;
    case 'updateNextPay':      countdownMs=m.ms;updateCountdownDisplay(true);break;
    case 'tickCountdown':      countdownMs=m.ms;updateCountdownDisplay(true);break;
    case 'openVehicleMenu':    state.vmenuVehicles=m.vehicles;state.vmenuHasCar=m.hasCar;state.vmenuLevel=m.playerLevel;openVehicleMenu(m.vehicles,m.hasCar,m.playerLevel,m.purchaseData);break;
    case 'serviceLogEntry':    prependLogEntry(m.entry);break;
    case 'receiveServiceLogs': renderServiceLogs(m.logs);break;
    case 'receiveTripHistory':  renderTripHistory(m.trips||m.rows||[]);break;
    case 'receiveSocietyData':  renderSocietyData(m);break;
    case 'xpUpdate':           renderXP({xp:m.xp,level:m.level},state.data&&state.data.levels);
                               if(m.gained>0) showNotify({type:'success',title:'XP Ganada',message:`+${m.gained} XP`});break;
    // Nombre empresa
    case 'receiveCompanyName':  setCompanyNameUI(m.name);break;
    // Notas
    case 'receiveNotes':        renderNotes(m.notes||[]);break;
    case 'noteUpdated':         applyNoteUpdate(m.entry);break;
    case 'noteDeleted':         applyNoteDelete(m.cid);break;
    // TRIPS
    case 'newTripRequest':     {
      const c=document.getElementById('trips-active-panel');
      const empty=c.querySelector('.empty-msg');if(empty)empty.remove();
      const el=document.createElement('div');el.innerHTML=buildTripCard(m.trip);
      c.insertBefore(el.firstChild,c.firstChild);
      activeTripsCached[m.trip.id]=m.trip;
      document.getElementById('stat-trips').textContent=Object.keys(activeTripsCached).length;
    }break;
    case 'showTripNotify':     showTripNotify(m.trip);break;
    case 'tripTaken':          {
      const card=document.getElementById(`trip-card-${m.tripId}`);
      if(card){
        const actions=card.querySelector('.trip-actions');
        if(actions) actions.innerHTML='<span style="font-size:12px;color:#718096">Viaje en curso por otro taxista</span>';
        const badge=card.querySelector('.trip-status-badge');
        if(badge){badge.textContent='En curso';badge.className='trip-status-badge active';}
      }
    }break;
    case 'tripRemoved':        {
      const card=document.getElementById(`trip-card-${m.tripId}`);
      if(card)card.remove();
      delete activeTripsCached[m.tripId];
      const c=document.getElementById('trips-active-panel');
      if(!c.querySelector('.trip-card')) c.innerHTML='<p class="empty-msg">Sin viajes activos.</p>';
      document.getElementById('stat-trips').textContent=Object.keys(activeTripsCached).length;
      dismissTripNotify(m.tripId);
    }break;
    case 'driverTripActive':   showDriverTripActive(m.trip);break;
    case 'tripMeterUpdate':    {
      const meters=m.meters||0;const cost=m.totalCost||0;
      const mStr=meters>=1000?`${(meters/1000).toFixed(2)} km`:`${meters} m`;
      const am=document.getElementById('atrip-meters');if(am)am.textContent=mStr;
      const ac=document.getElementById('atrip-cost');if(ac)ac.textContent='$'+cost;
      const cm=document.getElementById('ct-meters');if(cm)cm.textContent=mStr;
      const cc=document.getElementById('ct-cost');if(cc)cc.textContent='$'+cost;
      const ct=document.getElementById('ct-total');if(ct)ct.textContent='$'+(cost+clientTripTip);
    }break;
    case 'tripTipUpdate':      {
      myTripTip=m.tip;
      const at=document.getElementById('atrip-tip');if(at)at.textContent='$'+m.tip;
    }break;
    case 'waypointChanged':    showNotify({type:'warning',title:'Destino cambiado',message:`Nuevo destino: ${m.toZone}`});break;
    case 'driverTripFinished': {
      myTripId=null;
      document.getElementById('active-trip-dashboard').classList.add('hidden');
      if(m.totalEarned>0) showNotify({type:'success',title:'Viaje completado',message:`Ganaste $${m.totalEarned} + ${m.xpGained} XP`});
    }break;
    case 'driverTripCancelled':{ }break;
    case 'clientTripPending':   { if(m.hotkeys) clientHotkeys=m.hotkeys; }break;
    case 'clientTripAccepted': { if(m.hotkeys) clientHotkeys=m.hotkeys; }break;
    case 'showClientTripUI':   showClientTripUI(m);break;
    case 'acceptLatestTrip':   {
      if(latestTripId){postNui('acceptTrip',{tripId:latestTripId});dismissTripNotify(latestTripId);}
      else{const w=Object.values(activeTripsCached).find(t=>t.status==='waiting');
           if(w){postNui('acceptTrip',{tripId:w.id});}
           else showNotify({type:'warning',title:'Sin viajes',message:'No hay viajes pendientes.'});}
    }break;
    case 'dismissLatestTrip':  { if(latestTripId){dismissTripNotify(latestTripId);} }break;
    case 'clientTripFinished': {
      clientTripPending=false;clientTripTip=0;
      document.getElementById('client-trip-overlay').classList.add('hidden');
      showNotify({type:'success',title:'Viaje completado',message:`Total: $${m.totalCost}${m.tip>0?' + $'+m.tip+' propina':''}`});
    }break;
    case 'clientTripCancelled':{
      clientTripPending=false;clientTripTip=0;
      document.getElementById('client-trip-overlay').classList.add('hidden');
    }break;
    case 'receiveAlertasConfig': applyAlertasConfig(m); syncAlertasUI(m); break;
    case 'showNotify':         showNotify({type:m.type,title:m.title,message:m.message,duration:m.duration});break;
    case 'escapePressed':      handleEscape();break;
    case 'openClientUI':       document.getElementById('client-trip-overlay').classList.remove('hidden');break;
    case 'closeClientUI':      document.getElementById('client-trip-overlay').classList.add('hidden');break;
    case 'taxiArrived':        {}break;
    case 'driverStage2':       {
      showNotify({type:'info',title:'Etapa 2',message:`Llevá al pasajero a: ${m.toZone}`});
      const dest=document.getElementById('atrip-dest');if(dest)dest.textContent=m.toZone||'—';
    }break;
    case 'receiveHotkeys':     {
      const hkData=m.hotkeys||m.rows||[];
      clientHotkeys=hkData;
      renderHotkeys(hkData,m.canEdit!==false);
    }break;
    case 'hotkey': { handleHotkeySlot(m.slot); }break;
    // RADIO
    case 'radioState':    renderRadioChannels(m.channels); break;
    case 'radioOnDuty':   renderRadioDuty(m.list); break;
  }
});

/* ══ RADIO ══ */
let radioState = [];        // [{slot,freq,members:[{cid,name}]}]
let radioDutyList = [];     // [{src,name,grade,isOwner}]
let myRadioSlot = null;     // slot en el que está el jugador local
const pitarCooldowns = {};  // targetSrc → timestamp

function initRadio(){
  // Cuando se abre la pestaña radio, pedir estado fresco
  document.querySelectorAll('.nav-btn').forEach(b => {
    if(b.dataset.tab === 'radio') b.addEventListener('click', () => {
      postNui('getRadioState');
      renderRadioWarn();
    });
  });
}

function renderRadioWarn(){
  const warn = document.getElementById('radio-duty-warn');
  if(!warn) return;
  const onDuty = state.data && state.data.onDuty;
  warn.classList.toggle('hidden', !!onDuty);
}

function renderRadioChannels(channels){
  if(channels) radioState = channels;
  const grid = document.getElementById('radio-channels');
  if(!grid) return;
  const myCid = state.data && state.data.myCid;
  const canEditFreq = state.data && (state.data.isOwner || (state.data.myGrade||0) >= 3);
  const onDuty = state.data && state.data.onDuty;

  // Detectar en qué slot está el usuario actual
  myRadioSlot = null;
  if(myCid){
    for(const ch of radioState){
      if(ch.members && ch.members.some(m => m.cid === myCid)){
        myRadioSlot = ch.slot;
        break;
      }
    }
  }

  grid.innerHTML = radioState.map(ch => {
    const inThis = ch.slot === myRadioSlot;
    const membersHtml = (ch.members && ch.members.length)
      ? ch.members.map(m => {
          const isMe = myCid && m.cid === myCid;
          return `<span class="radio-member-tag${isMe?' me':''}"><i class="fas fa-circle"></i>${m.name}</span>`;
        }).join('')
      : `<span class="radio-empty-ch">Sin miembros</span>`;

    const freqDisabled = canEditFreq ? '' : 'disabled';
    const joinLabel = inThis ? '<i class="fas fa-sign-out-alt"></i> Salir' : '<i class="fas fa-headphones"></i> Entrar';
    const joinClass = inThis ? 'btn-radio-join leave' : 'btn-radio-join';
    const joinDisabled = (!onDuty && !inThis) ? 'disabled' : '';

    return `<div class="radio-channel-card${inThis?' active-ch':''}" id="radio-ch-${ch.slot}">
      <div class="radio-ch-top">
        <div class="radio-ch-num${inThis?' on':''}">${ch.slot}</div>
        <div class="radio-ch-info">
          <div class="radio-ch-label">Canal ${ch.slot}</div>
          <div class="radio-ch-freq-row">
            <input class="radio-ch-freq-input" id="freq-inp-${ch.slot}" type="number"
              value="${ch.freq}" min="3000" max="9999" step="1" ${freqDisabled}
              onchange="onFreqChange(${ch.slot},this.value)"
              title="${canEditFreq ? 'Cambiá la frecuencia' : 'Solo Sub-Jefes y superiores pueden cambiar frecuencias'}"/>
            <span class="radio-ch-freq-label">MHz</span>
          </div>
        </div>
        <div class="radio-ch-actions">
          <button class="${joinClass}" ${joinDisabled}
            onclick="onRadioJoin(${ch.slot})">${joinLabel}</button>
        </div>
      </div>
      <div class="radio-ch-members">${membersHtml}</div>
    </div>`;
  }).join('');
}

window.onRadioJoin = function(slot){
  postNui('joinRadioChannel', {slot});
};

window.onFreqChange = function(slot, val){
  const freq = parseInt(val);
  if(isNaN(freq) || freq < 3000 || freq > 9999){
    showNotify({type:'error',title:'Radio',message:'Frecuencia inválida (3000–9999).'});
    return;
  }
  postNui('setRadioFreq', {slot, freq});
};

function renderRadioDuty(list){
  if(list) radioDutyList = list;
  const container = document.getElementById('radio-duty-list');
  if(!container) return;
  if(!radioDutyList.length){
    container.innerHTML = '<p class="empty-msg">Nadie en servicio.</p>';
    return;
  }
  const mySrc = state.data && state.data.mySrc;
  container.innerHTML = radioDutyList.map(p => {
    const roleLabel = p.isOwner ? 'Propietario' : (gradeLabel(p.grade));
    const isMe = mySrc && p.src === mySrc;
    return `<div class="radio-duty-row">
      <div>
        <div class="radio-duty-name">${p.name}${isMe?' <span style="font-size:10px;color:#4a5568">(vos)</span>':''}</div>
        <div class="radio-duty-role">${roleLabel}</div>
      </div>
      ${!isMe ? `<button class="btn-pitar" id="pitar-${p.src}" onclick="pitarRadio(${p.src})">
        <i class="fas fa-bell"></i> Pitar Radio
      </button>` : ''}
    </div>`;
  }).join('');
}

function gradeLabel(g){
  const labels={0:'Conductor',1:'Senior',2:'Supervisor',3:'Sub-Jefe',4:'Jefe'};
  return labels[g]||'Empleado';
}

window.pitarRadio = function(targetSrc){
  const btn = document.getElementById(`pitar-${targetSrc}`);
  const now = Date.now();
  if(pitarCooldowns[targetSrc] && (now - pitarCooldowns[targetSrc]) < 5000){
    const left = Math.ceil((5000-(now-pitarCooldowns[targetSrc]))/1000);
    showNotify({type:'warning',title:'Radio',message:`Esperá ${left}s para volver a pitar.`});
    return;
  }
  pitarCooldowns[targetSrc] = now;
  postNui('pitarRadio', {targetSrc});
  // Deshabilitar botón 5 segundos
  if(btn){
    btn.disabled = true;
    btn.innerHTML = '<i class="fas fa-clock"></i> 5s...';
    let left = 5;
    const iv = setInterval(() => {
      left--;
      if(left <= 0){
        clearInterval(iv);
        btn.disabled = false;
        btn.innerHTML = '<i class="fas fa-bell"></i> Pitar Radio';
      } else {
        btn.innerHTML = `<i class="fas fa-clock"></i> ${left}s...`;
      }
    }, 1000);
  }
};

// Estado local de la config de alertas
let alertasLocal = {
  tripNotifyPos: 'top-right',
  tripNotifyDur: 20000,
  clientUiPos:   'bottom-right',
  npcTripUiPos:  'bottom-left',
};

// Mapeo de posición → clase CSS para el dot del preview
const POS_DOT_CLASS = {
  'top-right':     'pos-top-right',
  'top-left':      'pos-top-left',
  'top-center':    'pos-top-center',
  'center-right':  'pos-center-right',
  'center-left':   'pos-center-left',
  'center':        'pos-center',
  'bottom-right':  'pos-bottom-right',
  'bottom-left':   'pos-bottom-left',
  'bottom-center': 'pos-bottom-center',
};

// Convierte una posición tipo 'top-right' en estilos CSS {top,bottom,left,right,transform}
function posToCSS(pos) {
  const map = {
    'top-right':     { top:'20px', bottom:'auto', left:'auto',  right:'20px',  transform:'none' },
    'top-left':      { top:'20px', bottom:'auto', left:'20px',  right:'auto',  transform:'none' },
    'top-center':    { top:'20px', bottom:'auto', left:'50%',   right:'auto',  transform:'translateX(-50%)' },
    'center-right':  { top:'50%',  bottom:'auto', left:'auto',  right:'20px',  transform:'translateY(-50%)' },
    'center-left':   { top:'50%',  bottom:'auto', left:'20px',  right:'auto',  transform:'translateY(-50%)' },
    'center':        { top:'50%',  bottom:'auto', left:'50%',   right:'auto',  transform:'translate(-50%,-50%)' },
    'bottom-right':  { top:'auto', bottom:'20px', left:'auto',  right:'20px',  transform:'none' },
    'bottom-left':   { top:'auto', bottom:'20px', left:'20px',  right:'auto',  transform:'none' },
    'bottom-center': { top:'auto', bottom:'20px', left:'50%',   right:'auto',  transform:'translateX(-50%)' },
  };
  return map[pos] || map['bottom-left'];
}

// Aplica la config recibida del server: reposiciona los contenedores
function applyAlertasConfig(cfg) {
  if(!cfg) return;

  if(cfg.tripNotifyPos) alertasLocal.tripNotifyPos = cfg.tripNotifyPos;
  if(cfg.tripNotifyDur !== undefined) alertasLocal.tripNotifyDur = cfg.tripNotifyDur;
  if(cfg.clientUiPos)  alertasLocal.clientUiPos  = cfg.clientUiPos;
  if(cfg.npcTripUiPos) alertasLocal.npcTripUiPos = cfg.npcTripUiPos;

  // ── Reposicionar #trip-notify-container ──
  const tnc = document.getElementById('trip-notify-container');
  if(tnc) {
    [...tnc.classList].filter(c => c.startsWith('pos-')).forEach(c => tnc.classList.remove(c));
    tnc.classList.add('pos-' + alertasLocal.tripNotifyPos);
  }

  // ── Reposicionar #client-trip-overlay ──
  const cto = document.getElementById('client-trip-overlay');
  if(cto) {
    [...cto.classList].filter(c => c.startsWith('pos-')).forEach(c => cto.classList.remove(c));
    cto.classList.add('pos-' + alertasLocal.clientUiPos);
  }

  // ── Reposicionar #npc-trip-panel (el panel interior, no el overlay) ──
  applyNpcTripPanelPos(alertasLocal.npcTripUiPos);
}

// Aplica posición dinámica al panel de misión NPC
function applyNpcTripPanelPos(pos) {
  const panel = document.getElementById('npc-trip-panel');
  if(!panel) return;
  const css = posToCSS(pos || 'bottom-left');
  panel.style.top       = css.top;
  panel.style.bottom    = css.bottom;
  panel.style.left      = css.left;
  panel.style.right     = css.right;
  panel.style.transform = css.transform;
}

// Sincroniza los controles del panel Alertas Config con el estado actual
function syncAlertasUI(cfg) {
  if(!cfg) cfg = alertasLocal;

  const tnPos  = document.getElementById('ac-tn-pos');
  const tnDur  = document.getElementById('ac-tn-dur');
  const cuPos  = document.getElementById('ac-cu-pos');
  const npcPos = document.getElementById('ac-npc-pos');

  if(tnPos)  tnPos.value  = cfg.tripNotifyPos || alertasLocal.tripNotifyPos;
  if(tnDur)  tnDur.value  = Math.round((cfg.tripNotifyDur !== undefined ? cfg.tripNotifyDur : alertasLocal.tripNotifyDur) / 1000);
  if(cuPos)  cuPos.value  = cfg.clientUiPos   || alertasLocal.clientUiPos;
  if(npcPos) npcPos.value = cfg.npcTripUiPos  || alertasLocal.npcTripUiPos;

  updatePreviewDot('ac-tn-dot',  tnPos  ? tnPos.value  : alertasLocal.tripNotifyPos);
  updatePreviewDot('ac-cu-dot',  cuPos  ? cuPos.value  : alertasLocal.clientUiPos);
  updatePreviewDot('ac-npc-dot', npcPos ? npcPos.value : alertasLocal.npcTripUiPos);
}

// Mueve el dot del preview a la posición dada
function updatePreviewDot(dotId, posValue) {
  const dot = document.getElementById(dotId);
  if(!dot) return;
  [...dot.classList].filter(c => c.startsWith('pos-')).forEach(c => dot.classList.remove(c));
  const cls = POS_DOT_CLASS[posValue];
  if(cls) dot.classList.add(cls);
}

// Inicializar el panel Alertas Config cuando el DOM esté listo
function initAlertasConfig() {
  const tnPos  = document.getElementById('ac-tn-pos');
  const cuPos  = document.getElementById('ac-cu-pos');
  const npcPos = document.getElementById('ac-npc-pos');

  if(tnPos)  tnPos.addEventListener('change',  () => updatePreviewDot('ac-tn-dot',  tnPos.value));
  if(cuPos)  cuPos.addEventListener('change',  () => updatePreviewDot('ac-cu-dot',  cuPos.value));
  if(npcPos) npcPos.addEventListener('change', () => updatePreviewDot('ac-npc-dot', npcPos.value));

  // Botón guardar
  const btnSave = document.getElementById('btn-save-alertas');
  if(btnSave) {
    btnSave.addEventListener('click', () => {
      const posVal   = tnPos  ? tnPos.value  : alertasLocal.tripNotifyPos;
      const durSecs  = parseInt(document.getElementById('ac-tn-dur')?.value) || 20;
      const cuVal    = cuPos  ? cuPos.value  : alertasLocal.clientUiPos;
      const npcVal   = npcPos ? npcPos.value : alertasLocal.npcTripUiPos;

      if(durSecs < 5 || durSecs > 120) {
        showNotify({type:'error', title:'Alertas Config', message:'La duración debe estar entre 5 y 120 segundos.'});
        return;
      }

      postNui('updateAlertasConfig', {
        tripNotifyPos: posVal,
        tripNotifyDur: durSecs * 1000,
        clientUiPos:   cuVal,
        npcTripUiPos:  npcVal,
      });

      applyAlertasConfig({ tripNotifyPos: posVal, tripNotifyDur: durSecs * 1000, clientUiPos: cuVal, npcTripUiPos: npcVal });
      showNotify({type:'success', title:'Alertas Config', message:'Configuración guardada y aplicada.'});
    });
  }

  // Inicializar posición del panel NPC al cargar
  applyNpcTripPanelPos(alertasLocal.npcTripUiPos);
}

// Inicializar al cargar
document.addEventListener('DOMContentLoaded', () => {
  initCompanyName();
  initNotes();
  initRadio();
  initAlertasConfig();
});

/* ══════════════════════════════════════════════════════════════
   NPC DAILY MISSIONS — sh-taxijob
══════════════════════════════════════════════════════════════ */

// ── Estado local de misiones ──────────────────
let dailyMissions       = [];
let dailyMsToReset      = 0;
let dailyTimerInterval  = null;
let npcTripActive       = false;
let npcPendingData      = null;
let npcHasTimer         = false;
let npcTimerSecs        = 0;
let npcTimerInterval    = null;
let activeDailyMissionId = null;  // id de la misión actualmente aceptada

// ── Formato de tiempo mm:ss ───────────────────
function fmtMS(secs){
  const m = Math.floor(secs / 60);
  const s = secs % 60;
  return `${m}:${String(s).padStart(2,'0')}`;
}
function fmtHMS(ms){
  const totalSec = Math.floor(ms / 1000);
  const h = Math.floor(totalSec / 3600);
  const m = Math.floor((totalSec % 3600) / 60);
  const s = totalSec % 60;
  if(h > 0) return `${h}h ${m}m ${String(s).padStart(2,'0')}s`;
  return `${m}m ${String(s).padStart(2,'0')}s`;
}

// ── Actualizar contador "Diarias" en el dashboard ─
function updateDailyTimerDisplay(){
  const el = document.getElementById('stat-daily-timer');
  if(!el) return;
  if(dailyMsToReset <= 0){ el.textContent = 'Listo para reiniciar'; return; }
  el.textContent = fmtHMS(dailyMsToReset);
}

function startDailyTimerTick(){
  if(dailyTimerInterval) clearInterval(dailyTimerInterval);
  dailyTimerInterval = setInterval(() => {
    if(dailyMsToReset > 1000){ dailyMsToReset -= 1000; }
    else { dailyMsToReset = 0; }
    updateDailyTimerDisplay();
    // Sync el counter del panel de misiones
    const rt = document.getElementById('dm-reset-timer');
    if(rt) rt.textContent = dailyMsToReset > 0 ? fmtHMS(dailyMsToReset) : 'Disponible';
  }, 1000);
}

// ── Abrir panel de misiones diarias ───────────
function openDailyMissions(data){
  dailyMissions    = data.missions || [];
  dailyMsToReset   = data.msToReset || 0;

  const overlay = document.getElementById('daily-missions-overlay');
  if(!overlay) return;

  const rt = document.getElementById('dm-reset-timer');
  if(rt) rt.textContent = dailyMsToReset > 0 ? fmtHMS(dailyMsToReset) : 'Disponible';

  renderDailyMissionsList(dailyMissions, data.playerLevel || 0);
  overlay.classList.remove('hidden');
}

function closeDailyMissionsPanel(fromLua = false){
  const overlay = document.getElementById('daily-missions-overlay');
  if(overlay) overlay.classList.add('hidden');
  // Solo llamar postNui si el cierre fue iniciado DESDE el NUI (click del usuario).
  // Si viene del Lua (ESC), el foco ya fue liberado allá — no llamar de vuelta
  // para evitar el bucle que deja el NUI bloqueado.
  if(!fromLua) postNui('closeDailyMissions');
}

// ── Renderizar lista de misiones ──────────────
function renderDailyMissionsList(missions, playerLevel){
  const list = document.getElementById('dm-missions-list');
  if(!list) return;

  if(!missions || !missions.length){
    list.innerHTML = '<p class="empty-msg">No hay misiones disponibles para tu nivel actual.</p>';
    return;
  }

  list.innerHTML = missions.map(m => {
    const gradeColor = m.gradeColor || '#9b59b6';
    const distStr    = m.distMeters >= 1000
      ? `${(m.distMeters/1000).toFixed(1)} km`
      : `${m.distMeters || 0} m`;

    const flags = [];
    if(m.hasProbRunaway) flags.push(`<span class="dm-flag runaway"><i class="fas fa-running"></i> Puede huir</span>`);
    if(m.hasTimer)       flags.push(`<span class="dm-flag timer"><i class="fas fa-stopwatch"></i> Cronómetro ${fmtMS(m.timerSecs||0)}</span>`);
    if(m.hasTimer && m.timerSecs && (m.bonusPct||0) > 0) flags.push(`<span class="dm-flag bonus"><i class="fas fa-plus"></i> +${m.bonusPct||0}% bonus tiempo</span>`);
    if(m.gradeKey === 'Especial') flags.push(`<span class="dm-flag especial"><i class="fas fa-car-crash"></i> Persecución vehicular</span>`);

    const isActive   = (activeDailyMissionId === m.id);
    const anyActive  = (activeDailyMissionId !== null);

    const actionHtml = isActive
      ? `<div class="dm-mission-accepted-row">
           <span class="dm-badge-accepted"><i class="fas fa-check-circle"></i> Aceptada</span>
           <button class="btn-cancel-mission" onclick="cancelNpcMission(${m.id})" title="Cancelar misión">
             <i class="fas fa-times"></i>
           </button>
         </div>`
      : `<button class="btn-accept-mission mt6"
           onclick="acceptNpcMission(${m.id})"
           ${anyActive ? 'disabled title="Cancelá la misión activa primero"' : ''}>
           Aceptar
         </button>`;

    return `<div class="dm-mission-card${isActive ? ' dm-mission-card--active' : ''}">
      <div class="dm-mission-left">
        <div class="dm-mission-grade" style="background:${gradeColor}22;color:${gradeColor};border-color:${gradeColor}44">
          ${m.gradeLabel || m.gradeKey}
        </div>
        <div class="dm-mission-info">
          <span><i class="fas fa-map-marker-alt"></i> ${m.pickupZone || 'Zona recogida'}</span>
          <span><i class="fas fa-flag-checkered"></i> ${m.dropZone || 'Zona entrega'}</span>
          <span><i class="fas fa-road"></i> ~${distStr}</span>
        </div>
        <div class="dm-mission-flags">${flags.join('')}</div>
      </div>
      <div>
        <div class="dm-mission-pay">$${(m.basePay||0).toLocaleString()}</div>
        <div class="dm-mission-xp"><i class="fas fa-star"></i> +${(m.xpReward||0).toLocaleString()} XP</div>
        ${actionHtml}
      </div>
    </div>`;
  }).join('');
}

window.acceptNpcMission = function(id){
  if(activeDailyMissionId !== null){
    showNotify({type:'error',title:'Misión activa',message:'Cancelá tu misión actual primero.'});
    return;
  }
  activeDailyMissionId = id;
  postNui('acceptNpcMission', { missionId: id });
  // Refrescar la lista para mostrar el estado "Aceptada" + botón cancelar
  renderDailyMissionsList(dailyMissions, 0);
};

window.cancelNpcMission = function(id){
  // 1. Limpiar estado local inmediatamente
  activeDailyMissionId = null;
  npcTripActive = false;
  // 2. Avisar al Lua para que limpie el NPC, blips, threads y notifique al server
  postNui('cancelNpcMission', { missionId: id });
  // 3. Refrescar las cards — todos los botones vuelven a "Aceptar"
  renderDailyMissionsList(dailyMissions, 0);
};

// Cuando la misión termina naturalmente (éxito/fallo), limpiar el estado activo
function onNpcMissionEnded(){
  activeDailyMissionId = null;
  // Si el panel está abierto, refrescar las cards
  const overlay = document.getElementById('daily-missions-overlay');
  if(overlay && !overlay.classList.contains('hidden')){
    renderDailyMissionsList(dailyMissions, 0);
  }
}

// ── Boton cerrar misiones diarias ─────────────
document.getElementById('btn-close-daily-missions')
  ?.addEventListener('click', () => closeDailyMissionsPanel(false));

// ── Panel del viaje NPC (con barras) ──────────
function showNpcMissionPending(data){
  // Solo prepara los datos internamente.
  // El overlay npc-trip-overlay NO se muestra aquí — aparece cuando el NPC sube al auto (showNpcTripUI).
  // En esta etapa solo existe el blip en el mapa y la notificación de texto.
  npcPendingData = data;  // guardar para cuando llegue showNpcTripUI

  const gradeLbl = document.getElementById('ntrip-grade-label');
  if(gradeLbl){
    gradeLbl.textContent = data.gradeLabel || 'Básico';
    gradeLbl.style.background  = (data.gradeColor||'#9b59b6') + '22';
    gradeLbl.style.color       = data.gradeColor || '#9b59b6';
    gradeLbl.style.borderColor = (data.gradeColor||'#9b59b6') + '44';
  }

  const bp = document.getElementById('ntrip-base-pay');
  if(bp) bp.textContent = '$' + (data.basePay || 0).toLocaleString();

  npcTripActive = true;
  // overlay permanece oculto hasta showNpcTripUI
}

function showNpcTripUI(data){
  // Ahora SÍ mostramos el overlay — el NPC ya está en el auto
  const overlay = document.getElementById('npc-trip-overlay');
  if(!overlay) return;

  npcHasTimer  = data.hasTimer  || false;
  npcTimerSecs = data.timerSecs || 0;

  // Resetear etapas
  document.getElementById('ntrip-stage-pickup')?.classList.add('hidden');
  const dropStage = document.getElementById('ntrip-stage-dropoff');
  if(dropStage){
    dropStage.classList.remove('hidden');
    const dz = document.getElementById('ntrip-drop-zone');
    if(dz) dz.textContent = data.dropZone || 'Entregar pasajero';
  }
  document.getElementById('ntrip-metrics')?.removeAttribute('style');
  document.getElementById('ntrip-timer-row')?.classList.add('hidden');

  if(npcHasTimer && npcTimerSecs > 0){
    const tr = document.getElementById('ntrip-timer-row');
    if(tr) tr.classList.remove('hidden');
    const tv = document.getElementById('ntrip-timer-val');
    if(tv) tv.textContent = fmtMS(npcTimerSecs);
    startNpcTimerCountdown();
  }

  updateNpcBars(0, 0, false);
  document.getElementById('ntrip-penalties').innerHTML = '';

  overlay.classList.remove('hidden');
}

function startNpcTimerCountdown(){
  if(npcTimerInterval) clearInterval(npcTimerInterval);
  npcTimerInterval = setInterval(() => {
    if(!npcTripActive){ clearInterval(npcTimerInterval); return; }
    npcTimerSecs = Math.max(0, npcTimerSecs - 1);
    const tv = document.getElementById('ntrip-timer-val');
    if(tv) tv.textContent = fmtMS(npcTimerSecs);
    const tr = document.getElementById('ntrip-timer-row');
    if(tr) tr.classList.toggle('urgent', npcTimerSecs > 0 && npcTimerSecs <= 30);
    if(npcTimerSecs <= 0) clearInterval(npcTimerInterval);
  }, 1000);
}

function updateNpcBars(stress, scared, stressLocked, meters, cost){
  const stressBar = document.getElementById('stress-bar');
  const scaredBar = document.getElementById('scared-bar');
  const stressPct = document.getElementById('stress-pct');
  const scaredPct = document.getElementById('scared-pct');

  const stressW = Math.min(100, stress || 0);
  const scaredW = Math.min(100, scared || 0);

  if(stressBar){ stressBar.style.width = stressW + '%'; }
  if(stressPct){ stressPct.textContent  = Math.round(stressW) + '%'; }
  if(scaredBar){ scaredBar.style.width  = scaredW + '%'; }
  if(scaredPct){ scaredPct.textContent  = Math.round(scaredW) + '%'; }

  // Color rojo cuando llega al máximo
  if(stressBar) stressBar.style.background = stressLocked
    ? 'linear-gradient(90deg,#dc2626,#ef4444)'
    : 'linear-gradient(90deg,#f59e0b,#ef4444)';

  if(meters !== undefined){
    const mStr = meters >= 1000 ? `${(meters/1000).toFixed(2)} km` : `${meters} m`;
    const nm = document.getElementById('ntrip-meters');
    if(nm) nm.textContent = mStr;
  }
  if(cost !== undefined){
    const nc = document.getElementById('ntrip-cost');
    if(nc) nc.textContent = '$' + (cost || 0).toLocaleString();
  }

  // Mostrar tags de penalización
  const penalties = document.getElementById('ntrip-penalties');
  if(penalties){
    let html = '';
    if(stressLocked)   html += '<span class="ntrip-penalty-tag"><i class="fas fa-tachometer-alt"></i> Stress máx → −25%</span> ';
    if(scaredW >= 100) html += '<span class="ntrip-penalty-tag"><i class="fas fa-exclamation-triangle"></i> Asustado → −25%</span>';
    penalties.innerHTML = html;
  }
}

function hideNpcMissionUI(){
  npcTripActive    = false;
  npcPendingData   = null;
  if(npcTimerInterval) clearInterval(npcTimerInterval);
  npcTimerInterval = null;
  npcTimerSecs     = 0;
  const overlay = document.getElementById('npc-trip-overlay');
  if(overlay) overlay.classList.add('hidden');
  updateNpcBars(0, 0, false, 0, 0);
  document.getElementById('ntrip-penalties').innerHTML = '';
  // Limpiar estado de misión activa y refrescar cards si el panel está abierto
  onNpcMissionEnded();
}

// ── Agrandar renderLocations para viajes_diarios ─
(function patchRenderLocations(){
  const _orig = window.renderLocations || function(){};
  window.renderLocations = function(d){
    _orig(d);
    const l = d.locations || {};
    const fmt = v => v ? `X:${v.x.toFixed(1)} Y:${v.y.toFixed(1)} Z:${v.z.toFixed(1)} H:${(v.heading||0).toFixed(1)}` : '—';
    const el = document.getElementById('loc-viajes_diarios-coords');
    if(el) el.textContent = fmt(l.viajes_diarios);
  };
})();

// ── Botones de la ubicación viajes_diarios ────
document.getElementById('btn-viajes_diarios-here')
  ?.addEventListener('click', () => {
    postNui('setLocationHere', { locType: 'viajes_diarios' });
    showNotify({type:'success', title:'Movido', message:'Ubicación Viajes Diarios actualizada.'});
  });
document.getElementById('btn-viajes_diarios-manual')
  ?.addEventListener('click', () => {
    state.currentLocType = 'viajes_diarios';
    openModal('Coords — viajes_diarios');
  });

// ── Manejar mensajes NUI nuevos ───────────────
(function patchMessageHandler(){
  const _origListener = null; // ya existe el window.addEventListener principal
  // Agregamos uno propio para los casos nuevos
  window.addEventListener('message', e => {
    const m = e.data; if(!m || !m.action) return;
    switch(m.action){
      case 'openDailyMissions':
        openDailyMissions(m);
        break;
      case 'closeDailyMissions':
        // Iniciado desde Lua (ESC o cancelación) — no rellamar postNui
        closeDailyMissionsPanel(true);
        break;
      case 'forceCloseDailyMissions':
        // Explícitamente desde Lua — sin postNui, resetear estado de misión activa
        activeDailyMissionId = null;
        npcTripActive = false;
        closeDailyMissionsPanel(true);
        break;
      case 'showNpcMissionPending':
        showNpcMissionPending(m);
        break;
      case 'showNpcTripUI':
        showNpcTripUI(m);
        break;
      case 'npcMissionBarsUpdate':
        if(npcTripActive){
          updateNpcBars(m.stress, m.scared, m.stressLocked, m.meters, m.cost);
          // Actualizar timer si viene en el mensaje
          if(m.timerLeft !== undefined && npcHasTimer){
            npcTimerSecs = m.timerLeft;
          }
        }
        break;
      case 'hideNpcMissionUI':
        hideNpcMissionUI();
        break;
      case 'updateDailyTimer':
        dailyMsToReset = m.msToReset || 0;
        updateDailyTimerDisplay();
        startDailyTimerTick();
        // Sync al panel si está abierto
        const rt = document.getElementById('dm-reset-timer');
        if(rt) rt.textContent = dailyMsToReset > 0 ? fmtHMS(dailyMsToReset) : 'Disponible';
        break;
    }
  });
})();

// Inicializar ticker del daily timer al cargar
document.addEventListener('DOMContentLoaded', () => {
  updateDailyTimerDisplay();
  startDailyTimerTick();
});

// ══════════════════════════════════════════════
//  CHASE TIMER — Misiones Avanzadas
//  Aparece cuando el NPC huye sin pagar y el
//  jugador tiene un tiempo límite para atraparlo.
// ══════════════════════════════════════════════
let chaseTimerSecs    = 0;
let chaseTimerActive  = false;
let chaseTimerInterv  = null;

function showChaseTimer(data){
  chaseTimerSecs   = data.timerSecs || 30;
  chaseTimerActive = true;
  const gradeColor = data.gradeColor || '#e74c3c';

  let overlay = document.getElementById('chase-timer-overlay');
  if(!overlay){
    overlay = document.createElement('div');
    overlay.id = 'chase-timer-overlay';
    document.body.appendChild(overlay);
  }
  overlay.innerHTML = `
    <div class="chase-timer-box" style="--chase-color:${gradeColor}">
      <div class="chase-timer-label"><i class="fas fa-running"></i> ¡CIVIL SIN PAGAR!</div>
      <div class="chase-timer-sub">Recupera el pago antes de que huya</div>
      <div class="chase-timer-val" id="chase-timer-val">${chaseTimerSecs}s</div>
      <div class="chase-timer-bar-wrap">
        <div class="chase-timer-bar" id="chase-timer-bar" style="width:100%;background:${gradeColor}"></div>
      </div>
      <div class="chase-timer-hint"><i class="fas fa-fist-raised"></i> Acercate y Tackealo para recuperar el pago</div>
    </div>`;
  overlay.classList.remove('hidden');

  const totalSecs = chaseTimerSecs;
  if(chaseTimerInterv) clearInterval(chaseTimerInterv);
  chaseTimerInterv = setInterval(() => {
    if(!chaseTimerActive){ clearInterval(chaseTimerInterv); return; }
    chaseTimerSecs = Math.max(0, chaseTimerSecs - 1);
    const tv = document.getElementById('chase-timer-val');
    if(tv) tv.textContent = chaseTimerSecs + 's';
    const bar = document.getElementById('chase-timer-bar');
    if(bar) bar.style.width = ((chaseTimerSecs / totalSecs) * 100) + '%';
    const box = overlay.querySelector('.chase-timer-box');
    if(box) box.classList.toggle('chase-urgent', chaseTimerSecs > 0 && chaseTimerSecs <= 10);
    if(chaseTimerSecs <= 0){ clearInterval(chaseTimerInterv); }
  }, 1000);
}

function updateChaseTimer(timerLeft){
  chaseTimerSecs = timerLeft;
  const tv = document.getElementById('chase-timer-val');
  if(tv) tv.textContent = timerLeft + 's';
}

function hideChaseTimer(){
  chaseTimerActive = false;
  if(chaseTimerInterv) clearInterval(chaseTimerInterv);
  chaseTimerInterv = null;
  const overlay = document.getElementById('chase-timer-overlay');
  if(overlay) overlay.classList.add('hidden');
}

// Extender el handler de mensajes para los nuevos actions de chase
window.addEventListener('message', e => {
  const m = e.data; if(!m || !m.action) return;
  if(m.action === 'showChaseTimer')   showChaseTimer(m);
  if(m.action === 'updateChaseTimer') updateChaseTimer(m.timerLeft);
  if(m.action === 'hideChaseTimer')   hideChaseTimer();
});
