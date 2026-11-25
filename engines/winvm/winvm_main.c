// SPDX-License-Identifier: GPL-2.0-or-later
// winvm: runs the winarm board on the Mac (development and tests before iOS).
//   winvm --code QEMU_EFI.fd --vars vars.fd [--ram MB] [--cpus N] [--nvme disk.img]
//         [--cdrom installer.iso] [--tpm state.bin] [--net] [--seconds N] [--screenshot out.ppm]
// The guest's serial console is stdin/stdout.
#include "winarm.h"
#include "dispatch.h"
#include "sysreg.h"
#include "disk.h"
#include "devices_ext.h"
#include "usb.h"
#include "gicv3.h"
#include "mmu.h"
#include "timer.h"
#include <pthread.h>
#include <signal.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <termios.h>
#include <unistd.h>
#include <sys/ucontext.h>

int winvm_hvf_run(HvMachine *m, HvCpu *cpu); /* hvf.c (WINVM_HVF=1, Mac test tool) */
static HvMachine m;
static HvCpu cpus[HV_MAX_CPUS];
static WinArm board;
static atomic_int stopping;

/* Translated code keeps the guest's SP in the host SP: a fault there needs its own signal stack. */
static void alt_stack(void) {
    stack_t ss = {.ss_sp = malloc(1 << 16), .ss_size = 1 << 16, .ss_flags = 0};
    if (ss.ss_sp) sigaltstack(&ss, NULL);
}

static void *secondary(void *arg) {
    HvCpu *c = arg;
    alt_stack();
    sigset_t set; sigfillset(&set);
    sigdelset(&set, SIGSEGV); sigdelset(&set, SIGBUS); sigdelset(&set, SIGILL); sigdelset(&set, SIGTRAP);
    pthread_sigmask(SIG_BLOCK, &set, NULL);
    hv_run(c);
    return NULL;
}

static void *kicker(void *arg) {
    (void)arg;
    while (!atomic_load(&stopping)) { usleep(1000); hv_machine_kick_all(&m); }
    return NULL;
}

static void *stdin_reader(void *arg) {
    (void)arg;
    for (;;) {
        int ch = getchar();
        if (ch == EOF) return NULL;
        hv_dev_lock(&m);
        hv_pl011_receive(board.uart, (uint8_t)(ch == '\n' ? '\r' : ch));
        hv_dev_unlock(&m);
        hv_machine_wake(&m);
    }
}

static void *timeout_thread(void *arg) {
    for (unsigned left = (unsigned)(uintptr_t)arg; left;) left = sleep(left); /* signals cut sleep short */
    fprintf(stderr, "\nwinvm: time limit reached\n");
    if (getenv("WINVM_RAMDUMP")) { /* debugging: guest RAM to a file */
        FILE *f = fopen(getenv("WINVM_RAMDUMP"), "wb");
        if (f) { fwrite(board.ram, 1, board.ram_size, f); fclose(f); }
    }
    hv_machine_halt(&m, HV_HALT_HOST);
    return NULL;
}

/* WINVM_TYPE="text" types text on the USB keyboard after WINVM_TYPE_DELAY seconds (default 60):
   "\\n" (a real newline) is Enter; for testing, since stdin goes to the UART. */
static void type_text(const char *s);
static void *type_thread(void *arg) {
    const char *s = getenv(arg);                         /* arg: "WINVM_TYPE" or "WINVM_TYPE2" */
    char name[32];
    snprintf(name, sizeof name, "%s_DELAY", (const char *)arg);
    const char *dl = getenv(name);
    usleep((useconds_t)((dl ? atof(dl) : 60.0) * 1e6));
    const char *rp = !strcmp(arg, "WINVM_TYPE") ? getenv("WINVM_TYPE_REPEAT") : NULL, *ev = getenv("WINVM_TYPE_EVERY"); /* type again N-1 more times, every EVERY s */
    int reps = rp ? atoi(rp) : 1;
    for (int rep = 0; rep < reps; rep++, sleep(ev ? (unsigned)atoi(ev) : 30)) type_text(s);
    return NULL;
}

/* Type text on the USB keyboard ("\n" Enter, "\t" Tab, ESC, 1 Down, 2 End, 0x18 Ctrl-X). */
/* US keyboard punctuation: the first 11 unshifted, the next 11 the same keys with Shift. */
static const char US_PUNCT[] = "-=[]\\;'`,./" "_+{}|:\"~<>?";
static const uint8_t US_PUNCT_USAGE[11] = {0x2d, 0x2e, 0x2f, 0x30, 0x31, 0x33, 0x34, 0x35, 0x36, 0x37, 0x38};
/* Shifted digits row: !@#$%^&*() */
static const char US_SHIFT_DIGITS[] = "!@#$%^&*()";

static void type_text(const char *s) {
    for (; *s; s++) {
        int c = (unsigned char)*s, shift = 0;
        uint8_t u = 0;
        if (c >= 'a' && c <= 'z') u = (uint8_t)(4 + c - 'a');
        else if (c >= 'A' && c <= 'Z') { u = (uint8_t)(4 + c - 'A'); shift = 1; }
        else if (c >= '1' && c <= '9') u = (uint8_t)(0x1e + c - '1');
        else if (c == '0') u = 0x27;
        else if (c && strchr(US_SHIFT_DIGITS, c)) { int i = (int)(strchr(US_SHIFT_DIGITS, c) - US_SHIFT_DIGITS); u = (uint8_t)(i == 9 ? 0x27 : 0x1e + i); shift = 1; }
        else if (c == '\n') u = 0x28;
        else if (c == '\t') u = 0x2b;
        else if (c == ' ') u = 0x2c;
        else if (c > 32 && c < 127 && strchr(US_PUNCT, c)) {   /* the rest of printable ASCII, US layout */
            const char *p = strchr(US_PUNCT, c);
            int i = (int)(p - US_PUNCT);
            u = US_PUNCT_USAGE[i % 11]; shift = i >= 11;
        }
        else if (c == '\033') u = 0x29;
        else if (c == 1) u = 0x51;                       /* Down */
        else if (c == 3) u = 0x52;                       /* Up */
        else if (c == 4) u = 0x4f;                       /* Right */
        else if (c == 5) u = 0x50;                       /* Left */
        else if (c == 2) u = 0x4d;                       /* End */
        else if (c == 0x18) { usb_key(0xe0, 1); usb_key(0x1b, 1); usleep(60000); usb_key(0x1b, 0); usb_key(0xe0, 0); usleep(60000); continue; } /* Ctrl-X */
        if (!u) continue;
        if (shift) usb_key(0xe1, 1);
        usb_key(u, 1); usleep(60000);
        usb_key(u, 0);
        if (shift) usb_key(0xe1, 0);
        usleep(60000);
    }
}

static int screenshot(const char *path);

/* WINVM_CTL=file: a control channel for driving the guest step by step. Each line written to the file
   (then the file is removed) is one command: "type TEXT" (with \n \t \e \d=Down \u=Up \r=Right \l=Left escapes),
   "shot PATH" (a PPM screenshot). */
static void *ctl_thread(void *arg) {
    const char *path = arg;
    for (;;) {
        usleep(300000);
        FILE *f = fopen(path, "r");
        if (!f) continue;
        char line[1024];
        while (fgets(line, sizeof line, f)) {
            line[strcspn(line, "\n")] = 0;
            if (!strncmp(line, "trace ", 6)) { fprintf(stderr, "winvm-ctl: trace %s %s\n", line + 6, hv_trace_dump(line + 6) ? "failed" : "ok"); continue; }
            /* "key MOD USAGE": one chord, both hex (MOD = HID modifier bits: 2 left Shift, 1 left Ctrl, 4 left Alt). */
            if (!strncmp(line, "key ", 4)) {
                unsigned mod = 0, u = 0;
                if (sscanf(line + 4, "%x %x", &mod, &u) == 2) {
                    for (int b = 0; b < 8; b++) if (mod >> b & 1) usb_key((uint8_t)(0xe0 + b), 1);
                    usb_key((uint8_t)u, 1); usleep(80000); usb_key((uint8_t)u, 0);
                    for (int b = 0; b < 8; b++) if (mod >> b & 1) usb_key((uint8_t)(0xe0 + b), 0);
                }
                continue;
            }
            if (!strncmp(line, "shot ", 5)) { fprintf(stderr, "winvm-ctl: shot %s %s\n", line + 5, screenshot(line + 5) ? "failed" : "ok"); continue; }
            int cx, cy;
            if (sscanf(line, "click %d %d", &cx, &cy) == 2 && board.fb.width) { /* framebuffer pixels: move, press, release */
                int ax = (int)((long)cx * 32767 / (board.fb.width - 1)), ay = (int)((long)cy * 32767 / (board.fb.height - 1));
                usb_tablet(ax, ay, 0, 0); usleep(150000);
                usb_tablet(ax, ay, 1, 0); usleep(120000);
                usb_tablet(ax, ay, 0, 0);
                fprintf(stderr, "winvm-ctl: clicked %d %d\n", cx, cy);
                continue;
            }
            if (strncmp(line, "type ", 5)) continue;
            char out[1024]; int n = 0;
            for (const char *c = line + 5; *c && n < 1000; c++) {
                if (*c != '\\' || !c[1]) { out[n++] = *c; continue; }
                c++;
                out[n++] = *c == 'n' ? '\n' : *c == 't' ? '\t' : *c == 'e' ? '\033' : *c == 'd' ? 1 : *c == 'u' ? 3 : *c == 'r' ? 4 : *c == 'l' ? 5 : *c;
            }
            out[n] = 0;
            type_text(out);
            fprintf(stderr, "winvm-ctl: typed %s\n", line + 5);
        }
        fclose(f);
        unlink(path);
    }
    return NULL;
}

/* WINVM_PCS=N: print each CPU's pc every N seconds (a cheap "where is the guest stuck" profiler). */
static void *pc_thread(void *arg) {
    unsigned every = (unsigned)(uintptr_t)arg;
    for (;;) {
        for (unsigned left = every; left;) left = sleep(left);
        fprintf(stderr, "winvm-pc:");
        for (int i = 0; i < board.ncpus; i++) fprintf(stderr, " cpu%d=%llx el%u esr=%llx elr=%llx far=%llx", i, (unsigned long long)cpus[i].pc, cpus[i].el,
                (unsigned long long)cpus[i].esr_el1, (unsigned long long)cpus[i].elr_el1, (unsigned long long)cpus[i].far_el1);
        fprintf(stderr, "\n");
        if (getenv("WINVM_GICDBG") && m.gic) {
            HvGic *g = m.gic;
            uint64_t now = hv_counter();
            fprintf(stderr, "  gicd ctlr=%x\n", g->ctlr);
            {
                static int dumped;
                int at = getenv("WINVM_DUMP_AT") ? atoi(getenv("WINVM_DUMP_AT")) : 6;
                if (dumped == at && getenv("WINVM_DUMP_VA")) { /* a guest VA range to a file, unmapped pages as zero */
                    uint64_t va0 = (cpus[1].pc & ~0x1fffffull) - 0x1000000, len = 0x1800000; fprintf(stderr, "  kva base %llx\n", (unsigned long long)va0);
                    FILE *f = fopen("/tmp/winboot/kva.bin", "wb");
                    static uint8_t pg[4096];
                    for (uint64_t o = 0; f && o < len; o += 4096) {
                        uint64_t pa;
                        memset(pg, 0, sizeof pg);
                        if (!hv_mmu_access(&cpus[0], va0 + o, HV_ACC_READ, 1, &pa)) hv_phys_read(&m, pa, pg, 4096);
                        fwrite(pg, 1, 4096, f);
                    }
                    if (f) fclose(f);
                }
                if (dumped == at && getenv("WINVM_PEEK")) { /* comma-separated VAs: print the 8 bytes at each */
                    char buf[512]; snprintf(buf, sizeof buf, "%s", getenv("WINVM_PEEK"));
                    for (char *t = strtok(buf, ","); t; t = strtok(NULL, ",")) {
                        uint64_t va = strtoull(t, NULL, 16), pa, q = 0xdead;
                        if (!hv_mmu_access(&cpus[0], va, HV_ACC_READ, 1, &pa)) hv_phys_read(&m, pa, &q, 8);
                        fprintf(stderr, "  peek %llx = %llx\n", (unsigned long long)va, (unsigned long long)q);
                    }
                }
                /* (An unconditional peek at guest memory through hv_mmu_access(&cpus[0]) was here: it walked CPU 0's
                   page tables from this thread while CPU 0 ran, racing its TLB and walk state -> random guest crashes
                   in every WINVM_GICDBG run. WINVM_DUMP_VA / WINVM_PEEK above still do that: debugging only.) */
                if (dumped == at)
                    for (int c = 0; c < board.ncpus; c++) {
                        HvGicCpu *k = &g->cpu[c];
                        fprintf(stderr, "  sgi%d:", c);
                        for (int i = 0; i < 16; i++) fprintf(stderr, " %d:e%dl%da%dp%x", i, k->enabled[i], k->latch[i], k->active[i], k->priority[i]);
                        fprintf(stderr, " bpr1=%llx stack:", (unsigned long long)k->bpr1);
                        for (int d = 0; d < k->depth; d++) fprintf(stderr, " %d/%x", k->stack[d].intid, k->stack[d].prio);
                        fprintf(stderr, "\n");
                    }
                if (dumped++ == at && getenv("WINVM_DUMP_CODE")) /* walks each CPU's tables from this thread: debugging only */
                    for (int c = 0; c < board.ncpus; c++) {
                        uint64_t base = cpus[c].pc - 0x100;
                        fprintf(stderr, "  code%d %llx:", c, (unsigned long long)base);
                        for (int w = 0; w < 0x100; w++) {
                            uint64_t pa; uint32_t insn = 0;
                            if (hv_mmu_access(&cpus[c], base + w * 4, HV_ACC_READ, 1, &pa) || hv_phys_read(&m, pa, &insn, 4)) insn = 0xdeadbeef;
                            fprintf(stderr, " %08x", insn);
                        }
                        fprintf(stderr, "\n  regs%d sp=%llx elr=%llx spsr=%llx x:", c, (unsigned long long)cpus[c].sp, (unsigned long long)cpus[c].elr_el1, (unsigned long long)cpus[c].spsr_el1);
                        for (int r = 0; r < 31; r++) fprintf(stderr, " %d=%llx", r, (unsigned long long)cpus[c].x[r]);
                        fprintf(stderr, "\n");
                    }
            }
            fprintf(stderr, "  cpu0 sp=%llx x:", (unsigned long long)cpus[0].sp);
            for (int r = 0; r < 31; r++) fprintf(stderr, " %d=%llx", r, (unsigned long long)cpus[0].x[r]);
            fprintf(stderr, "\n");
            for (int i = 0; i < board.ncpus; i++) {
                HvGicCpu *k = &g->cpu[i];
                fprintf(stderr, "  cpu%d daif=%llx off=%d vbar=%llx irq=%d fiq=%d pmr=%llx grpen0/1=%llu/%llu ctlr=%llx depth=%d top=%d waker=%x cntv ctl=%llx cval-now=%lld cntp ctl=%llx | ppi27 en%d g%d p%x lvl%d lat%d act%d ppi30 en%d g%d act%d\n",
                        i, (unsigned long long)cpus[i].daif, cpus[i].off, (unsigned long long)cpus[i].vbar_el1, m.percpu[i].irq_line, m.percpu[i].fiq_line,
                        (unsigned long long)k->pmr, (unsigned long long)k->igrpen0, (unsigned long long)k->igrpen1, (unsigned long long)k->icc_ctlr, k->depth,
                        k->depth ? k->stack[k->depth - 1].intid : -1, k->waker, (unsigned long long)cpus[i].cntv_ctl,
                        (long long)(cpus[i].cntv_cval - (now - cpus[i].cntvoff)), (unsigned long long)cpus[i].cntp_ctl,
                        k->enabled[27], k->group[27], k->priority[27], k->level[27], k->latch[27], k->active[27], k->enabled[30], k->group[30], k->active[30]);
            }
            for (int i = 32; i < HV_GIC_NUM_IRQS; i++)
                if (g->enabled[i] || g->active[i]) fprintf(stderr, "  spi%d en%d act%d lvl%d lat%d g%d p%x route=%llx\n", i, g->enabled[i], g->active[i], g->level[i], g->latch[i], g->group[i], g->priority[i], (unsigned long long)g->route[i]);
        }
    }
    return NULL;
}


/* Guest virtual memory through CPU 0's current mapping (debugging). */
static int gread(uint64_t va, void *buf, unsigned len) {
    uint8_t *p = buf;
    while (len) {
        uint64_t pa;
        unsigned chunk = 4096 - (unsigned)(va & 4095);
        if (chunk > len) chunk = len;
        if (hv_mmu_access(&cpus[0], va, HV_ACC_READ, 1, &pa) || hv_phys_read(&m, pa, p, chunk)) return -1;
        va += chunk, p += chunk, len -= chunk;
    }
    return 0;
}

/* Address of an ntoskrnl export, or 0. */
static uint64_t kexport(uint64_t base, const char *want) {
    uint32_t pe, edir, nnames, names, ords, funcs;
    if (gread(base + 0x3c, &pe, 4) || gread(base + pe + 24 + 112, &edir, 4) || !edir) return 0;
    gread(base + edir + 24, &nnames, 4); gread(base + edir + 28, &funcs, 4); gread(base + edir + 32, &names, 4); gread(base + edir + 36, &ords, 4);
    if (nnames > 20000) return 0;
    for (uint32_t i = 0; i < nnames; i++) {
        uint32_t nrva; char nm[40] = {0};
        unsigned wl = (unsigned)strlen(want) + 1;
        if (gread(base + names + 4 * i, &nrva, 4) || gread(base + nrva, nm, wl)) continue;
        if (memcmp(nm, want, wl)) continue;
        uint16_t ord; uint32_t frva;
        gread(base + ords + 2 * i, &ord, 2); gread(base + funcs + 4 * ord, &frva, 4);
        return base + frva;
    }
    return 0;
}

/* ADRP+ADD/LDR/STR targets in the first n instructions at f (candidate global variables). */
static int adrp_targets(uint64_t f, int n, uint64_t *out, int max) {
    uint32_t ins[512]; int k = 0;
    if (n > 512 || gread(f, ins, 4 * n)) return 0;
    for (int i = 0; i < n; i++) {
        uint32_t a = ins[i];
        if ((a & 0x9f000000) != 0x90000000) continue; /* ADRP */
        int rd = a & 31;
        int64_t imm = ((int64_t)(((a >> 5) & 0x7ffff) << 2 | ((a >> 29) & 3)) << 43) >> 31;
        uint64_t page = ((f + 4ull * i) & ~0xfffull) + imm;
        for (int j = i + 1; j < n && j < i + 8 && k < max; j++) {
            uint32_t b = ins[j];
            if ((b & 0xffc00000) == 0x91000000 && ((b >> 5) & 31) == rd) { out[k++] = page + ((b >> 10) & 0xfff); break; } /* ADD imm */
            if ((b & 0x3b400000) == 0x39400000 && ((b >> 5) & 31) == rd) {                                     /* LDR/STR unsigned imm */
                unsigned sz = b >> 30; out[k++] = page + (((b >> 10) & 0xfff) << sz); break;
            }
        }
    }
    return k;
}

/* At a guest restart: Windows' bugcheck code and parameters. KiBugCheckData isn't exported on recent builds, so
   follow KeBugCheckEx -> KeBugCheck2 and print globals referenced there that look like {code, p1..p4}. */
static void print_bugcheck(void) {
    uint64_t base = cpus[0].vbar_el1 & ~0xfffull;
    uint16_t mz = 0;
    for (int i = 0; i < 0x4000 && base; i++, base -= 0x1000)
        if (!gread(base, &mz, 2) && mz == 0x5a4d) break;
    if (mz != 0x5a4d) { fprintf(stderr, "winvm: bugcheck: no kernel image found\n"); return; }
    uint64_t d[5], v = kexport(base, "KiBugCheckData");
    if (v && !gread(v, d, sizeof d)) {
        fprintf(stderr, "winvm: bugcheck %llx (%llx, %llx, %llx, %llx)\n", (unsigned long long)d[0], (unsigned long long)d[1],
                (unsigned long long)d[2], (unsigned long long)d[3], (unsigned long long)d[4]);
        return;
    }
    uint64_t fn[4]; int nf = 0;
    uint64_t kbe = kexport(base, "KeBugCheckEx");
    if (!kbe) { fprintf(stderr, "winvm: bugcheck: no KeBugCheckEx\n"); return; }
    fn[nf++] = kbe;
    uint32_t ins[64];
    if (!gread(kbe, ins, sizeof ins))
        for (int i = 0; i < 64 && nf < 4; i++)
            if ((ins[i] & 0xfc000000) == 0x94000000) /* BL */
                fn[nf++] = kbe + 4ull * i + (uint64_t)((int64_t)((int32_t)(ins[i] << 6) >> 6) * 4);
    int shown = 0;
    for (int f = 0; f < nf; f++) {
        uint64_t t[96]; int k = adrp_targets(fn[f], 400, t, 96);
        for (int i = 0; i < k; i++) {
            if (gread(t[i], d, sizeof d) || !d[0] || d[0] > 0x1ff) continue;
            if (!d[1] && !d[2] && !d[3] && !d[4]) continue;
            fprintf(stderr, "winvm: bugcheck? %llx (%llx, %llx, %llx, %llx) at %llx\n", (unsigned long long)d[0], (unsigned long long)d[1],
                    (unsigned long long)d[2], (unsigned long long)d[3], (unsigned long long)d[4], (unsigned long long)t[i]);
            if (++shown >= 6) return;
        }
    }
    if (!shown) fprintf(stderr, "winvm: bugcheck: KiBugCheckData not found (kernel %llx)\n", (unsigned long long)base);
}

static int screenshot(const char *path) {
    if (!board.fb.addr || !board.fb.width) return -1;
    uint8_t *p = hv_phys_ptr(&m, board.fb.addr, (uint64_t)board.fb.stride * board.fb.height);
    if (!p) return -1;
    FILE *f = fopen(path, "wb");
    if (!f) return -1;
    fprintf(f, "P6\n%u %u\n255\n", board.fb.width, board.fb.height);
    for (uint32_t y = 0; y < board.fb.height; y++)
        for (uint32_t x = 0; x < board.fb.width; x++) {
            uint8_t *px = p + (uint64_t)y * board.fb.stride + x * 4; /* XRGB8888 little-endian: B G R X */
            fputc(px[2], f); fputc(px[1], f); fputc(px[0], f);
        }
    fclose(f);
    return 0;
}

/* A host fault (in translated code, say): where, what instruction, and where each guest CPU was. */
static void host_fault(int sig, siginfo_t *si, void *ctx) {
    ucontext_t *uc = ctx;
    uint64_t pc = uc->uc_mcontext->__ss.__pc;
    uint32_t insn = 0;
    if (pc) memcpy(&insn, (void *)pc, 4);
    fprintf(stderr, "\nwinvm: host signal %d at pc %llx insn %08x addr %p esr %x far %llx\n", sig, (unsigned long long)pc, insn,
            si->si_addr, uc->uc_mcontext->__es.__esr, (unsigned long long)uc->uc_mcontext->__es.__far);
    for (int r = 0; r < 31; r += 4)
        fprintf(stderr, "winvm:   x%d %llx %llx %llx %llx\n", r, (unsigned long long)uc->uc_mcontext->__ss.__x[r], (unsigned long long)uc->uc_mcontext->__ss.__x[r + 1],
                r + 2 < 29 ? (unsigned long long)uc->uc_mcontext->__ss.__x[r + 2] : 0ull, r + 3 < 29 ? (unsigned long long)uc->uc_mcontext->__ss.__x[r + 3] : 0ull);
    for (int i = 0; i < board.ncpus; i++)
        fprintf(stderr, "winvm:   guest cpu%d pc %llx el%u\n", i, (unsigned long long)cpus[i].pc, cpus[i].el);
    signal(sig, SIG_DFL);
}

int main(int argc, char **argv) {
    WinArmConfig cfg = {.ncpus = 2, .ram_mb = 4096};
    const char *nvme = NULL, *cdrom = NULL, *usbdisk = NULL, *shot = NULL, *tpm = NULL;
    int net = 0;
    unsigned seconds = 0;
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--code") && i + 1 < argc) cfg.code_path = argv[++i];
        else if (!strcmp(argv[i], "--vars") && i + 1 < argc) cfg.vars_path = argv[++i];
        else if (!strcmp(argv[i], "--ram") && i + 1 < argc) cfg.ram_mb = strtoull(argv[++i], NULL, 0);
        else if (!strcmp(argv[i], "--cpus") && i + 1 < argc) cfg.ncpus = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--nvme") && i + 1 < argc) nvme = argv[++i];
        else if (!strcmp(argv[i], "--cdrom") && i + 1 < argc) cdrom = argv[++i];
        else if (!strcmp(argv[i], "--usbdisk") && i + 1 < argc) usbdisk = argv[++i];
        else if (!strcmp(argv[i], "--tpm") && i + 1 < argc) tpm = argv[++i];
        else if (!strcmp(argv[i], "--net")) net = 1;
        else if (!strcmp(argv[i], "--seconds") && i + 1 < argc) seconds = (unsigned)atoi(argv[++i]);
        else if (!strcmp(argv[i], "--screenshot") && i + 1 < argc) shot = argv[++i];
        else { fprintf(stderr, "usage: winvm --code QEMU_EFI.fd --vars vars.fd [--ram MB] [--cpus N] [--nvme disk.img] [--cdrom iso] [--usbdisk img] [--tpm state.bin] [--seconds N] [--screenshot out.ppm]\n"); return 2; }
    }
    if (!cfg.code_path || !cfg.vars_path) { fprintf(stderr, "winvm: --code and --vars are required\n"); return 2; }
    signal(SIGPIPE, SIG_IGN);
    { struct sigaction sa = {0}; sa.sa_sigaction = host_fault; sa.sa_flags = SA_SIGINFO | SA_RESETHAND | SA_ONSTACK; alt_stack();
      sigaction(SIGBUS, &sa, NULL); sigaction(SIGSEGV, &sa, NULL); sigaction(SIGILL, &sa, NULL); }
    /* Match the app's EDK2 workaround pending a physical iPad retest. */
    if (!getenv("WINVM_TLBI_BLOCK")) setenv("HV_NO_TLBI_BLOCK", "1", 0);
    if (hv_machine_init(&m, (size_t)512 << 20) != 0) { fprintf(stderr, "winvm: JIT region\n"); return 1; }
    m.log = getenv("WINVM_LOG") ? atoi(getenv("WINVM_LOG")) : 0;
    char err[256];
    if (winarm_create(&board, &m, cpus, &cfg, err, sizeof err) != 0) { fprintf(stderr, "winvm: %s\n", err); return 1; }
    HvDisk disk, iso, udisk;
    if (nvme) {
        if (hv_disk_open(&disk, nvme, 0, 0) != 0 || !winvm_nvme_create(&board, &disk, 0)) { fprintf(stderr, "winvm: cannot attach %s\n", nvme); return 1; }
    }
    if (!winvm_usb_create(&board)) { fprintf(stderr, "winvm: cannot create the USB controller\n"); return 1; }
    if (cdrom) {
        if (hv_disk_open(&iso, cdrom, 0, 1) != 0 || !winvm_usb_storage_create(&board, &iso, 1)) { fprintf(stderr, "winvm: cannot attach %s\n", cdrom); return 1; }
    }
    if (usbdisk) {
        if (hv_disk_open(&udisk, usbdisk, 0, 0) != 0 || !winvm_usb_storage_create(&board, &udisk, 0)) { fprintf(stderr, "winvm: cannot attach %s\n", usbdisk); return 1; }
    }
    if (net) {
        static const uint8_t mac[6] = {0x52, 0x54, 0x00, 0x12, 0x34, 0x56};
        if (!winvm_usb_net_create(&board, mac)) { fprintf(stderr, "winvm: cannot attach the network adapter (built without libslirp?)\n"); return 1; }
    }
    if (tpm && !winvm_tpm_create(&board, tpm)) { fprintf(stderr, "winvm: cannot start the TPM (state %s; built without libtpms?)\n", tpm); return 1; }
    if (winarm_finalize(&board) != 0) { fprintf(stderr, "winvm: tables\n"); return 1; }

    pthread_t rd; pthread_create(&rd, NULL, stdin_reader, NULL); pthread_detach(rd);
    if (getenv("WINVM_TYPE")) { pthread_t t; pthread_create(&t, NULL, type_thread, "WINVM_TYPE"); pthread_detach(t); }
    /* Installer on a blank disk: answer "Press any key to boot from CD or DVD" (same as the app; WINVM_NOAUTOBOOT=1 to skip). */
    else if (cdrom && nvme && !getenv("WINVM_NOAUTOBOOT") && usb_autoboot_cd(&disk))
        fprintf(stderr, "winvm: blank disk: pressing Space until the installer loads\n");
    if (getenv("WINVM_CTL")) { pthread_t t; pthread_create(&t, NULL, ctl_thread, getenv("WINVM_CTL")); pthread_detach(t); }
    if (getenv("WINVM_TYPE2")) { pthread_t t; pthread_create(&t, NULL, type_thread, "WINVM_TYPE2"); pthread_detach(t); }
    if (getenv("WINVM_PCS")) { pthread_t t; pthread_create(&t, NULL, pc_thread, (void *)(uintptr_t)atoi(getenv("WINVM_PCS"))); pthread_detach(t); }
    if (seconds) { pthread_t t; pthread_create(&t, NULL, timeout_thread, (void *)(uintptr_t)seconds); pthread_detach(t); }
    int reason;
    for (;;) {
        winarm_reset(&board);
        atomic_store(&stopping, 0);
        pthread_t sec[HV_MAX_CPUS], kick;
        for (int i = 1; i < board.ncpus; i++) pthread_create(&sec[i], NULL, secondary, &cpus[i]);
        pthread_create(&kick, NULL, kicker, NULL);
        int r = getenv("WINVM_HVF") ? winvm_hvf_run(&m, &cpus[0]) : hv_run(&cpus[0]);
        reason = atomic_load(&cpus[0].halted);
        hv_machine_halt(&m, HV_HALT_HOST);
        atomic_store(&stopping, 1);
        for (int i = 1; i < board.ncpus; i++) pthread_join(sec[i], NULL);
        pthread_join(kick, NULL);
        if (reason != HV_HALT_RESET) {
            fprintf(stderr, "\nwinvm: stopped (exit %d, halt %d) at pc %llx el%u\n", r, reason, (unsigned long long)cpus[0].pc, cpus[0].el);
            break;
        }
        fprintf(stderr, "\nwinvm: guest restart\n");
        for (int i = 0; i < board.ncpus; i++)
            fprintf(stderr, "winvm: at restart cpu%d pc=%llx x0=%llx x1=%llx elr=%llx esr=%llx\n", i, (unsigned long long)cpus[i].pc,
                    (unsigned long long)cpus[i].x[0], (unsigned long long)cpus[i].x[1], (unsigned long long)cpus[i].elr_el1, (unsigned long long)cpus[i].esr_el1);
        if (shot && getenv("WINVM_RESET_SHOTS")) { /* what the guest showed last (a stop code, say) */
            static int n;
            char path[1024];
            snprintf(path, sizeof path, "%s.reset%d.ppm", shot, n++);
            if (screenshot(path) == 0) fprintf(stderr, "winvm: screenshot before restart: %s\n", path);
        }
        if (!getenv("WINVM_HVF")) print_bugcheck();
        for (int i = 0; i < board.ncpus; i++) atomic_store(&cpus[i].halted, HV_HALT_NONE);
        hv_flush_blocks(&m);
    }
    if (shot) fprintf(stderr, "winvm: screenshot %s\n", screenshot(shot) == 0 ? shot : "unavailable (no framebuffer)");
    pflash_close(&board.vars);
    return reason == HV_HALT_SHUTDOWN ? 0 : 1;
}
