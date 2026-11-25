// SPDX-License-Identifier: GPL-3.0-or-later
// CrossOver's cx tools run in Triptych's in-process Perl (PerlCommand.c + Triptych::Process): output goes to the
// command's FDs, %ENV stays the script's own, and every child process goes through MacProcessShim; nothing forks.
#import <XCTest/XCTest.h>
@import MacAppsKit;
#include <stdlib.h>
#include <sys/stat.h>
#include <unistd.h>

static char *const kEnv[] = { "PATH=/usr/bin:/bin", "HOME=/tmp", NULL };

@interface PerlCommandTests : XCTestCase
@end

@implementation PerlCommandTests

- (void)setUp { PerlCommandInstall(); }
- (void)tearDown { MacProcessShimSetPerlRuntime(NULL); }

/// Runs `perl -e code args` with stdout and stderr captured.
- (int)eval:(NSString *)code args:(NSArray<NSString *> *)args env:(char *const *)env
        out:(NSString **)outText err:(NSString **)errText {
    int o[2], e[2];
    XCTAssertEqual(pipe(o), 0);
    XCTAssertEqual(pipe(e), 0);
    char *argv[16] = {0};
    for (NSUInteger i = 0; i < args.count && i < 15; i++) argv[i] = (char *)args[i].UTF8String;
    __block int rc = -1;
    char **av = argv;
    int outW = o[1], errW = e[1];
    // A shim command's thread, as in the app (its own big stack, never the main thread).
    NSThread *t = [[NSThread alloc] initWithBlock:^{
        rc = PerlCommandEval(code.UTF8String, av, env ? env : kEnv, -1, outW, errW);
    }];
    t.stackSize = 16 << 20;
    [t start];
    while (!t.isFinished) [NSThread sleepForTimeInterval:0.01];
    close(o[1]);
    close(e[1]);
    NSFileHandle *oh = [[NSFileHandle alloc] initWithFileDescriptor:o[0] closeOnDealloc:YES];
    NSFileHandle *eh = [[NSFileHandle alloc] initWithFileDescriptor:e[0] closeOnDealloc:YES];
    if (outText) *outText = [[NSString alloc] initWithData:[oh readDataToEndOfFile] encoding:NSUTF8StringEncoding];
    if (errText) *errText = [[NSString alloc] initWithData:[eh readDataToEndOfFile] encoding:NSUTF8StringEncoding];
    return rc;
}

- (void)testPrintsToCommandFds {
    NSString *out, *err;
    int rc = [self eval:@"print qq{hi $ARGV[0]\\n}; print STDERR qq{warn\\n}; printf qq{%03d\\n}, 7"
                   args:@[@"you"] env:NULL out:&out err:&err];
    XCTAssertEqual(rc, 0);
    XCTAssertEqualObjects(out, @"hi you\n007\n");
    XCTAssertEqualObjects(err, @"warn\n");
}

- (void)testExitStatusDieAndCompileError {
    XCTAssertEqual([self eval:@"exit 3" args:@[] env:NULL out:NULL err:NULL], 3);
    NSString *err;
    XCTAssertEqual([self eval:@"$! = 0; $? = 0; die qq{boom\\n}" args:@[] env:NULL out:NULL err:&err], 255);
    XCTAssertEqualObjects(err, @"boom\n");
    XCTAssertEqual([self eval:@"sub {" args:@[] env:NULL out:NULL err:&err], 255);
    XCTAssertTrue([err containsString:@"syntax error"] || [err containsString:@"Missing right curly"], @"%@", err);
}

- (void)testEnvironmentStaysInsideTheScript {
    char *env[] = { "PATH=/usr/bin:/bin", "TRIPTYCH_PERL_T=1", NULL };
    NSString *out;
    int rc = [self eval:@"$ENV{TRIPTYCH_PERL_LEAK} = 1; print $ENV{TRIPTYCH_PERL_T}; use POSIX (); use Cwd ();"
                   args:@[] env:env out:&out err:NULL];
    XCTAssertEqual(rc, 0);
    XCTAssertEqualObjects(out, @"1");
    XCTAssertTrue(getenv("TRIPTYCH_PERL_LEAK") == NULL);
}

- (void)testSystemQxAndPipeOpensGoThroughTheShim {
    NSString *out, *err;
    int rc = [self eval:@"my $u = qx{uname -s 2>/dev/null}; print qq{qx=$u};"
                         "system('false'); print 'false=', $? >> 8, qq{\\n};"
                         "print 'true=', system('/usr/bin/true'), qq{\\n};"
                         "open(my $p, '-|', 'uname', '-s') or die $!; my $l = <$p>; close($p); print qq{pipe=$l};"
                         "open(P, 'uname -s |') or die $!; print 'bare=', <P>; close(P) or die 'close';"
                         "print 'list=', scalar(my @x = `uname -s`), qq{\\n};"
                         "system('nonexistent-tool-xyz'); print 'missing=', $?, qq{\\n};"
                   args:@[] env:NULL out:&out err:&err];
    XCTAssertEqual(rc, 0, @"%@", err);
    XCTAssertEqualObjects(out, @"qx=Darwin\nfalse=1\ntrue=0\npipe=Darwin\nbare=Darwin\nlist=1\nmissing=-1\n");
}

- (void)testForkExecKillAndSignalsNeverTouchTheApp {
    NSString *out, *err;
    int rc = [self eval:@"print defined(fork()) ? 'forked' : 'nofork', qq{\\n};"
                         "print defined(CORE::fork()) ? 'coreforked' : 'nocorefork', qq{\\n};"
                         "print 'kill=', kill(15, $$), qq{\\n};"
                         "$SIG{ALRM} = sub { print 'alarm' }; alarm 1; $SIG{TERM} = 'IGNORE';"
                         "END { print qq{end\\n} } exec('false'); print qq{not reached\\n}"
                   args:@[] env:NULL out:&out err:&err];
    XCTAssertEqual(rc, 1);
    XCTAssertEqualObjects(out, @"nofork\nnocorefork\nkill=0\n");
    XCTAssertTrue([err containsString:@"fork refused"], @"%@", err);
    [NSThread sleepForTimeInterval:1.2];  // the app is still here: no SIGALRM was armed
}

- (void)testNestedPerlScriptRunsInItsOwnInterpreter {
    NSString *dir = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    [NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *script = [dir stringByAppendingPathComponent:@"child"];
    [@"#!/usr/bin/perl -w\nuse strict;\nmy $in = <STDIN> // q{}; chomp $in;\nprint qq{child @ARGV $ENV{X} $in\\n};\n"
     "print STDERR qq{to log\\n};\nexit 4;\n"
        writeToFile:script atomically:YES encoding:NSUTF8StringEncoding error:nil];
    chmod(script.fileSystemRepresentation, 0755);
    NSString *out, *err;
    int rc = [self eval:@"$ENV{X} = 'y'; open(my $w, '|-', $ARGV[0], 'a b') or die $!; print $w qq{fed\\n};"
                         "close($w); print 'st=', $? >> 8, qq{\\n};"
                         "my $log = qq{$ARGV[1]/log}; system(qq{X=z '$ARGV[0]' c </dev/null >>$log 2>&1});"
                         "open(my $l, '<', $log) or die; print <$l>;"
                   args:@[script, dir] env:NULL out:&out err:&err];
    XCTAssertEqual(rc, 0, @"%@", err);
    XCTAssertEqualObjects(out, @"child a b y fed\nst=4\nchild c z \nto log\n");
    XCTAssertEqualObjects(err, @"to log\n");
    [NSFileManager.defaultManager removeItemAtPath:dir error:nil];
}

- (void)testUnsupportedShellSyntaxIsReported {
    NSString *out, *err;
    int rc = [self eval:@"print system('true && true'), qq{\\n}" args:@[] env:NULL out:&out err:&err];
    XCTAssertEqual(rc, 0);
    XCTAssertEqualObjects(out, @"-1\n");
    XCTAssertTrue([err containsString:@"unsupported shell command"], @"%@", err);
}

/// CrossOver Preview's own cxbottle under Triptych's Perl. Needs the user's CrossOver Preview.app (never bundled):
/// TEST_RUNNER_TRIPTYCH_CROSSOVER_APP=/path/to/CrossOver Preview.app
- (void)testCrossOverCxbottleHelp {
    NSString *app = NSProcessInfo.processInfo.environment[@"TRIPTYCH_CROSSOVER_APP"];
    if (!app.length) { XCTSkip(@"TRIPTYCH_CROSSOVER_APP not set"); }
    NSString *cxbottle = [app stringByAppendingPathComponent:@"Contents/SharedSupport/CrossOver/bin/cxbottle"];
    XCTAssertTrue([NSFileManager.defaultManager fileExistsAtPath:cxbottle]);
    int o[2];
    XCTAssertEqual(pipe(o), 0);
    char *argv[] = { (char *)cxbottle.fileSystemRepresentation, "--help", NULL };
    __block int rc = -1;
    char **av = argv;
    int w = o[1];
    NSThread *t = [[NSThread alloc] initWithBlock:^{
        rc = PerlCommandRun(cxbottle.fileSystemRepresentation, av, kEnv, -1, w, w);
    }];
    t.stackSize = 16 << 20;
    [t start];
    while (!t.isFinished) [NSThread sleepForTimeInterval:0.01];
    close(o[1]);
    NSFileHandle *h = [[NSFileHandle alloc] initWithFileDescriptor:o[0] closeOnDealloc:YES];
    NSString *text = [[NSString alloc] initWithData:[h readDataToEndOfFile] encoding:NSUTF8StringEncoding];
    XCTAssertEqual(rc, 0, @"%@", text);
    XCTAssertTrue([text containsString:@"--bottle"], @"%@", text);
}

@end
