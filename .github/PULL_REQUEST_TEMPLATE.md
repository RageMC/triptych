## Summary

- **Engine / Component:** <!-- e.g., Gesso, Casement (winvm), Pane, Atelier (MacAppsKit), Fresco, x86 PC, Curator -->
- **Related Issue(s):** <!-- e.g., RageMC/triptych-issues#123 -->

## Verification

- [ ] `make -C engines/gesso test` and `make -C engines/winvm test` pass (if engine/VM code changed)
- [ ] Simulator build and `TriptychTests` / `TriptychUITests` pass (if app/UI code changed)
- [ ] No proprietary binaries, firmware, Apple/Windows images, keys, or personal paths (`/Users/...`) included
- [ ] Third-party code/patches are GPL-3.0-compatible and documented in `CREDITS.md`
