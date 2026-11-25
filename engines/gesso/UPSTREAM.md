# Gesso (from Henge)

`engines/gesso/` is Triptych's own engine core, derived from [Henge](https://github.com/Leviidev/Henge.git)
and licensed under **GPL-2.0-or-later** (see [`LICENSE`](LICENSE) and the per-file headers).

## Origin

- **Upstream repository:** `https://github.com/Leviidev/Henge.git`
- **Imported commit:** `9cf6d26` (`triptych-fixes` branch of the prior `upstreams/henge` submodule:
  upstream base `e98920c` plus all 37 patches from `engines/macos/patches/series`, including
  `triptych-net-attach-rx.patch` and `triptych-jit-state.patch`).
- **Included:** the CPU core (`core/`), host layer (`host/`), device models (`devices/`),
  translation layer (`tl/`), restore dependencies (`third_party/`), engine tests (`tests/`),
  restore/agent tools (`tools/`), and the iOS bridge/UI/JIT helper sources compiled by Triptych
  (`ios/Henge/`, `ios/HengeJITHelper/`).
- **Omitted:** Henge's standalone app entrypoint (`HengeApp.swift`), icons/assets/entitlements/
  `Info.plist`/`project.yml`, `henge-jit.js` (Triptych ships `triptych-jit.js`), CI configs,
  screenshots, and Henge's standalone docs/AltStore source.

## Cherry-picking upstream fixes

Instead of maintaining a patch series on top of a submodule, cherry-pick upstream Henge commits
directly into `engines/gesso/`:

```sh
git remote add henge-upstream https://github.com/Leviidev/Henge.git
git fetch henge-upstream
git log --oneline e98920c..henge-upstream/main
```

Apply a commit into `engines/gesso/` (excluding Henge-only files such as `ios/Henge/HengeApp.swift`,
`.github/`, `Screenshots/`, `docs/`):

```sh
git format-patch -1 <commit> --stdout | git apply --directory=engines/gesso -p1 --3way
```

After applying:
1. Keep GPL-2.0-or-later headers and notices intact.
2. Rename any new user-visible `"Henge"` strings to `"Triptych"` (keep internal `hv_*` / `henge_*` symbols).
3. Verify:
   - `make -C engines/gesso test`
   - `make -C engines/winvm test`
   - `scripts/build-winvm.sh iphonesimulator`
   - `scripts/build-macos-engine.sh iphonesimulator` and Xcode Simulator build.
