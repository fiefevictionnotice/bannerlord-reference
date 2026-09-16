# Helper for Relocate-BannerlordReference.ps1. Runs inside Blender headless on one .blend:
#   blender -b <file.blend> --python bl_relocate.py -- --list <out.json>
#       writes every external file the blend depends on: images (absolute path, whether it exists), image['bl_fullres_path']
#       props, linked libraries.
#   blender -b <file.blend> --python bl_relocate.py -- --remap <map.json> [--drop-fullres]
#       map.json = {"old absolute path": "new absolute path", ...}. Rewrites image paths (and bl_fullres_path props) through the
#       map, stores them RELATIVE to the blend (//...) when the target sits under the blend's folder tree, and saves the file.
#       --drop-fullres removes bl_fullres_path props whose target was not copied (so nothing points back at the old machine).
import bpy, os, sys, json
args = sys.argv[sys.argv.index('--') + 1:]
def opt(name, default=None): return args[args.index(name) + 1] if name in args else default
def norm(p): return os.path.normcase(os.path.normpath(p))
blend_dir = os.path.dirname(bpy.data.filepath)
# --origin <folder>: the folder the blend was COPIED FROM. Relative paths (//...) inside a copied blend must be resolved against
# the original location, otherwise they point into the new folder where the dependency does not exist yet.
ORIGIN = opt('--origin')
def absolute(fp):
    if ORIGIN and fp.startswith('//'): return os.path.normpath(os.path.join(ORIGIN, fp[2:]))
    return os.path.normpath(bpy.path.abspath(fp))
if '--list' in args:
    deps = []
    for im in bpy.data.images:
        if im.packed_file or not im.filepath: continue
        p = absolute(im.filepath); deps.append({'kind': 'image', 'name': im.name, 'path': p, 'exists': os.path.exists(p)})
        fr = im.get('bl_fullres_path')
        if fr: deps.append({'kind': 'fullres', 'name': im.name, 'path': os.path.normpath(fr), 'exists': os.path.exists(fr)})
    for lib in bpy.data.libraries:
        p = bpy.path.abspath(lib.filepath); deps.append({'kind': 'library', 'name': lib.name, 'path': os.path.normpath(p), 'exists': os.path.exists(p)})
    json.dump({'blend': bpy.data.filepath, 'deps': deps}, open(opt('--list'), 'w'), indent=1)
    print('[relocate] %s: %d image paths, %d full-res props, %d libraries' % (os.path.basename(bpy.data.filepath), sum(1 for d in deps if d['kind'] == 'image'), sum(1 for d in deps if d['kind'] == 'fullres'), len(bpy.data.libraries)))
elif '--remap' in args:
    m = {norm(k): v for k, v in json.load(open(opt('--remap'))).items()}
    def rel(p):
        try:
            if norm(os.path.commonpath([p, blend_dir])) == norm(blend_dir): return bpy.path.relpath(p, start=blend_dir)
        except ValueError: pass
        return p
    n_img = n_fr = n_drop = 0
    for im in bpy.data.images:
        if im.packed_file or not im.filepath: continue
        cur = norm(absolute(im.filepath))
        if cur in m: im.filepath = rel(m[cur]); n_img += 1
        else:   # not remapped: still make it relative if it already lives under the blend's folder
            ap = absolute(im.filepath); r = rel(ap)
            if r != ap: im.filepath = r
        fr = im.get('bl_fullres_path')
        if fr:
            if norm(fr) in m: im['bl_fullres_path'] = m[norm(fr)]; n_fr += 1
            elif '--drop-fullres' in args: del im['bl_fullres_path']; n_drop += 1
    for lib in bpy.data.libraries:
        cur = norm(absolute(lib.filepath))
        if cur in m: lib.filepath = rel(m[cur])
    compressed = open(bpy.data.filepath, 'rb').read(4) != b'BLEN'
    bpy.ops.wm.save_mainfile(filepath=bpy.data.filepath, compress=compressed, relative_remap=False)
    missing = sorted({os.path.basename(bpy.path.abspath(im.filepath)) for im in bpy.data.images if im.filepath and not im.packed_file and not os.path.exists(bpy.path.abspath(im.filepath))})
    print('[relocate] %s: %d image paths remapped, %d full-res props remapped, %d dropped; still missing on disk: %d %s' % (os.path.basename(bpy.data.filepath), n_img, n_fr, n_drop, len(missing), missing[:6]))
