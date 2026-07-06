#!/usr/bin/env bash
# =====================================================================
#  ONE-COMMAND INSTALLER v2.1 — Custom Node Upload for self-hosted n8n
#  NATIVE INTEGRATION: uploaded nodes become real community packages —
#  they appear in Settings -> Community Nodes with n8n's OWN uninstall/
#  update options, and load INSTANTLY (no restart needed).
#
#  Works on Hostinger n8n VPS and any Docker-Compose n8n.
#  Host on GitHub, then users run:
#    curl -fsSL https://raw.githubusercontent.com/YOU/REPO/main/install-custom-node-upload.sh | bash
#  Uninstall the feature:  ... | bash -s -- --uninstall
#
#  Uses ONLY native n8n extension points (EXTERNAL_HOOK_FILES +
#  EXTERNAL_FRONTEND_HOOKS_URLS). The n8n image is never modified.
# =====================================================================
set -euo pipefail
B='\033[1;34m'; G='\033[1;32m'; R='\033[1;31m'; Y='\033[1;33m'; O='\033[0m'
info(){ echo -e "${B}[INFO]${O}  $*"; }
ok(){   echo -e "${G}[OK]${O}    $*"; }
warn(){ echo -e "${Y}[WARN]${O}  $*"; }
err(){  echo -e "${R}[ERROR]${O} $*" >&2; exit 1; }

UNINSTALL=false
[ "${1:-}" = "--uninstall" ] && UNINSTALL=true

command -v docker >/dev/null || err "Docker not found. This installer targets Docker-based n8n."

# --- FIX #4: prefer a container whose NAME matches n8n, so we don't pick a
#     sidecar (e.g. a postgres/redis image that happens to carry 'n8n' in its
#     image tag). Fall back to a name-or-image match only if no name matches.
CONTAINER="$(docker ps --format '{{.Names}}' | awk 'tolower($0) ~ /n8n/{print; exit}')"
[ -n "$CONTAINER" ] || CONTAINER="$(docker ps --format '{{.Names}} {{.Image}}' | awk 'tolower($0) ~ /n8n/{print $1; exit}')"
[ -n "$CONTAINER" ] || err "No running n8n container found. Start n8n first."
info "n8n container: $CONTAINER"

COMPOSE_DIR="$(docker inspect "$CONTAINER" --format '{{ index .Config.Labels "com.docker.compose.project.working_dir" }}' 2>/dev/null || true)"
SERVICE="$(docker inspect "$CONTAINER" --format '{{ index .Config.Labels "com.docker.compose.service" }}' 2>/dev/null || true)"
[ "$COMPOSE_DIR" = "<no value>" ] && COMPOSE_DIR=""
[ "$SERVICE" = "<no value>" ] && SERVICE=""
[ -n "$SERVICE" ] || SERVICE="n8n"
info "Compose dir: ${COMPOSE_DIR:-not detected} | service: $SERVICE"

# --- FIX #2: single helper so install AND uninstall bring compose up the
#     same way, supporting both the `docker compose` plugin and the legacy
#     `docker-compose` binary.
compose_up(){ ( cd "$1" && ( docker compose up -d 2>/dev/null || docker-compose up -d ) ); }

if $UNINSTALL; then
  info "Removing custom node upload feature..."
  docker exec "$CONTAINER" rm -rf /home/node/.n8n/hooks 2>/dev/null || true
  if [ -n "$COMPOSE_DIR" ] && [ -f "$COMPOSE_DIR/docker-compose.override.yml" ]; then
    rm -f "$COMPOSE_DIR/docker-compose.override.yml"
    info "Removed docker-compose.override.yml; restarting n8n..."
    compose_up "$COMPOSE_DIR"
  else
    # --- FIX #5: non-compose container. We cannot un-set env vars we never
    #     owned; tell the operator exactly what to strip on next recreate.
    warn "Container is not compose-managed (or no override was written)."
    warn "Restarting the container; if you recreate it, drop these env vars:"
    echo "  EXTERNAL_HOOK_FILES, EXTERNAL_FRONTEND_HOOKS_URLS, CUSTOM_NODE_ADMIN_TOKEN"
    docker restart "$CONTAINER" >/dev/null
  fi
  ok "Custom node upload feature removed. (Already-installed nodes remain manageable natively.)"
  exit 0
fi

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# ---------------------------------------------------------------
# Backend hook — runs INSIDE the n8n process, so it can use n8n's
# own CommunityPackagesService for fully native install/uninstall.
# ---------------------------------------------------------------
cat > "$TMP/custom-node-hooks.js" <<'HOOK_EOF'
'use strict';
const fs=require('fs'),path=require('path'),os=require('os');
const {execFile}=require('child_process');
const FALLBACK_DIR=path.join(os.homedir(),'.n8n','nodes');
const TOKEN=process.env.CUSTOM_NODE_ADMIN_TOKEN||'';
const MAX=50*1024*1024;
function sh(c,a,o){return new Promise((res,rej)=>{execFile(c,a,{maxBuffer:10485760,...o},(e,so,se)=>{e?rej(new Error((se||so||e.message).toString().slice(-2000))):res((so||'').toString());});});}
function auth(req,res){if(!TOKEN){res.status(500).json({error:'CUSTOM_NODE_ADMIN_TOKEN not set on server.'});return false;}
if(req.headers['x-custom-node-token']!==TOKEN){res.status(403).json({error:'Invalid admin token.'});return false;}return true;}

/* ---------- locate n8n internals (native integration) ---------- */
function findN8nRoot(){
let d=require.main&&require.main.filename?path.dirname(require.main.filename):'';
while(d&&d!=='/'){const pj=path.join(d,'package.json');
if(fs.existsSync(pj)){try{if(JSON.parse(fs.readFileSync(pj,'utf-8')).name==='n8n')return d;}catch(e){}}
d=path.dirname(d);}
const guess='/usr/local/lib/node_modules/n8n';
return fs.existsSync(guess)?guess:null;}
function findFile(root,names,depth){
const stack=[[path.join(root,'dist'),0]];
while(stack.length){const[dir,lv]=stack.pop();let ents;
try{ents=fs.readdirSync(dir,{withFileTypes:true});}catch(e){continue;}
for(const en of ents){const p=path.join(dir,en.name);
if(en.isFile()&&names.indexOf(en.name)!==-1)return p;
if(en.isDirectory()&&lv<depth&&en.name!=='node_modules')stack.push([p,lv+1]);}}
return null;}
let NATIVE=null;
function native(){
if(NATIVE!==null)return NATIVE;
try{
const root=findN8nRoot();if(!root)throw new Error('n8n root not found');
const req=require('module').createRequire(path.join(root,'package.json'));
const {Container}=req('@n8n/di');
const {InstanceSettings}=req('n8n-core');
const lncPath=findFile(root,['load-nodes-and-credentials.js'],6);
const repoPath=findFile(root,['installed-packages.repository.js'],8);
if(!lncPath||!repoPath)throw new Error('internal files not found');
const LNC=require(lncPath).LoadNodesAndCredentials;
const REPO=require(repoPath).InstalledPackagesRepository;
NATIVE={Container,InstanceSettings,LNC,REPO};
console.log('[custom-node-hooks] native community-package integration: ENABLED');
}catch(e){NATIVE=false;
console.log('[custom-node-hooks] native integration unavailable ('+e.message+') — using fallback (~/.n8n/nodes + restart)');}
return NATIVE;}

function ensureDepFile(dir){fs.mkdirSync(dir,{recursive:true});
const p=path.join(dir,'package.json');
if(!fs.existsSync(p))fs.writeFileSync(p,JSON.stringify({name:'installed-nodes',private:true,version:'1.0.0'},null,2));return p;}
function setDep(depFile,name,ver){const j=JSON.parse(fs.readFileSync(depFile,'utf-8'));
j.dependencies=j.dependencies||{};if(ver===null)delete j.dependencies[name];else j.dependencies[name]=ver;
fs.writeFileSync(depFile,JSON.stringify(j,null,2));}

async function validate(tmp,filename){
if(!/\.(tgz|tar\.gz)$/.test(filename||''))throw new Error('Only .tgz from `npm pack` supported.');
const pkg=JSON.parse(await sh('tar',['-xzOf',tmp,'package/package.json']));
if(!pkg.n8n||!pkg.n8n.nodes||!pkg.n8n.nodes.length)throw new Error('Not an n8n node package (no "n8n.nodes" in package.json).');
if(!/^(@[a-z0-9-~][a-z0-9-._~]*\/)?[a-z0-9-~][a-z0-9-._~]*$/.test(pkg.name||''))throw new Error('Invalid package name in package.json.');
const listing=(await sh('tar',['-tzf',tmp])).split('\n').map(s=>s.trim());
const declared=[].concat(pkg.n8n.nodes||[],pkg.n8n.credentials||[]);
const missing=declared.filter(f=>listing.indexOf('package/'+f)===-1);
if(missing.length)throw new Error('Package structure invalid — declared files missing from archive (run `npm run build` before `npm pack`?): '+missing.join(', '));
return pkg;}

async function extractAndDeps(tmp,pkgDir,pkg){
fs.rmSync(pkgDir,{recursive:true,force:true});fs.mkdirSync(pkgDir,{recursive:true});
await sh('tar',['-xzf',tmp,'-C',pkgDir,'--strip-components=1']);
const clean=Object.assign({},pkg);delete clean.devDependencies;delete clean.peerDependencies;delete clean.optionalDependencies;
fs.writeFileSync(path.join(pkgDir,'package.json'),JSON.stringify(clean,null,2));
await sh('npm',['install','--omit=dev','--no-audit','--no-fund','--ignore-scripts','--install-strategy=shallow','--package-lock=false'],{cwd:pkgDir});}

module.exports={n8n:{ready:[async function(server){
const app=server.app,log=m=>console.log('[custom-node-hooks] '+m);

app.get('/rest/custom-nodes/ui.js',(q,res)=>{try{res.type('application/javascript').send(fs.readFileSync(path.join(__dirname,'custom-node-ui.js'),'utf-8'));}catch(e){res.status(404).send('// ui.js missing');}});

/* --- FIX #1: /status endpoint the installer's verify command points at.
   Returns integration mode + whether the admin token is configured, with
   NO auth required (it leaks nothing sensitive) so a plain curl confirms
   the hook is live. */
app.get('/rest/custom-nodes/status',(q,res)=>{try{
res.json({ok:true,feature:'custom-node-upload',native:!!native(),tokenConfigured:!!TOKEN});
}catch(e){res.status(500).json({ok:false,error:e.message});}});

app.get('/rest/custom-nodes/list',async(q,res)=>{try{
const nat=native();
if(nat){const settings=nat.Container.get(nat.InstanceSettings);
const depFile=ensureDepFile(settings.nodesDownloadDir);
const j=JSON.parse(fs.readFileSync(depFile,'utf-8'));
return res.json({native:true,packages:j.dependencies||{}});}
const depFile=ensureDepFile(FALLBACK_DIR);
const j=JSON.parse(fs.readFileSync(depFile,'utf-8'));
res.json({native:false,packages:j.dependencies||{}});
}catch(e){res.status(500).json({error:e.message});}});

app.post('/rest/custom-nodes/install',async(req,res)=>{if(!auth(req,res))return;
const {filename,data}=req.body||{};
if(!data)return res.status(400).json({error:'Missing base64 "data".'});
const buf=Buffer.from(data,'base64');
if(buf.length>MAX)return res.status(400).json({error:'File too large.'});
const tmp=path.join(os.tmpdir(),'cn-'+Date.now()+'.tgz');
fs.writeFileSync(tmp,buf);
try{
const pkg=await validate(tmp,filename);
const nat=native();
if(nat){
/* ---- NATIVE: behaves exactly like a community node ---- */
const settings=nat.Container.get(nat.InstanceSettings);
const dlDir=settings.nodesDownloadDir;
const pkgDir=path.join(dlDir,'node_modules',pkg.name);
await extractAndDeps(tmp,pkgDir,pkg);
setDep(ensureDepFile(dlDir),pkg.name,pkg.version);
const lnc=nat.Container.get(nat.LNC);
try{await lnc.unloadPackage(pkg.name);}catch(e){}
const loader=await lnc.loadPackage(pkg.name);
if(!loader.loadedNodes||!loader.loadedNodes.length){fs.rmSync(pkgDir,{recursive:true,force:true});setDep(ensureDepFile(dlDir),pkg.name,null);throw new Error('Package loaded but contains no usable nodes.');}
const repo=nat.Container.get(nat.REPO);
const old=await repo.findOne({where:{packageName:pkg.name},relations:['installedNodes']}).catch(()=>null);
if(old)await repo.remove(old);
await repo.saveInstalledPackageWithNodes(loader);
await lnc.postProcessLoaders();
if(lnc.releaseTypes)lnc.releaseTypes();
log('natively installed '+pkg.name+'@'+pkg.version);
return res.json({ok:true,native:true,package:pkg.name,version:pkg.version,nodes:loader.loadedNodes.length,
note:'Installed as a community package — live now, NO restart needed. See Settings -> Community Nodes (native uninstall works there).'});
}
/* ---- FALLBACK: ~/.n8n/nodes + restart ---- */
ensureDepFile(FALLBACK_DIR);
await sh('npm',['install',tmp,'--omit=dev','--no-audit','--no-fund','--ignore-scripts'],{cwd:FALLBACK_DIR});
log('installed (fallback) '+pkg.name+'@'+pkg.version);
res.json({ok:true,native:false,package:pkg.name,version:pkg.version,nodes:pkg.n8n.nodes.length,
note:'Installed. Restart n8n to load the node.'});
}catch(e){res.status(500).json({error:e.message});}
finally{fs.rmSync(tmp,{force:true});}});

app.post('/rest/custom-nodes/remove',async(req,res)=>{if(!auth(req,res))return;
try{const name=(req.body&&req.body.name)||'';
if(!/^(@[a-z0-9-~][a-z0-9-._~]*\/)?[a-z0-9-~][a-z0-9-._~]*$/.test(name))return res.status(400).json({error:'Invalid package name.'});
const nat=native();
if(nat){const settings=nat.Container.get(nat.InstanceSettings);
const dlDir=settings.nodesDownloadDir;
fs.rmSync(path.join(dlDir,'node_modules',name),{recursive:true,force:true});
setDep(ensureDepFile(dlDir),name,null);
const lnc=nat.Container.get(nat.LNC);
try{await lnc.unloadPackage(name);}catch(e){}
const repo=nat.Container.get(nat.REPO);
const row=await repo.findOne({where:{packageName:name},relations:['installedNodes']}).catch(()=>null);
if(row)await repo.remove(row);
try{await lnc.postProcessLoaders();}catch(e){}
return res.json({ok:true,native:true,removed:name,note:'Removed live — no restart needed.'});}
await sh('npm',['uninstall',name,'--silent'],{cwd:FALLBACK_DIR});
res.json({ok:true,native:false,removed:name,note:'Removed. Restart n8n to unload.'});
}catch(e){res.status(500).json({error:e.message});}});

app.post('/rest/custom-nodes/restart',(req,res)=>{if(!auth(req,res))return;
res.json({ok:true,note:'Restarting…'});log('restart requested');setTimeout(()=>process.exit(0),800);});

native(); /* detect + log integration mode at startup */
log('routes registered: /rest/custom-nodes/*');
}]}};
HOOK_EOF

# ---------------------------------------------------------------
# Frontend UI — adds ONLY the upload control to the install popup.
# Management (uninstall/update) is n8n's own native UI.
# ---------------------------------------------------------------
cat > "$TMP/custom-node-ui.js" <<'UI_EOF'
(function(){'use strict';
var MARK='data-custom-node-ui';
function getToken(){var t=sessionStorage.getItem('customNodeToken');
if(!t){t=window.prompt('Admin token for custom node upload:');if(t)sessionStorage.setItem('customNodeToken',t);}return t||'';}
function api(p,o){o=o||{};o.headers=Object.assign({'content-type':'application/json','x-custom-node-token':getToken()},o.headers||{});
return fetch(p,o).then(function(r){return r.json().then(function(j){
if(!r.ok){if(r.status===403)sessionStorage.removeItem('customNodeToken');throw new Error(j.error||('HTTP '+r.status));}return j;});});}
function el(t,c,x){var e=document.createElement(t);if(c)e.style.cssText=c;if(x)e.textContent=x;return e;}
function build(){
var w=el('div','border-top:1px solid #dbdfe7;margin-top:14px;padding-top:14px;');w.setAttribute(MARK,'1');
var ti=el('div','font-size:13px;font-weight:600;margin-bottom:4px;color:#31353e;','Upload your own node (.tgz)');
var h=el('div','font-size:12px;color:#7d8496;margin-bottom:10px;','Built with `npm pack`. Installs as a normal community node — uninstall/manage it in this list like any other.');
var f=el('input');f.type='file';f.accept='.tgz,.tar.gz';f.style.cssText='font-size:12px;margin-bottom:10px;display:block;';
var b=el('button','background:#ff6d5a;color:#fff;border:none;border-radius:6px;padding:8px 14px;font-size:13px;font-weight:600;cursor:pointer;','Upload & install');
var out=el('div','font-size:12px;margin-top:10px;white-space:pre-wrap;color:#555c6e;');
b.onclick=function(){var file=f.files&&f.files[0];
if(!file){out.textContent='Choose a .tgz file first.';return;}
b.disabled=true;b.textContent='Installing…';
var rd=new FileReader();rd.onload=function(){
api('/rest/custom-nodes/install',{method:'POST',body:JSON.stringify({filename:file.name,data:String(rd.result).split(',')[1]})})
.then(function(r){out.style.color='#29a568';
out.textContent='✔ Installed '+r.package+' v'+r.version+' ('+r.nodes+' node(s)). '+r.note;
if(r.native){setTimeout(function(){location.reload();},2500);}
else{var rb=el('button','margin-top:8px;background:#fff;border:1px solid #dbdfe7;border-radius:6px;padding:6px 12px;font-size:12px;cursor:pointer;display:block;','Restart n8n now');
rb.onclick=function(){rb.disabled=true;rb.textContent='Restarting… page will reload';
api('/rest/custom-nodes/restart',{method:'POST',body:'{}'}).catch(function(){}).finally(function(){setTimeout(function(){location.reload();},7000);});};
out.appendChild(rb);}})
.catch(function(e){out.style.color='#c0392b';out.textContent='✖ '+e.message;})
.finally(function(){b.disabled=false;b.textContent='Upload & install';});};
rd.readAsDataURL(file);};
w.appendChild(ti);w.appendChild(h);w.appendChild(f);w.appendChild(b);w.appendChild(out);return w;}
function inject(){if(document.querySelector('['+MARK+']'))return;
var ds=document.querySelectorAll('[role="dialog"], .el-dialog, [class*="modal"]');
for(var i=0;i<ds.length;i++){var d=ds[i];if(d.offsetParent===null)continue;
var t=(d.textContent||'').toLowerCase();
if(t.indexOf('community node')!==-1&&t.indexOf('npm')!==-1){
(d.querySelector('[class*="content"], [class*="body"]')||d).appendChild(build());return;}}}
window.n8nExternalHooks=window.n8nExternalHooks||{};
var ns=window.n8nExternalHooks.settingsCommunityNodesView=window.n8nExternalHooks.settingsCommunityNodesView||{};
ns.openInstallModal=(ns.openInstallModal||[]).concat([function(){setTimeout(inject,300);setTimeout(inject,900);}]);
new MutationObserver(function(){inject();}).observe(document.documentElement,{childList:true,subtree:true});
console.log('[custom-node-ui] loaded');})();
UI_EOF

info "Installing hook files into the n8n data volume..."
docker exec "$CONTAINER" mkdir -p /home/node/.n8n/hooks
docker cp "$TMP/custom-node-hooks.js" "$CONTAINER:/home/node/.n8n/hooks/"
docker cp "$TMP/custom-node-ui.js"    "$CONTAINER:/home/node/.n8n/hooks/"
docker exec -u root "$CONTAINER" chown -R node:node /home/node/.n8n/hooks 2>/dev/null || true
ok "Hook files installed (persist across updates — they live in the data volume)."

# --- FIX #3: portable random token. Prefer openssl; fall back to /dev/urandom
#     via od; final fallback to the kernel's own hex source.
if command -v openssl >/dev/null 2>&1; then
  TOKEN="$(openssl rand -hex 32)"
elif [ -r /dev/urandom ]; then
  TOKEN="$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')"
else
  TOKEN="$(head -c 64 /proc/sys/kernel/random/uuid | tr -d '-\n')$(date +%s)"
fi
[ -n "$TOKEN" ] || err "Could not generate an admin token."

if [ -n "$COMPOSE_DIR" ] && [ -d "$COMPOSE_DIR" ]; then
  cat > "$COMPOSE_DIR/docker-compose.override.yml" <<EOF
# Added by n8n custom-node-upload installer
services:
  ${SERVICE}:
    environment:
      - EXTERNAL_HOOK_FILES=/home/node/.n8n/hooks/custom-node-hooks.js
      - EXTERNAL_FRONTEND_HOOKS_URLS=/rest/custom-nodes/ui.js
      - CUSTOM_NODE_ADMIN_TOKEN=${TOKEN}
EOF
  ok "Created $COMPOSE_DIR/docker-compose.override.yml"
  info "Restarting n8n..."
  compose_up "$COMPOSE_DIR"
  ok "n8n restarted with the feature enabled."
else
  warn "Container isn't compose-managed. Recreate it with these extra flags:"
  echo "  -e EXTERNAL_HOOK_FILES=/home/node/.n8n/hooks/custom-node-hooks.js"
  echo "  -e EXTERNAL_FRONTEND_HOOKS_URLS=/rest/custom-nodes/ui.js"
  echo "  -e CUSTOM_NODE_ADMIN_TOKEN=${TOKEN}"
fi

echo
echo -e "${G}=====================================================${O}"
echo -e "${G} DONE! Custom Node Upload (native mode) is installed.${O}"
echo -e "${G} ADMIN TOKEN (save this):${O} ${TOKEN}"
echo -e "${G}=====================================================${O}"
echo
info "n8n -> Settings -> Community Nodes -> Install -> upload your .tgz."
info "Uploaded nodes appear in the Community Nodes list with n8n's"
info "native uninstall/manage options, and load without a restart."
info "Verify:  curl -s http://localhost:5678/rest/custom-nodes/status"
