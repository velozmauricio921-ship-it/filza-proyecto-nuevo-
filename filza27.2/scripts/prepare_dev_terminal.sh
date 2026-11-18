#!/bin/zsh
# Build the larger developer terminal payload: every a-Shell command except
# Python, Node.js, Lua/TeX (and commands that hard-depend on Python, such as
# vim and xxd). Resources for Perl/man/ImageMagick are kept.
#
# Usage: prepare_dev_terminal.sh <app-path> [ashell-ipa]
set -euo pipefail

APP="${1:A}"
ASHELL_IPA="${2:-$HOME/Downloads/Terminal.ipa}"
REPO_ROOT="${0:A:h:h}"
RES_SRC="$REPO_ROOT/../a-shell-master/Resources_mini"
[[ -d "$APP" ]] || { echo "app not found: $APP" >&2; exit 66; }
[[ -f "$ASHELL_IPA" ]] || { echo "a-Shell IPA not found: $ASHELL_IPA" >&2; exit 66; }
[[ -d "$RES_SRC" ]] || { echo "Resources_mini not found: $RES_SRC" >&2; exit 66; }

python3 - "$APP" "$ASHELL_IPA" "$RES_SRC" <<'PY'
import os, re, shutil, struct, sys, zipfile, plistlib

app, ipa, resources_mini = sys.argv[1], sys.argv[2], sys.argv[3]
z = zipfile.ZipFile(ipa)
names = z.namelist()
app_prefix = None
for n in names:
    m = re.match(r'(Payload/[^/]+\.app/)', n)
    if m:
        app_prefix = m.group(1)
        break
if not app_prefix:
    raise SystemExit('cannot find app prefix in IPA')
print('IPA app:', app_prefix)

def exclude_framework(name):
    n = name.lower().replace('.framework', '')
    if n.startswith('python') or n.startswith('python'):
        return 'Python'
    if n in ('node', 'npm', 'node-fetch'):
        return 'Node.js'
    if n in ('vim', 'xxd'):
        return 'Python dependency'
    tex_names = ('xetex', 'luatex', 'luahbtex', 'pdftex', 'euptex',
                 'texlua53', 'texluajit', 'kpathsea', 'kpsewhich', 'bibtex',
                 'metapost', 'mflua', 'mplib', 'mf')
    if n in tex_names or n.startswith('lua') or (
            n.startswith('tex') and n != 'text'):
        return 'TeX/Lua'
    if n in ('libllvm', 'clang', 'lld', 'ar'):
        return 'unused compiler'
    if n in ('libgdal', 'openblas', 'libgfortran', 'libproj', 'libgeos',
             'libgeos_c', 'libspatialindex', 'libspatialindex_c'):
        return 'Python geo/math'
    # Keep the A-E variants. ios_system picks a free variant for each
    # concurrent script/shell/SSH session, so stripping them breaks dash
    # scripts and parallel sessions.
    return None

fw_size = {}
fw_files = {}
for n in names:
    if not n.startswith(app_prefix + 'Frameworks/'):
        continue
    rest = n[len(app_prefix + 'Frameworks/'):]
    parts = rest.split('/')
    if len(parts) < 2 or not parts[0].endswith('.framework'):
        continue
    fw = parts[0]
    fw_size[fw] = fw_size.get(fw, 0) + z.getinfo(n).file_size
    fw_files.setdefault(fw, []).append(n)

def macho_deps(data):
    out = []
    if len(data) < 32:
        return out
    magic = struct.unpack_from('<I', data, 0)[0]
    if magic in (0xfeedfacf, 0xfeedface):
        ncmds = struct.unpack_from('<I', data, 16)[0]
        off = 32 if magic == 0xfeedfacf else 28
        for _ in range(ncmds):
            if off + 8 > len(data):
                break
            cmd, size = struct.unpack_from('<II', data, off)
            if size < 8 or off + size > len(data):
                break
            if (cmd & 0x7fffffff) in (0xc, 0x18, 0x1f, 0x23):
                nameoff = struct.unpack_from('<I', data, off + 8)[0]
                start = off + nameoff
                end = data.find(b'\0', start, off + size)
                if end > start:
                    out.append(data[start:end].decode('utf-8', 'replace'))
            off += size
    elif magic in (0xcafebabe, 0xcafebabf):
        n = struct.unpack_from('>I', data, 4)[0]
        for i in range(n):
            off = (struct.unpack_from('>I', data, 8 + i*20 + 8)[0]
                   if magic == 0xcafebabe else
                   struct.unpack_from('>Q', data, 8 + i*32 + 8)[0])
            out += macho_deps(data[off:])
    return out

deps = {}
for fw, files in fw_files.items():
    base = fw[:-len('.framework')]
    target = next((f for f in files if os.path.basename(f) == base), None)
    if target is None:
        continue
    try:
        for d in macho_deps(z.read(target)):
            if '.framework/' in d:
                deps.setdefault(fw, set()).add(d.split('/')[-2].replace('.framework', '') + '.framework')
    except Exception:
        pass

cd = plistlib.loads(z.read(app_prefix + 'commandDictionary.plist'))
selected = set()
for cmd, info in cd.items():
    if not isinstance(info, list) or len(info) < 4:
        continue
    path = info[0]
    if path == 'SELF':
        continue
    fw = path.split('/')[0]
    if not fw.endswith('.framework'):
        fw += '.framework'
    if fw in fw_size and not exclude_framework(fw):
        selected.add(fw)

# add transitive dependencies
pending = list(selected)
while pending:
    fw = pending.pop()
    for d in deps.get(fw, ()):
        if d in fw_size and d not in selected and not exclude_framework(d):
            selected.add(d)
            pending.append(d)

# ios_system appends A-E when it starts concurrent dash scripts. These
# variants are not referenced by commandDictionary.plist, so add them
# explicitly; otherwise `dash script.sh` fails to load dashA.framework.
for variant in ('dashA', 'dashB', 'dashC', 'dashD', 'dashE'):
    framework = variant + '.framework'
    if framework in fw_size:
        selected.add(framework)

print('selected frameworks:', len(selected), 'size:', round(sum(fw_size[f] for f in selected)/1e6, 1), 'MB')

# extract frameworks
os.makedirs(os.path.join(app, 'Frameworks'), exist_ok=True)
for fw in sorted(selected):
    dest = os.path.join(app, 'Frameworks', fw)
    shutil.rmtree(dest, ignore_errors=True)
    os.makedirs(dest, exist_ok=True)
    for n in fw_files[fw]:
        if '/_CodeSignature/' in n:
            continue
        rel = n[len(app_prefix + 'Frameworks/' + fw + '/'):]
        if not rel:
            continue
        out = os.path.join(dest, rel)
        if n.endswith('/'):
            os.makedirs(out, exist_ok=True)
            continue
        os.makedirs(os.path.dirname(out), exist_ok=True)
        info = z.getinfo(n)
        with z.open(n) as src, open(out, 'wb') as dst:
            shutil.copyfileobj(src, dst)
        mode = (info.external_attr >> 16) & 0o777
        if mode:
            os.chmod(out, mode)

# resources
wqres = os.path.join(app, 'WQResources')
shutil.rmtree(wqres, ignore_errors=True)
os.makedirs(wqres, exist_ok=True)
for sub in ('bin', 'usr'):
    src = os.path.join(resources_mini, sub)
    if os.path.isdir(src):
        shutil.copytree(src, os.path.join(wqres, sub), symlinks=True)

# top-level a-Shell resources that are not Python/Node/TeX
for sub in ('Perl', 'man', 'task', 'terminfo', 'ImageMagick-7'):
    dest = os.path.join(wqres, sub)
    found = False
    for n in names:
        if n.startswith(app_prefix + sub + '/'):
            if not found:
                shutil.rmtree(dest, ignore_errors=True)
                os.makedirs(dest, exist_ok=True)
                found = True
            rel = n[len(app_prefix + sub + '/'):]
            if not rel:
                continue
            out = os.path.join(dest, rel)
            if n.endswith('/'):
                os.makedirs(out, exist_ok=True)
                continue
            os.makedirs(os.path.dirname(out), exist_ok=True)
            info = z.getinfo(n)
            with z.open(n) as src, open(out, 'wb') as dst:
                shutil.copyfileobj(src, dst)
            mode = (info.external_attr >> 16) & 0o777
            if mode:
                os.chmod(out, mode)
    if found:
        print('resource:', sub)

for name in ('cacert.pem',):
    n = app_prefix + name
    if n in z.NameToInfo:
        with z.open(n) as src, open(os.path.join(wqres, name), 'wb') as dst:
            shutil.copyfileobj(src, dst)

# filtered command dictionary
out_cd = {}
for cmd, info in cd.items():
    if not isinstance(info, list) or len(info) < 4:
        continue
    path = info[0]
    if path == 'SELF':
        out_cd[cmd] = info
        continue
    fw = path.split('/')[0]
    if not fw.endswith('.framework'):
        fw += '.framework'
    if fw in selected:
        out_cd[cmd] = info
plistlib.dump(out_cd, open(os.path.join(app, 'commandDictionary.plist'), 'wb'))
print('commands kept:', len(out_cd), '/', len(cd))

# Remove zero-byte placeholders for excluded commands from WQResources/bin.
bin_dir = os.path.join(wqres, 'bin')
if os.path.isdir(bin_dir):
    for name in os.listdir(bin_dir):
        p = os.path.join(bin_dir, name)
        if not os.path.isfile(p) or os.path.getsize(p) != 0:
            continue
        if name not in out_cd:
            os.unlink(p)

print('done')
PY
