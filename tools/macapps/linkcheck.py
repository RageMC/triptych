#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Static link check for a retagged Mac app: for every arm64 Mach-O in the bundle, resolve each imported symbol
against the dependency it is bound to (two-level namespace), the way dyld will in the iOS Simulator/device.
Dependencies resolve to: Triptych's shim dylibs (@rpath/libShim_*), files inside the bundle (@loader_path, @rpath),
or the iOS SDK (/System/Library/..., /usr/lib/...). ld does the resolving, so re-exports and .tbd stubs are honoured.
Usage: linkcheck.py APP.app [--shims DIR] [--sdk iphonesimulator] [--only REL_PATH_SUBSTR] [--json OUT]"""
import argparse, json, os, re, subprocess, sys, tempfile, collections

SDKROOT = None
ALL_MACHOS = []

def sh(*a):
    return subprocess.run(a, capture_output=True, text=True)

def machos(app):
    for root, ds, fs in os.walk(app):
        for n in fs:
            p = os.path.join(root, n)
            if os.path.islink(p): continue
            try:
                with open(p, 'rb') as f: h = f.read(8)
            except OSError: continue
            if h[:4] == b'\xcf\xfa\xed\xfe' and h[4:8] == b'\x0c\x00\x00\x01': yield p

def load_cmds(p):
    """(deps [(path, weak)], rpaths) in ordinal order."""
    deps, rpaths, cur = [], [], None
    for line in sh('otool', '-l', p).stdout.splitlines():
        s = line.strip()
        if s.startswith('cmd '): cur = s.split()[1]
        elif s.startswith('name ') and cur in ('LC_LOAD_DYLIB', 'LC_LOAD_WEAK_DYLIB', 'LC_REEXPORT_DYLIB', 'LC_LAZY_LOAD_DYLIB', 'LC_LOAD_UPWARD_DYLIB'):
            deps.append((s[5:].rsplit(' (offset', 1)[0], cur == 'LC_LOAD_WEAK_DYLIB'))
        elif s.startswith('path ') and cur == 'LC_RPATH':
            rpaths.append(s[5:].rsplit(' (offset', 1)[0])
    return deps, rpaths

def imports(p):
    """{dep leaf name: set(symbols)} for non-weak imports, from nm -m (two-level namespace)."""
    out = collections.defaultdict(set)
    for line in sh('nm', '-m', '-u', p).stdout.splitlines():
        m = re.match(r'\s*\(undefined\)\s*(weak )?.*?external (\S+) \(from (\S+)\)', line)
        if m and not m.group(1): out[m.group(3)].add(m.group(2))
    return out

def leaf(dep):
    b = os.path.basename(dep)
    return b[:-6] if b.endswith('.dylib') else b

def resolve(dep, p, rpaths, app, shims, exe_dir):
    """Concrete file or ('sdk', path) for a dependency of p."""
    ld = os.path.dirname(p)
    def subst(x):
        return x.replace('@loader_path', ld).replace('@executable_path', exe_dir)
    if dep.startswith('@rpath/'):
        rest = dep[len('@rpath/'):]
        for rp in rpaths:
            if rp == '@executable_path/Frameworks':
                c = os.path.join(shims, rest)
            elif rp.startswith('/'):
                if sdk_flag(os.path.join(rp, rest), SDKROOT): return ('sdk', os.path.join(rp, rest))
                continue
            else:
                c = os.path.join(subst(rp), rest)
            if os.path.exists(c): return c
        # The host (Triptych) is dyld's main executable; its rpath @executable_path/Frameworks holds the shims.
        c = os.path.join(shims, rest)
        if os.path.exists(c): return c
        # No own rpath hit: dyld also searches the rpaths of the images that loaded this one (wine's
        # @loader_path/../lib/aarch64 for its glib/gstreamer libraries). Approximate that with a unique arm64 file of
        # this name elsewhere in the bundle.
        hits = [q for q in ALL_MACHOS if os.path.basename(q) == os.path.basename(rest)]
        return hits[0] if len(hits) == 1 else None
        return None
    if dep.startswith('@'):
        c = os.path.normpath(subst(dep))
        return c if os.path.exists(c) else None
    return ('sdk', dep)

def sdk_flag(path, sdkroot):
    m = re.match(r'/System/Library/(?:Private)?Frameworks/([^/]+)\.framework/', path)
    tbd = None
    if m:
        for d in ('System/Library/Frameworks', 'System/Library/PrivateFrameworks'):
            base = os.path.join(sdkroot, d, m.group(1) + '.framework')
            for c in (os.path.join(base, m.group(1) + '.tbd'), os.path.join(base, m.group(1))):
                if os.path.exists(c): tbd = c
    else:
        c = os.path.join(sdkroot, path.lstrip('/'))
        c2 = re.sub(r'\.dylib$', '.tbd', c)
        tbd = c2 if os.path.exists(c2) else (c if os.path.exists(c) else None)
    return tbd

def expand(lib, shims, sdkroot, seen=None):
    """lib plus the libraries it re-exports (recursively), as files ld can read without @rpath lookups."""
    seen = seen if seen is not None else set()
    if lib in seen or lib.endswith('.tbd'): return [lib] if lib not in seen else []
    seen.add(lib)
    out = [lib]
    deps, _ = load_cmds_reexport(lib)
    for d in deps:
        if d.startswith('@rpath/'): c = os.path.join(shims, d[len('@rpath/'):])
        else: c = sdk_flag(d, sdkroot)
        if c and os.path.exists(c): out += expand(c, shims, sdkroot, seen)
    return out

def load_cmds_reexport(p):
    deps, cur = [], None
    for line in sh('otool', '-l', p).stdout.splitlines():
        s = line.strip()
        if s.startswith('cmd '): cur = s.split()[1]
        elif s.startswith('name ') and cur == 'LC_REEXPORT_DYLIB': deps.append(s[5:].rsplit(' (offset', 1)[0])
    return deps, []

def missing_symbols(libs, syms, target, tmp, sdk):
    """Symbols from syms that lib (file or .tbd) does not provide, according to ld."""
    if not syms: return []
    uf = os.path.join(tmp, 'u.txt')
    with open(uf, 'w') as f:
        for s in sorted(syms): f.write(s + '\n')
    stub = os.path.join(tmp, 's.c')
    if not os.path.exists(stub): open(stub, 'w').write('void _triptych_linkcheck(void){}\n')
    r = sh('xcrun', '--sdk', sdk, 'clang', '-target', target, '-dynamiclib', stub, *libs,
           '-Wl,-undefined,error', *[f'-Wl,-u,{s}' for s in sorted(syms)],
           '-o', os.path.join(tmp, 'o.dylib'))
    if r.returncode == 0: return []
    miss = set(re.findall(r'^\s+"([^"]+)", referenced from', r.stderr, re.M))
    # ld prints C names without the leading underscore
    return sorted(s for s in syms if s in miss or (s.startswith('_') and s[1:] in miss)) or ['<ld error> ' + r.stderr.strip()[-300:]]

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('app'); ap.add_argument('--shims', required=True)
    ap.add_argument('--sdk', default='iphonesimulator'); ap.add_argument('--only', action='append')
    ap.add_argument('--json')
    a = ap.parse_args()
    global SDKROOT
    sdkroot = SDKROOT = sh('xcrun', '--sdk', a.sdk, '--show-sdk-path').stdout.strip()
    target = 'arm64-apple-ios17.0' + ('-simulator' if a.sdk == 'iphonesimulator' else '')
    info = sh('/usr/libexec/PlistBuddy', '-c', 'Print CFBundleExecutable', os.path.join(a.app, 'Contents/Info.plist')).stdout.strip()
    exe_dir = os.path.join(a.app, 'Contents/MacOS')
    ALL_MACHOS[:] = list(machos(a.app))
    report = {}
    with tempfile.TemporaryDirectory() as tmp:
        for p in sorted(ALL_MACHOS):
            rel = os.path.relpath(p, a.app)
            if a.only and not any(o in rel for o in a.only): continue
            deps, rpaths = load_cmds(p)
            imp = imports(p)
            probs = {}
            for dep, weak in deps:
                syms = imp.get(leaf(dep), set())
                r = resolve(dep, p, rpaths, a.app, a.shims, exe_dir)
                if isinstance(r, tuple):
                    lib = sdk_flag(r[1], sdkroot)
                    if not lib:
                        if not weak: probs[dep] = ['<library not in iOS SDK>']
                        continue
                elif r is None:
                    if not weak: probs[dep] = ['<unresolved>']
                    continue
                else:
                    lib = r
                m = missing_symbols(expand(lib, a.shims, sdkroot), syms, target, tmp, a.sdk)
                if m: probs[dep] = m
            if probs: report[rel] = probs
    if a.json:
        json.dump(report, open(a.json, 'w'), indent=1, sort_keys=True)
    total = sum(len(v) for d in report.values() for v in d.values())
    for rel, probs in report.items():
        print(rel)
        for dep, m in probs.items():
            print(f'  {dep}: {len(m)} missing: ' + ' '.join(m[:8]) + (' ...' if len(m) > 8 else ''))
    print(f'{len(report)} files with problems, {total} missing symbols/libraries')
    return 1 if report else 0

if __name__ == '__main__':
    sys.exit(main())
