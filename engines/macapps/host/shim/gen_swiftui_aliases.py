#!/usr/bin/env python3
"""Generate an ld64 -alias_list mapping ShimSUI symbols to SwiftUI symbols."""

import subprocess
import sys

# macOS SwiftUI symbols required by macOS SwiftUI guests (absent from iOS SwiftUI).
TARGET_SYMBOLS = [
    "_$s10NSViewType7SwiftUI0A13RepresentablePTl",
    "_$s11Coordinator7SwiftUI19NSViewRepresentablePTl",
    "_$s11Coordinator7SwiftUI29NSViewControllerRepresentablePTl",
    "_$s20NSViewControllerType7SwiftUI0aB13RepresentablePTl",
    "_$s7SwiftUI13NSHostingViewC04rootD0ACyxGx_tcfCTq",
    "_$s7SwiftUI13NSHostingViewC04rootD0ACyxGx_tcfc",
    "_$s7SwiftUI13NSHostingViewC04rootD0xvsTj",
    "_$s7SwiftUI13NSHostingViewC13sizingOptionsAA0c6SizingF0VvsTj",
    "_$s7SwiftUI13NSHostingViewC5coder04rootD0ACyxGSgSo7NSCoderC_xtcfCTq",
    "_$s7SwiftUI13NSHostingViewC5coder04rootD0ACyxGSgSo7NSCoderC_xtcfc",
    "_$s7SwiftUI13NSHostingViewCMn",
    "_$s7SwiftUI19NSHostingControllerC8rootViewACyxGx_tcfC",
    "_$s7SwiftUI19NSHostingControllerC8rootViewxvsTj",
    "_$s7SwiftUI19NSHostingControllerCMa",
    "_$s7SwiftUI19NSViewRepresentableMp",
    "_$s7SwiftUI19NSViewRepresentableP04makeC07context0C4TypeQzAA0cD7ContextVyxG_tFTq",
    "_$s7SwiftUI19NSViewRepresentableP06updateC0_7contexty0C4TypeQz_AA0cD7ContextVyxGtFTq",
    "_$s7SwiftUI19NSViewRepresentableP09dismantleC0_11coordinatory0C4TypeQz_11CoordinatorQztFZTq",
    "_$s7SwiftUI19NSViewRepresentableP12sizeThatFits_6nsView7contextSo6CGSizeVSgAA08ProposedI4SizeV_0C4TypeQzAA0cD7ContextVyxGtFTq",
    "_$s7SwiftUI19NSViewRepresentableP14_layoutOptionsyAA013_PlatformViewd6LayoutF0V0C4TypeQzFZTq",
    "_$s7SwiftUI19NSViewRepresentableP15makeCoordinator0F0QzyFTq",
    "_$s7SwiftUI19NSViewRepresentableP19_identifiedViewTree2inAA011_IdentifiedfG0O0C4TypeQz_tFTq",
    "_$s7SwiftUI19NSViewRepresentableP21_overrideLayoutTraits_3foryAA01_fG0Vz_0C4TypeQztFTq",
    "_$s7SwiftUI19NSViewRepresentableP21_overrideSizeThatFits_2in6nsViewySo6CGSizeVz_AA09_ProposedF0V0C4TypeQztFTq",
    "_$s7SwiftUI19NSViewRepresentableP24_modifyBridgedViewInputsyyAA01_gH0VzFZTq",
    "_$s7SwiftUI19NSViewRepresentableP35_invalidatesSizeOnConstraintChangesSbvgZTq",
    "_$s7SwiftUI19NSViewRepresentablePAA4ViewTb",
    "_$s7SwiftUI19NSViewRepresentablePAAE09dismantleC0_11coordinatory0C4TypeQz_11CoordinatorQztFZ",
    "_$s7SwiftUI19NSViewRepresentablePAAE12sizeThatFits_6nsView7contextSo6CGSizeVSgAA08ProposedI4SizeV_0C4TypeQzAA0cD7ContextVyxGtF",
    "_$s7SwiftUI19NSViewRepresentablePAAE13_makeViewList4view6inputsAA01_fG7OutputsVAA11_GraphValueVyxG_AA01_fG6InputsVtFZ",
    "_$s7SwiftUI19NSViewRepresentablePAAE14_layoutOptionsyAA013_PlatformViewd6LayoutF0V0C4TypeQzFZ",
    "_$s7SwiftUI19NSViewRepresentablePAAE19_identifiedViewTree2inAA011_IdentifiedfG0O0C4TypeQz_tF",
    "_$s7SwiftUI19NSViewRepresentablePAAE21_overrideLayoutTraits_3foryAA01_fG0Vz_0C4TypeQztF",
    "_$s7SwiftUI19NSViewRepresentablePAAE21_overrideSizeThatFits_2in6nsViewySo6CGSizeVz_AA09_ProposedF0V0C4TypeQztF",
    "_$s7SwiftUI19NSViewRepresentablePAAE24_modifyBridgedViewInputsyyAA01_gH0VzFZ",
    "_$s7SwiftUI19NSViewRepresentablePAAE35_invalidatesSizeOnConstraintChangesSbvgZ",
    "_$s7SwiftUI19NSViewRepresentablePAAE4bodys5NeverOvg",
    "_$s7SwiftUI19NSViewRepresentablePAAE9_makeView4view6inputsAA01_F7OutputsVAA11_GraphValueVyxG_AA01_F6InputsVtFZ",
    "_$s7SwiftUI19NSViewRepresentablePAAyt11CoordinatorRtzrlE04makeE0yyF",
    "_$s7SwiftUI22NSHostingSizingOptionsV7maxSizeACvgZ",
    "_$s7SwiftUI22NSHostingSizingOptionsV7minSizeACvgZ",
    "_$s7SwiftUI22NSHostingSizingOptionsVMa",
    "_$s7SwiftUI22NSHostingSizingOptionsVMn",
    "_$s7SwiftUI22NSHostingSizingOptionsVs10SetAlgebraAAMc",
    "_$s7SwiftUI26NSViewRepresentableContextV11coordinator11CoordinatorQzvg",
    "_$s7SwiftUI26NSViewRepresentableContextVMn",
    "_$s7SwiftUI29NSViewControllerRepresentableMp",
    "_$s7SwiftUI29NSViewControllerRepresentableP04makecD07context0cD4TypeQzAA0cdE7ContextVyxG_tFTq",
    "_$s7SwiftUI29NSViewControllerRepresentableP06updatecD0_7contexty0cD4TypeQz_AA0cdE7ContextVyxGtFTq",
    "_$s7SwiftUI29NSViewControllerRepresentableP09dismantlecD0_11coordinatory0cD4TypeQz_11CoordinatorQztFZTq",
    "_$s7SwiftUI29NSViewControllerRepresentableP12sizeThatFits_06nsViewD07contextSo6CGSizeVSgAA08ProposedJ4SizeV_0cD4TypeQzAA0cdE7ContextVyxGtFTq",
    "_$s7SwiftUI29NSViewControllerRepresentableP14_layoutOptionsyAA013_PlatformViewe6LayoutG0V0cD4TypeQzFZTq",
    "_$s7SwiftUI29NSViewControllerRepresentableP15makeCoordinator0G0QzyFTq",
    "_$s7SwiftUI29NSViewControllerRepresentableP19_identifiedViewTree2inAA011_IdentifiedgH0O0cD4TypeQz_tFTq",
    "_$s7SwiftUI29NSViewControllerRepresentableP35_invalidatesSizeOnConstraintChangesSbvgZTq",
    "_$s7SwiftUI29NSViewControllerRepresentablePAA4ViewTb",
    "_$s7SwiftUI29NSViewControllerRepresentablePAAE09dismantlecD0_11coordinatory0cD4TypeQz_11CoordinatorQztFZ",
    "_$s7SwiftUI29NSViewControllerRepresentablePAAE12sizeThatFits_06nsViewD07contextSo6CGSizeVSgAA08ProposedJ4SizeV_0cD4TypeQzAA0cdE7ContextVyxGtF",
    "_$s7SwiftUI29NSViewControllerRepresentablePAAE13_makeViewList4view6inputsAA01_gH7OutputsVAA11_GraphValueVyxG_AA01_gH6InputsVtFZ",
    "_$s7SwiftUI29NSViewControllerRepresentablePAAE14_layoutOptionsyAA013_PlatformViewe6LayoutG0V0cD4TypeQzFZ",
    "_$s7SwiftUI29NSViewControllerRepresentablePAAE19_identifiedViewTree2inAA011_IdentifiedgH0O0cD4TypeQz_tF",
    "_$s7SwiftUI29NSViewControllerRepresentablePAAE35_invalidatesSizeOnConstraintChangesSbvgZ",
    "_$s7SwiftUI29NSViewControllerRepresentablePAAE4bodys5NeverOvg",
    "_$s7SwiftUI29NSViewControllerRepresentablePAAE9_makeView4view6inputsAA01_G7OutputsVAA11_GraphValueVyxG_AA01_G6InputsVtFZ",
    "_$s7SwiftUI29NSViewControllerRepresentablePAAyt11CoordinatorRtzrlE04makeF0yyF",
    # LinkButtonStyle is macOS-only: iOS SwiftUI exports it but traps (CrossOver's catalog rows use it).
    "_$s7SwiftUI15LinkButtonStyleVAA09PrimitivedE0AAMc",
    "_$s7SwiftUI15LinkButtonStyleVACycfC",
    "_$s7SwiftUI15LinkButtonStyleVMa",
    "_$s7SwiftUI15LinkButtonStyleVMn",
]


def normalize_demangled(syms):
    inp = "\n".join(s.lstrip("_") for s in syms)
    out = subprocess.check_output(
        ["xcrun", "swift-demangle", "--compact"], input=inp, text=True
    )
    return dict(
        zip(
            syms,
            (
                line.replace("ShimSUI", "M")
                .replace("SwiftUICore", "M")
                .replace("SwiftUI", "M")
                for line in out.splitlines()
            ),
        )
    )


def main():
    if len(sys.argv) != 3:
        print(f"usage: {sys.argv[0]} <obj> <aliases_out>", file=sys.stderr)
        sys.exit(2)

    obj_path, out_path = sys.argv[1], sys.argv[2]
    nm_out = subprocess.check_output(["nm", "-g", "--defined-only", obj_path], text=True)
    obj_syms = sorted(set(l.split()[-1] for l in nm_out.splitlines() if l.strip()))

    obj_map = normalize_demangled(obj_syms)
    by_dem = {}
    for sym, dem in obj_map.items():
        by_dem.setdefault(dem, []).append(sym)

    target_map = normalize_demangled(TARGET_SYMBOLS)
    aliases = []
    missing = []
    for target in TARGET_SYMBOLS:
        if target in obj_syms:
            continue  # Already defined directly (e.g. via @_silgen_name)
        cands = by_dem.get(target_map[target], [])
        if not cands:
            missing.append((target, target_map[target]))
        else:
            aliases.append(f"{cands[0]} {target}\n")

    if missing:
        for t, d in missing:
            print(f"gen_swiftui_aliases: missing match for {t} ({d})", file=sys.stderr)
        sys.exit(1)

    with open(out_path, "w") as f:
        f.writelines(aliases)
    print(f"gen_swiftui_aliases: wrote {len(aliases)} aliases to {out_path}")


if __name__ == "__main__":
    main()
