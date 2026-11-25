#include "Bridge/triptych_bridge.h"
// Henge's app UI (ios/Henge/HengeBridge.h, kept in step).
#include "Native/henge-ios-jit.h"
#include "Native/henge-vm.h"
#include "Native/henge-tl.h"
#include "Native/HuskRPPairing.h"
#include "hvsparse.h"
// The winarm board (engines/winvm, built by scripts/build-winvm.sh): Windows PC page.
#include "Bridge/winvm_host.h"
// The x86pc board (engines/x86pc, QEMU x86-64 system emulation): x86 PC page.
#include "Bridge/x86pc_host.h"
// Optional on-device Curator model (llama.cpp).
#include "Curator/curator_llama.h"
