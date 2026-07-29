import re, os, json, sys
from collections import Counter

def guid_map():
    g={}
    for root,_,files in os.walk('.'):
        for f in files:
            if f.endswith('.meta'):
                p=os.path.join(root,f)
                m=re.search(r'^guid: (\w+)',open(p,errors='ignore').read(),re.M)
                if m: g[m.group(1)]=os.path.relpath(p[:-5])
    return g
G=guid_map()

def v3(d,key):
    m=re.search(key+r': \{x: ([-\d.eE+]+), y: ([-\d.eE+]+), z: ([-\d.eE+]+)\}',d)
    return [float(x) for x in m.groups()] if m else None
def v4(d,key):
    m=re.search(key+r': \{x: ([-\d.eE+]+), y: ([-\d.eE+]+), z: ([-\d.eE+]+), w: ([-\d.eE+]+)\}',d)
    return [float(x) for x in m.groups()] if m else None

# For every prefab/model asset: its root transform fileID and that root's default TRS.
prefab_root={}
def prefab_info(path):
    if path in prefab_root: return prefab_root[path]
    info=(None,[0,0,0],[0,0,0,1],[1,1,1])
    if os.path.exists(path):
        t=open(path,errors='ignore').read()
        for d in re.split(r'\n(?=--- !u!)',t):
            m=re.match(r'--- !u!4 &(\d+)',d)
            if not m: continue
            f=re.search(r'm_Father: \{fileID: (\d+)\}',d)
            if f and f.group(1)=='0':
                info=(m.group(1), v3(d,'m_LocalPosition') or [0,0,0],
                      v4(d,'m_LocalRotation') or [0,0,0,1], v3(d,'m_LocalScale') or [1,1,1])
                break
    prefab_root[path]=info
    return info

txt=open('Scenes/nivelEscena.unity',errors='ignore').read()
docs=re.split(r'\n(?=--- !u!)',txt)
transforms={}; instances={}
for d in docs:
    m=re.match(r'--- !u!(\d+) &(\d+)',d)
    if not m: continue
    cid,fid=m.group(1),m.group(2)
    if cid=='4':
        f=re.search(r'm_Father: \{fileID: (\d+)\}',d)
        pi=re.search(r'm_PrefabInternal: \{fileID: (\d+)\}',d)
        transforms[fid]={'pos':v3(d,'m_LocalPosition'),'rot':v4(d,'m_LocalRotation'),
                         'scale':v3(d,'m_LocalScale'),'father':f.group(1) if f else '0',
                         'inst':pi.group(1) if pi else None}
    elif cid=='1001':
        gm=re.search(r'm_ParentPrefab: \{fileID: \d+, guid: (\w+)',d)
        tp=re.search(r'm_TransformParent: \{fileID: (\d+)\}',d)
        mods={}
        for tgt,prop,val in re.findall(
                r'- target: \{fileID: (-?\d+), guid: \w+,\s*\n?\s*type: \d+\}\s*\n'
                r'\s*propertyPath: (m_Local\w+\.\w)\s*\n\s*value: ([-\d.eE+]+)', d):
            mods.setdefault(tgt,{})[prop]=float(val)
        nm=re.search(r'propertyPath: m_Name\n *value: (.*)',d)
        instances[fid]={'prefab':G.get(gm.group(1),'?') if gm else '?','mods':mods,
                        'parent':tp.group(1) if tp else '0',
                        'name':nm.group(1).strip() if nm else None}

def qmul(a,b):
    ax,ay,az,aw=a; bx,by,bz,bw=b
    return [aw*bx+ax*bw+ay*bz-az*by, aw*by-ax*bz+ay*bw+az*bx,
            aw*bz+ax*by-ay*bx+az*bw, aw*bw-ax*bx-ay*by-az*bz]
def qrot(q,v):
    x,y,z,w=q; vx,vy,vz=v
    tx,ty,tz=2*(y*vz-z*vy),2*(z*vx-x*vz),2*(x*vy-y*vx)
    return [vx+w*tx+(y*tz-z*ty), vy+w*ty+(z*tx-x*tz), vz+w*tz+(x*ty-y*tx)]

def compose(ppos,prot,pscl, pos,rot,scl):
    sp=[pos[i]*pscl[i] for i in range(3)]
    rp=qrot(prot,sp)
    return ([ppos[i]+rp[i] for i in range(3)], qmul(prot,rot),
            [pscl[i]*scl[i] for i in range(3)])

def world_transform(tid, depth=0):
    if tid=='0' or tid not in transforms or depth>40:
        return [0.0,0.0,0.0],[0.0,0.0,0.0,1.0],[1.0,1.0,1.0]
    t=transforms[tid]
    inst=t['inst']
    if inst and inst in instances:
        return world_instance(inst, depth+1)
    pos=t['pos'] or [0,0,0]; rot=t['rot'] or [0,0,0,1]; scl=t['scale'] or [1,1,1]
    ppos,prot,pscl=world_transform(t['father'], depth+1)
    return compose(ppos,prot,pscl,pos,rot,scl)

def world_instance(iid, depth=0):
    inst=instances[iid]
    rootid,dpos,drot,dscl=prefab_info(inst['prefab'])
    mm=inst['mods'].get(rootid, {})
    if not mm and inst['mods']:
        # single-target instances sometimes key on a different id; take the block
        # that actually carries position data
        for k,v in inst['mods'].items():
            if any(p.startswith('m_LocalPosition') for p in v): mm=v; break
    pos=[mm.get('m_LocalPosition.'+a, dpos[i]) for i,a in enumerate('xyz')]
    rot=[mm.get('m_LocalRotation.'+a, drot[i]) for i,a in enumerate('xyzw')]
    scl=[mm.get('m_LocalScale.'+a, dscl[i]) for i,a in enumerate('xyz')]
    ppos,prot,pscl=world_transform(inst['parent'], depth+1)
    return compose(ppos,prot,pscl,pos,rot,scl)

PROPS={'silla.fbx','puerta.fbx','table.fbx','pc.fbx','pc2.fbx','cake.fbx','cable.fbx',
       'interruptor.fbx','meta.fbx','piezaParede.fbx','book.fbx','puertaInicio.prefab',
       'martillo_prefab.prefab','plataforma_prefab.prefab','plataformaCae.prefab',
       'tablePcs.prefab','particleSys_conffeti.prefab'}
out=[]
for iid,inst in instances.items():
    base=os.path.basename(inst['prefab'])
    if base not in PROPS: continue
    wp,wr,ws=world_instance(iid)
    out.append({'prefab':base,'name':inst['name'],
                'pos':[round(v,5) for v in wp],'rot':[round(v,6) for v in wr],
                'scale':[round(v,5) for v in ws]})
c=Counter(o['prefab'] for o in out)
for k,v in c.most_common(): print("  %-26s %d"%(k,v), file=sys.stderr)
print("  TOTAL %d instances"%len(out), file=sys.stderr)
json.dump(out, open(os.environ['SP']+'/props.json','w'), indent=1)
