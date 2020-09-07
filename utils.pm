#!/usr/bin/env perl
#
# Linux Test Project test runner
#
# Copyright (c) 2017-2018 Cyril Hrubis <chrubis@suse.cz>
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 2 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License along
# with this program; if not, write to the Free Software Foundation, Inc.,
# 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.

package utils;

use strict;
use warnings;

use Time::HiRes qw(clock_gettime CLOCK_MONOTONIC);

use log;
use backend;
use install_pkg;

sub format_memsize
{
	my ($size) = @_;

	if ($size >= 1024 * 1024) {
		return sprintf("%.2f GB ($size KB)", $size / (1024 * 1024));
	}

	if ($size >= 1024) {
		return sprintf("%.2f MB ($size KB)", $size / 1024);
	}

	return "$size KB";
}

sub print_sysinfo
{
	my ($sysinfo) = @_;

	print("\nSystem information\n------------------\n\n");

	for (sort(keys %$sysinfo)) {
		printf("%-30s: $sysinfo->{$_}\n", ($_));
	}

	print("\n");
}

sub list_testgroups
{
	my ($self, $ltpdir) = @_;

	if (backend::run_cmd($self, "[ -e $ltpdir ]")) {
		print("openposix\n");
	}

	my ($ret, @log) = backend::run_cmd($self, "ls $ltpdir/runtest/");

	print("$_\n") for (@log);
}

sub collect_sysinfo
{
	my ($self) = @_;
	my %info;
	my @log;

	if (utils::check_cmd_retry($self, 'uname')) {
		@log = utils::run_cmd_retry($self, 'for i in m p r; do printf uname-$i; uname -$i; done');
		for (@log) {
			if (m/uname-m(.*)/) {
				$info{'arch'} = $1;
			}
			if (m/uname-p(.*)/) {
				$info{'cpu'} = $1;
			}
			if (m/uname-r(.*)/) {
				$info{'kernel'} = $1;
			}
		}
	}

	@log = utils::run_cmd_retry($self, 'cat /proc/meminfo');
	for (@log) {
		if (m/SwapTotal:\s+(\d+)\s+kB/) {
			$info{'swap'} = format_memsize($1);
		}

		if (m/MemTotal:\s+(\d+)\s+kB/) {
			$info{'RAM'} = format_memsize($1);
		}
	}

	@log = utils::run_cmd_retry($self, 'cat /etc/os-release');
	for (@log) {
		if (m/^ID=\"?([^\"\n]*)\"?/) {
			$info{'distribution'} = $1;
		}
		if (m/^VERSION_ID=\"?([^\"\n]*)\"?/) {
			$info{'distribution_version'} = $1;
		}
	}

	return \%info;
}

sub install_git_cmds
{
	my ($revision, $uri) = @_;
	my @cmds;

	push(@cmds, "git clone $uri ltp");
	push(@cmds, "git -C ltp checkout $revision") if ($revision);

	return @cmds;
}

sub install_zip_cmds
{
	my ($revision, $uri) = @_;
	my @cmds;

	$revision //= 'HEAD';
	$uri =~ s/.git$//;

	push(@cmds, "wget $uri/archive/$revision.zip -O ltp.zip");
	push(@cmds, "unzip ltp.zip");
	push(@cmds, "mv ltp-* ltp");

	return @cmds;
}

sub install_ltp
{
	my ($self, $ltpdir, $revision, $m32, $runtest, $uri) = @_;
	my $ret;

	$uri //= 'http://github.com/linux-test-project/ltp.git';

	my @cmds = ();

	push(@cmds, "if [ -e $ltpdir ]; then rm -rf $ltpdir; fi");
	push(@cmds, 'cd; if [ -e ltp/ ]; then rm -r ltp/; fi');

	if (check_cmd_retry($self, 'git')) {
		push(@cmds, install_git_cmds($revision, $uri));
	} else {
		push(@cmds, install_zip_cmds($revision, $uri));
	}

	push(@cmds, 'cd ltp');
	push(@cmds, 'make autotools');
	if (defined($runtest) && $runtest =~ "openposix") {
		push(@cmds, "./configure --prefix=$ltpdir --with-open-posix-testsuite");
	} elsif (defined($runtest) && $runtest =~ "syzkaller") {
		push(@cmds, "./configure --prefix=$ltpdir --with-syzkaller-repros");
	} else {
		push(@cmds, "./configure --prefix=$ltpdir");
	}
	push(@cmds, 'make -j$(getconf _NPROCESSORS_ONLN)');
	push(@cmds, 'make install');

	my @results;
	if (run_cmds_retry($self, \@cmds, results => \@results) != 0) {
		my $last = $results[$#results];
		printf("Failed command: %s\n  output:\n%s\n",
			$last->{cmd}, join("\n  ", @{$last->{log}}));
		return $last->{ret};
	}

	return 0;
}

sub parse_retval
{
	my ($result, $stat, $ret) = @_;

	# Kernel crashed, machine stopped responding
	if (!defined($ret)) {
		$result->{'broken'}++;
		$stat->{'broken'}++;
		return;
	}

	if ($ret == 0) {
		$result->{'passed'}++;
		$stat->{'passed'}++;
		return;
	}

	# Command-not-found
	if ($ret == 127) {
		$result->{'broken'}++;
		$stat->{'broken'}++;
		return;
	}

	if ($ret & 1) {
		$result->{'failed'}++;
		$stat->{'failed'}++;
	}

	if ($ret & 2) {
		$result->{'broken'}++;
		$stat->{'broken'}++;
	}

	if ($ret & 4) {
		$result->{'warnings'}++;
		$stat->{'warnings'}++;
	}

	if ($ret & 32) {
		$result->{'skipped'}++;
		$stat->{'skipped'}++;
	}
}

sub parse_retval_openposix
{
	my ($result, $stat, $ret) = @_;

	# Kernel crashed, machine stopped responding
	if (!defined($ret)) {
		$result->{'broken'}++;
		$stat->{'broken'}++;
		return;
	}

	if ($ret == 0) {
		$result->{'passed'}++;
		$stat->{'passed'}++;
		return;
	}

	# Command-not-found
	if ($ret == 127) {
		$result->{'broken'}++;
		$stat->{'broken'}++;
		return;
	}

	if ($ret == 1 || $ret == 2) {
		$result->{'failed'}++;
		$stat->{'failed'}++;
	} elsif ($ret == 4 || $ret == 5) {
		$result->{'skipped'}++;
		$stat->{'skipped'}++;
	} else {
		$result->{'broken'}++;
		$stat->{'broken'}++;
	}
}

sub check_tainted
{
	my ($self) = @_;
	my $res;

	# We do not use run_cmd_retry() here, cause we will track that state.
	my ($ret, @log) = backend::run_cmd($self, "printf tainted-; cat /proc/sys/kernel/tainted", 600);

	return undef if ($ret);

	for (@log) {
		if (m/tainted-(\d+)/) {
			$res = $1;
		}
	}

	return $res;
}

sub setup_ltp_run($$$)
{
	my ($self, $ltpdir, $timeout) = @_;

	my $ret = utils::run_cmds_retry($self,
		[
			"cd $ltpdir",
			'export LTPROOT=$PWD',
			'export TMPDIR=/tmp',
			'export PATH=$LTPROOT/testcases/bin:$PATH',
			'export LTP_TIMEOUT_MUL=' . ($timeout * 0.9) / 300,
			'cd $LTPROOT/testcases/bin',
		]);

	return $ret;
}

sub reboot($$$)
{
	my ($self, $reason, $timeout) = @_;

	print("$reason, attempting to reboot...\n");

	return backend::reboot($self, $timeout);
}


=head2 run_cmds_retry

    run_cmds_retry($self, <ARRAY of commands>, [timeout => <seconds>, retries => <number>, results => <array_ref>]);

Run commands sequentially. If command has failed because of timeout, reboot the SUT.
After reboot the sequence is restarted from the first  command.
The sequence stops on the first command which exits with non zero.

The function returns a array of hash refs or the exitcode of the last command in scalar context:
  (
	{ cmd=> <the command>, ret => <returnvalue>, log => <array ref of output lines> },
	{ cmd=>'echo "foo"', ret => 0, log => ('foo') }
	...
  )
=cut
sub run_cmds_retry($$%)
{
	my ($self, $cmd, %args) = @_;
	my @ret;
	$args{retries} //= 3;
	$args{timeout} //= 3600;

	for my $cnt (1 .. $args{retries}) {
		@ret = backend::run_cmds($self, $cmd, %args);
		last if (defined($ret[$#ret]->{ret}));
		if ($cnt == $args{retries}) {
			die("Unable to recover SUT");
		}
		my $reboot_msg = "Timeout on command: " . $ret[$#ret]->{cmd};
		my $reboot_ret = reboot($self, $reboot_msg, $args{timeout});
		if ($reboot_ret != 0) {
			push(@ret, {cmd => 'reboot-sut', ret => $reboot_ret, log => $reboot_msg});
			last;
		}
	}
	if ($args{results}) {
		push(@{$args{results}}, @ret);
	}
	wantarray ? @ret : $ret[$#ret]->{ret};
}

sub run_cmd_retry($$%)
{
	my ($self, $cmd, %args) = @_;
	my ($ret) = run_cmds_retry($self, [$cmd], %args);
	wantarray ? ($ret->{ret}, @{$ret->{log}}) : $ret->{ret};
}

sub check_cmd_retry
{
	my ($self, $cmd, %args) = @_;
	my $ret = run_cmd_retry($self, $cmd, %args);
	return $ret != 127;
}

sub load_tests
{
	my ($self, $runtest) = @_;

	if ($runtest =~ "openposix") {
		my ($ret, @flist) =
			backend::run_cmd($self, "find \$LTPROOT -name '*.run-test' > /tmp/openposix");

		return backend::read_file($self, '/tmp/openposix');
	}

	return backend::read_file($self, "\$LTPROOT/runtest/$runtest");
}

sub parse_test
{
	my ($runtest, $line) = @_;

	if ($runtest =~ "openposix") {
		$line =~ /([-\w]+).run-test/;
		return ($1, $line);
	}

	return split(/\s/, $line, 2);
}

sub run_ltp
{
	my ($self, $ltpdir, $runtest, $timeout, $include, $exclude) = @_;
	my @results;
	my %reshash;

	my %empty_result = (
		'runtime' => 0,
		'runs' => 0,
		'passed' => 0,
		'failed' => 0,
		'broken' => 0,
		'skipped' => 0,
		'warnings' => 0,
	);

	my %stats = (
		'passed' => 0,
		'failed' => 0,
		'broken' => 0,
		'skipped' => 0,
		'warnings' => 0,
	);

	setup_ltp_run($self, $ltpdir, $timeout);

	my @tests = load_tests($self, $runtest);
	my $start_tainted = check_tainted($self);
	my $start_time = clock_gettime(CLOCK_MONOTONIC);

	for (@tests) {
		next if m/^\s*($|#)/;
		chomp;

		my ($tid, $c) = parse_test($runtest, $_);
		next unless ($tid =~ $include);
		next if ($exclude && $tid =~ $exclude);

		print("Executing $tid\n");
		my $test_start_time = clock_gettime(CLOCK_MONOTONIC);
		my ($ret, @log) = backend::run_cmd($self, "$c", $timeout);
		my $test_end_time = clock_gettime(CLOCK_MONOTONIC);

		my $result = {};

		if (defined($reshash{$tid})) {
			$result = $reshash{$tid};
		} else {
			$result = {%empty_result};
			$result->{'tid'} = $tid;
			$result->{'log'} = [];
		}

		push(@{$result->{'log'}}, @log);
		$result->{'runtime'} += $test_end_time - $test_start_time;
		$result->{'runs'} += 1;

		if ($runtest =~ "openposix") {
			parse_retval_openposix($result, \%stats, $ret);
		} else {
			parse_retval($result, \%stats, $ret);
		}

		if (!defined($reshash{$tid})) {
			push(@results, $result);
			$reshash{$tid} = $result;
		}

		my $err_msg = 'Machine stopped respoding';
		if (defined($ret)) {
			next if ($ret == 0);

			my $tainted = check_tainted($self);
			next if ($tainted == $start_tainted);
			$err_msg = 'Kernel was tained' if (defined($tainted));
		}

		last if (reboot($self, $err_msg, $timeout) != 0);
		last if (setup_ltp_run($self, $ltpdir, $timeout) != 0);
	}

	my $stop_time = clock_gettime(CLOCK_MONOTONIC);

	$stats{'runtime'} = $stop_time - $start_time;

	return (\%stats, \@results);
}

sub tstctl
{
	my $args = join(' ', @_);
	my $output = `./tstctl $args`;
	my $err = $? == -1 ? $! : $? & 127 ? $? : $? >> 8;

	die "Exec Failed: `$args` -> $err" if $err;

	return $output;
}

sub run_ltp_executor
{
	my ($self, $ltpdir, $runtest, $timeout, $include, $exclude) = @_;

	# The local log file for 'cat' will be called $runtest. This
	# allows us to transfer the contents of the runtes file to the
	# host
	tstctl('init');
	tstctl('add-test', $runtest, 'cat', "$ltpdir/runtest/$runtest");
	backend::drive_executor($self);

	tstctl('init');
	tstctl('add-tests', $runtest);

	while (tstctl('status') =~ /TODO/) {
		backend::drive_executor($self);
        last if (tstctl('status') =~ /DONE/);
		reboot($self, "Driver stopped, but more tests todo", $timeout);
	}
}

1;
