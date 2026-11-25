// SPDX-License-Identifier: GPL-3.0-or-later
// CrossOver's `wine PROGRAM ARGS` / `wineserver -k` reach Pane through PaneWineCommand (MacAppsKit).
#import <XCTest/XCTest.h>
@import MacAppsKit;
#include <unistd.h>

static char g_prefix[1024], g_exe[1024], g_args[4096];
static int g_runs, g_stops, g_loads;

static int StubRun(const char *prefix, const char *exe, const char *args, char *const envp[], int i, int o, int e) {
    (void)envp; (void)i; (void)e;
    g_runs++;
    snprintf(g_prefix, sizeof g_prefix, "%s", prefix);
    snprintf(g_exe, sizeof g_exe, "%s", exe);
    snprintf(g_args, sizeof g_args, "%s", args);
    if (o >= 0) (void)!write(o, "hello\n", 6);
    return 7;
}
static int StubBusy(const char *p, const char *x, const char *a, char *const v[], int i, int o, int e) {
    (void)p; (void)x; (void)a; (void)v; (void)i; (void)o; (void)e; return -16; /* -EBUSY */
}
static int StubStop(const char *prefix) { (void)prefix; g_stops++; return 0; }
static int StubLoad(void) { g_loads++; return 1; }

@interface PaneWineCommandTests : XCTestCase
@end

@implementation PaneWineCommandTests

- (void)tearDown { PaneWineCommandSetRunner(NULL, NULL); PaneWineCommandSetLoader(NULL); }

- (void)testProgramTranslation {
    char out[512];
    XCTAssertEqual(PaneWineCommandTranslateProgram("/b/Steam", "wineboot", out, sizeof out), 0);
    XCTAssertEqualObjects(@(out), @"wineboot.exe");
    XCTAssertEqual(PaneWineCommandTranslateProgram("/b/Steam/", "/b/Steam/drive_c/Program Files/Steam/steam.exe", out, sizeof out), 0);
    XCTAssertEqualObjects(@(out), @"C:\\Program Files\\Steam\\steam.exe");
    XCTAssertEqual(PaneWineCommandTranslateProgram("/b/Steam", "/tmp/SteamSetup.exe", out, sizeof out), 0);
    XCTAssertEqualObjects(@(out), @"Z:\\tmp\\SteamSetup.exe");
    XCTAssertEqual(PaneWineCommandTranslateProgram("/b/Steam", "C:\\x\\y.exe", out, sizeof out), 0);
    XCTAssertEqualObjects(@(out), @"C:\\x\\y.exe");
}

- (void)testArgumentQuoting {
    char out[512];
    char *argv[] = { "--init", "a b", "say \"hi\"", "", NULL };
    XCTAssertEqual(PaneWineCommandQuoteArgs(argv, out, sizeof out), 0);
    XCTAssertEqualObjects(@(out), @"--init \"a b\" \"say \\\"hi\\\"\" \"\"");
}

- (void)testWineRunsInBottleThroughPane {
    g_runs = 0; g_loads = 0;
    PaneWineCommandSetRunner(StubRun, StubStop);
    int p[2]; XCTAssertEqual(pipe(p), 0);
    char *argv[] = { "wine", "wineboot", "--init", NULL };
    char *envp[] = { "WINEPREFIX=/b/Steam", "WINEDEBUG=-all", NULL };
    int rc = PaneWineCommandRun("/CrossOver.app/Contents/SharedSupport/CrossOver/lib/wine/aarch64-unix/wine", argv, envp, -1, p[1], -1);
    close(p[1]);
    char buf[16] = {0}; (void)!read(p[0], buf, sizeof buf - 1); close(p[0]);
    XCTAssertEqual(rc, 7);
    XCTAssertEqual(g_runs, 1);
    XCTAssertEqualObjects(@(g_prefix), @"/b/Steam");
    XCTAssertEqualObjects(@(g_exe), @"wineboot.exe");
    XCTAssertEqualObjects(@(g_args), @"--init");
    XCTAssertEqualObjects(@(buf), @"hello\n");
}

- (void)testNeedsBottleAndReportsBusySession {
    PaneWineCommandSetRunner(StubBusy, StubStop);
    char *argv[] = { "wine", "steam.exe", NULL };
    char *none[] = { NULL };
    XCTAssertEqual(PaneWineCommandRun("/x/wine", argv, none, -1, -1, -1), 1);
    char *envp[] = { "WINEPREFIX=/b/Other", NULL };
    XCTAssertEqual(PaneWineCommandRun("/x/wine", argv, envp, -1, -1, -1), 126);
}

- (void)testWineserverKillStopsSession {
    g_stops = 0;
    PaneWineCommandSetRunner(StubRun, StubStop);
    char *argv[] = { "wineserver", "-k", NULL };
    char *envp[] = { "WINEPREFIX=/b/Steam", NULL };
    XCTAssertEqual(PaneWineCommandRun("/x/wineserver", argv, envp, -1, -1, -1), 0);
    XCTAssertEqual(g_stops, 1);
}

- (void)testLoaderRunsBeforeLookup {
    g_loads = 0;
    PaneWineCommandSetLoader(StubLoad);
    char *argv[] = { "wine", "cmd", NULL };
    char *envp[] = { "WINEPREFIX=/b/Steam", NULL };
    // No runner override and no Pane in the Simulator: the loader is asked, then the command fails cleanly.
    XCTAssertEqual(PaneWineCommandRun("/x/wine", argv, envp, -1, -1, -1), 126);
    XCTAssertEqual(g_loads, 1);
}

@end
