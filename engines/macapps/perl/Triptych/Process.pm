# SPDX-License-Identifier: GPL-3.0-or-later
# Loaded first (-MTriptych::Process) by app/MacAppsKit/PerlCommand.c in every Perl interpreter Triptych runs.
# Perl runs inside the app, so a script's child processes must never be real: system, exec, qx/readpipe, pipe
# opens and fork are overridden here, and every command starts through MacProcessShim (_spawn) as a virtual
# child that CORE::waitpid reaps. libperl's own fork/exec are refused in C (PerlGuard.c), so nothing that
# slips past these overrides can fork or replace the app. Shell command strings are run by a small shell
# (words, quotes, $VAR, VAR=value prefixes, exec, redirections and pipelines); anything else is reported.
package Triptych::Process;
use strict;
use warnings;

our $VERSION = '1.0';
our %Pipes;      # refaddr of a pipe handle's IO -> [pids] reaped by close
our $Debug = $ENV{TRIPTYCH_PERL_DEBUG};

# The command's standard FDs become STDIN/STDOUT/STDERR. Each is a dup the interpreter owns; the app's own
# 0/1/2 are never reopened or closed (Perl leaves the old std handles' FDs alone when their globs change).
BEGIN {
    my @fds = _std_fds();
    my @modes = ('<&', '>&', '>&');
    my @names = qw(STDIN STDOUT STDERR);
    for my $i (0 .. 2) {
        next if $fds[$i] < 0;
        CORE::open(my $h, $modes[$i], $fds[$i]) or next;
        no strict 'refs';
        *{"main::$names[$i]"} = *{$h}{IO};
    }
    select(STDOUT);
}

sub _debug { print STDERR "Triptych::Process: @_\n" if $Debug }

sub _fileno_or_closed { my $n = fileno($_[0]); defined $n ? $n : -1 }
sub _std3 { (_fileno_or_closed(\*main::STDIN), _fileno_or_closed(\*main::STDOUT), _fileno_or_closed(\*main::STDERR)) }

sub _flush {
    for my $h (\*main::STDOUT, \*main::STDERR) {
        next unless defined fileno($h);
        my $old = select($h);
        my $af = $|;
        $| = 1;
        $| = $af;
        select($old);
    }
}

# A program name without a slash is looked up on $PATH; the shim resolves what's left (its built-ins and
# CrossOver's own helpers).
sub _resolve {
    my ($name) = @_;
    return $name if $name =~ m{/};
    for my $dir (split /:/, ($ENV{PATH} // '')) {
        next unless length $dir;
        my $p = "$dir/$name";
        return $p if -f $p && -x _;
    }
    return $name;
}

# Starts argv with the given standard FDs. Returns the virtual pid, or undef with $! set.
sub _launch_argv {
    my ($argv, $fds) = @_;
    return undef unless @$argv;
    my $path = _resolve($argv->[0]);
    _debug("spawn $path @$argv[1..$#$argv]");
    return _spawn($path, [@$argv], @$fds);
}

# MARK: - Shell commands

# Splits a command into tokens: words (with their quoting removed and $VAR expanded) and operators.
# Returns undef for syntax the small shell does not run.
sub _shell_tokens {
    my ($cmd) = @_;
    my @tok;
    my $s = $cmd;
    while (1) {
        $s =~ s/^[ \t\n]+//;
        last if $s eq '';
        if ($s =~ s/^(\d?>>|\d?>&\d|&>|\d?>|\d?<|\|\||&&|\||;|&)//) {
            push @tok, { op => $1 };
            next;
        }
        my $word = '';
        my $glob = 0;
        while ($s ne '' && $s !~ /^[ \t\n|;&<>]/) {
            if ($s =~ s/^'([^']*)'//) { $word .= $1; next }
            if ($s =~ s/^"((?:[^"\\]|\\.)*)"//) {
                my $q = $1;
                return undef if $q =~ /`|\$\(/;
                $q =~ s/\\([\\"\$`])/$1/g;
                $word .= _expand($q);
                next;
            }
            if ($s =~ s/^\\(.)//s) { $word .= $1; next }
            return undef if $s =~ /^(`|\$\(|\(|\))/;
            if ($s =~ s/^(\$(?:\{\w+\}|\w+))//) { $word .= _expand($1); next }
            $s =~ s/^(.)//s;
            $glob = 1 if $1 =~ /[*?\[]/;
            $word .= $1;
        }
        my @words = $glob ? CORE::glob($word) : ();
        push @tok, map { { word => $_ } } (@words ? @words : ($word));
    }
    return \@tok;
}

sub _expand {
    my ($s) = @_;
    $s =~ s/\$\{(\w+)\}|\$(\w+)/my $v = $ENV{defined $1 ? $1 : $2}; defined $v ? $v : ''/ge;
    return $s;
}

# Parses tokens into a pipeline: [{argv => [...], env => {...}, redirs => [[fd, mode, target], ...]}, ...].
sub _parse_pipeline {
    my ($tok) = @_;
    my @stages = ({ argv => [], env => {}, redirs => [] });
    for (my $i = 0; $i < @$tok; $i++) {
        my $t = $tok->[$i];
        my $st = $stages[-1];
        if (exists $t->{word}) {
            my $w = $t->{word};
            if (!@{ $st->{argv} } && $w =~ /^([A-Za-z_]\w*)=(.*)$/s) { $st->{env}{$1} = $2; next }
            next if !@{ $st->{argv} } && $w eq 'exec';
            push @{ $st->{argv} }, $w;
            next;
        }
        my $op = $t->{op};
        if ($op eq '|') {
            return undef unless @{ $st->{argv} };
            push @stages, { argv => [], env => {}, redirs => [] };
        } elsif ($op =~ /^(\d?)>&(\d)$/) {
            push @{ $st->{redirs} }, [length $1 ? $1 : 1, 'dup', $2];
        } elsif ($op =~ /^(&>|\d?>>|\d?>|\d?<)$/) {
            my $next = $tok->[++$i];
            return undef unless $next && exists $next->{word};
            if ($op eq '&>') {
                push @{ $st->{redirs} }, [1, '>', $next->{word}], [2, 'dup', 1];
                next;
            }
            my ($fd, $mode) = $op =~ /^(\d?)(.*)$/;
            $fd = $mode eq '<' ? 0 : 1 unless length $fd;
            push @{ $st->{redirs} }, [$fd, $mode, $next->{word}];
        } else {
            return undef;    # ; && || & run lists and background jobs
        }
    }
    return undef unless @{ $stages[-1]{argv} };
    return \@stages;
}

# Runs a shell command string with standard FDs $fds. Returns the pids (the last stage's last), or ().
sub _launch_shell {
    my ($cmd, $fds) = @_;
    my $tok = _shell_tokens($cmd);
    my $stages = $tok && _parse_pipeline($tok);
    unless ($stages) {
        print STDERR "Triptych::Process: unsupported shell command: $cmd\n";
        $! = 38;    # ENOSYS
        return ();
    }
    my @pids;
    my @keep;
    my $in = $fds->[0];
    for my $n (0 .. $#$stages) {
        my $st = $stages->[$n];
        my @std = ($in, $fds->[1], $fds->[2]);
        my $pr;
        if ($n < $#$stages) {
            pipe($pr, my $pw) or return ();
            push @keep, $pr, $pw;
            $std[1] = fileno($pw);
        }
        for my $r (@{ $st->{redirs} }) {
            my ($fd, $mode, $target) = @$r;
            next if $fd > 2;
            if ($mode eq 'dup') { $std[$fd] = $std[$target] if $target <= 2; next }
            CORE::open(my $f, $mode, $target) or do {
                print STDERR "$target: $!\n";
                return ();
            };
            push @keep, $f;
            $std[$fd] = fileno($f);
        }
        local @ENV{ keys %{ $st->{env} } } = values %{ $st->{env} };
        my $pid = _launch_argv($st->{argv}, \@std);
        return () unless defined $pid;
        push @pids, $pid;
        $in = fileno($pr) if $pr;
    }
    CORE::close($_) for @keep;
    return @pids;
}

sub _launch {
    my ($args, $fds) = @_;
    return @$args == 1 ? _launch_shell($args->[0], $fds) : do {
        my $pid = _launch_argv($args, $fds);
        defined $pid ? ($pid) : ();
    };
}

# Waits for every pid; $? ends as the last one's status, as a shell pipeline's would.
sub _reap {
    my @pids = @_;
    my $status = 0;
    for my $pid (@pids) {
        CORE::waitpid($pid, 0);
        $status = $?;
    }
    $? = $status;
    return $status;
}

# MARK: - Overrides

sub system {
    _flush();
    my @pids = _launch([@_], [_std3()]);
    unless (@pids) { $? = -1; return -1 }
    return _reap(@pids);
}

sub exec {
    _flush();
    my @pids = _launch([@_], [_std3()]);
    return 0 unless @pids;
    my $st = _reap(@pids);
    _exec_exit(($st & 127) ? 128 + ($st & 127) : $st >> 8);
}

sub readpipe {
    my $cmd = @_ ? $_[0] : $_;
    _flush();
    pipe(my $r, my $w) or return;
    my @std = _std3();
    my @pids = _launch_shell($cmd, [$std[0], fileno($w), $std[2]]);
    CORE::close($w);
    unless (@pids) {
        CORE::close($r);
        $? = -1;
        return wantarray ? () : undef;
    }
    my (@lines, $all);
    if (wantarray) { @lines = <$r> }
    else { local $/; $all = <$r>; $all = '' unless defined $all }
    CORE::close($r);
    _reap(@pids);
    return wantarray ? @lines : $all;
}

# There is no second process to fork into. Callers see fork fail (CXUtils::cxwait then skips its dialog).
sub fork {
    $! = 38;    # ENOSYS
    return undef;
}

sub _handle {
    my ($pkg) = @_;
    return $_[1] if ref $_[1];
    return \*{ $_[1] } if ref \$_[1] eq 'GLOB';
    require Symbol;
    return Symbol::qualify_to_ref($_[1], $pkg);
}

sub _io_key { my $io = *{ $_[0] }{IO}; $io ? 0 + $io : 0 }

sub _open_pipe {
    my ($fh, $dir, @cmd) = @_;
    pipe(my $r, my $w) or return undef;
    my @std = _std3();
    my @fds = $dir eq 'r' ? ($std[0], fileno($w), $std[2]) : (fileno($r), $std[1], $std[2]);
    _flush();
    my @pids = _launch(\@cmd, \@fds);
    my $mine = $dir eq 'r' ? $r : $w;
    CORE::close($dir eq 'r' ? $w : $r);
    unless (@pids) { CORE::close($mine); return undef }
    my $ok = CORE::open($fh, $dir eq 'r' ? '<&' : '>&', $mine);
    CORE::close($mine);
    unless ($ok) { _reap(@pids); return undef }
    $Pipes{ _io_key($fh) } = [@pids];
    return $pids[-1];
}

sub open (*;$@) {
    $_[0] = do { require Symbol; Symbol::gensym() } unless defined $_[0];
    my $fh = _handle(scalar caller, $_[0]);
    if (@_ == 2 && !ref $_[1]) {
        my $spec = $_[1];
        if ($spec =~ /^\s*\|(.*)$/s) {
            my $c = $1; $c =~ s/^\s+|\s+$//g;
            return $c eq '-' ? &fork() : _open_pipe($fh, 'w', $c);
        }
        if ($spec =~ /^(.*)\|\s*$/s) {
            my $c = $1; $c =~ s/^\s+|\s+$//g;
            return $c eq '-' ? &fork() : _open_pipe($fh, 'r', $c);
        }
        return CORE::open($fh, $spec);
    }
    if (@_ >= 3 && !ref $_[1] && $_[1] =~ /^\s*(-\||\|-)\s*$/) {
        my $dir = $1 eq '-|' ? 'r' : 'w';
        return &fork() if @_ == 3 && $_[2] eq '-';
        return _open_pipe($fh, $dir, @_[2 .. $#_]);
    }
    return CORE::open($fh) if @_ == 1;
    return CORE::open($fh, $_[1], $_[2]) if @_ == 3;
    return CORE::open($fh, $_[1], @_[2 .. $#_]);
}

sub close (;*) {
    my $fh = @_ ? _handle(scalar caller, $_[0]) : select();
    $fh = _handle('main', $fh) unless ref $fh;
    my $pids = delete $Pipes{ _io_key($fh) };
    my $ok = CORE::close($fh);
    if ($pids) {
        _reap(@$pids);
        $ok = 0 if $?;
    }
    return $ok;
}

BEGIN {
    no warnings 'once';
    *CORE::GLOBAL::system = \&system;
    *CORE::GLOBAL::exec = \&exec;
    *CORE::GLOBAL::readpipe = \&readpipe;
    *CORE::GLOBAL::fork = \&fork;
    *CORE::GLOBAL::open = \&open;
    *CORE::GLOBAL::close = \&close;
}

1;
