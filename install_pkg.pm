#!/usr/bin/env perl
# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (c) 2017-2021 Cyril Hrubis <chrubis@suse.cz>
# Copyright (c) 2021 Petr Vorel <pvorel@suse.cz>
#
# Linux Test Project test runner

package install_pkg;

use strict;
use warnings;

sub foo_to_pkg
{
	my ($foo, $distro) = @_;

	my %pkg_map = (
		'git' => 'git',
		'unzip' => 'unzip',
		'autoconf' => 'autoconf',
		'automake' => 'automake',
		'pkg-config' => 'pkg-config',
		'make' => 'make',
		'gcc' => 'gcc',
		'bc' => 'bc',

		# mkfs.foo
		'dosfstools' => 'dosfstools',
		'xfsprogs' => 'xfsprogs',
		'e2fsprogs' => 'e2fsprogs',
		'btrfsprogs' => 'btrfsprogs',
		'btrfsprogs-alpine' => 'btrfs-progs',
		'btrfsprogs-debian' => 'btrfs-progs',
		'btrfsprogs-fedora' => 'btrfs-progs',

		# FS quota tools
		'quota' => 'quota',
		'quota-alpine' => 'quota-tools',

		# NFS tools
		'nfs-utils' => 'nfs-utils',
		'nfs-utils-debian' => 'nfs-kernel-server',

		# kernel devel
		'kernel-devel' => 'kernel-devel',
		'kernel-devel-alpine' => 'linux-headers',
		'kernel-devel-debian' =>
			'linux-headers-`dpkg --print-architecture`',
		'kernel-devel-ubuntu' =>
			'linux-headers-`uname -r`',

		# devel libs
		'libacl-devel-alpine' => 'acl-dev',
		'libaio-devel-alpine' => 'libaio-dev',
		'libattr-devel-alpine' => 'attr-dev',
		'libcap-devel-alpine' => 'libcap-dev',
		'libnuma-devel-alpine' => 'numactl-dev',
		'pkg-config-alpine' => 'pkgconf',

		'libaio-devel-debian' => 'libaio-dev',
		'libacl-devel-debian' => 'libacl1-dev',
		'libattr-devel-debian' => 'libattr1-dev',
		'libcap-devel-debian' => 'libcap-dev',
		'libnuma-devel-debian' => 'libnuma-dev',

		'libaio-devel-fedora' => 'libaio-devel',
		'libacl-devel-fedora' => 'libacl-devel',
		'libattr-devel-fedora' => 'libattr-devel',
		'libcap-devel-fedora' => 'libcap-devel',
		'libnuma-devel-fedora' => 'numactl-devel',

		'libaio-devel-opensuse' => 'libaio-devel',
		'libacl-devel-opensuse' => 'libacl-devel',
		'libattr-devel-opensuse' => 'libattr-devel',
		'libcap-devel-opensuse' => 'libcap-devel',
		'libnuma-devel-opensuse' => 'libnuma-devel',
	);

	if ($distro eq 'sles') {
		$distro = 'opensuse';
	}

	if ($distro eq 'ubuntu') {
		$distro = 'debian';
	}

	my $pkg = $pkg_map{"$foo-$distro"};
	return $pkg if defined $pkg;

	return $pkg_map{"$foo"};
}

my @distros = qw(alpine debian fedora opensuse sles ubuntu);

sub detect_distro
{
	my ($self) = @_;

	for my $distro (@distros) {
		if (utils::run_cmd_retry($self, "grep -q $distro /etc/os-release") == 0) {
			return $distro;
		}
	}

	print("Unknown distribution!\n");
	return;
}

sub pkg_to_m32
{
	my ($distro, $pkg_name) = @_;

	if ($distro eq "debian") {
		#TODO: we need architecture detection for now default to i386
		return "gcc-multilib" if ($pkg_name eq "gcc");
		return "$pkg_name:i386";
	}

	return "$pkg_name-32bit" if ($distro eq "suse");

	return;
}

sub setup_m32
{
	my ($distro) = @_;

	if ($distro eq "debian") {
		return ("dpkg --add-architecture i386");
	}
	return;
}

sub map_pkgs
{
	my ($foos, $distro, $m32) = @_;

	$foos = [$foos] unless (ref($foos) eq 'ARRAY');

	my @pkgs = map { foo_to_pkg($_, $distro) } @{$foos};

	@pkgs = map { pkg_to_m32($distro, $_) } @pkgs if ($m32);

	return \@pkgs;
}

sub install_pkg
{
	my ($distro, $pkgs) = @_;

	if ($distro eq "alpine") {
		return 'apk add ' . join(' ', @$pkgs);
	}

	if ($distro eq 'debian') {
		return 'apt-get install -y ' . join(' ', @$pkgs);
	}

	if ($distro eq 'fedora') {
		return 'yum install -y ' . join(' ', @$pkgs);
	}

	if ($distro eq 'suse') {
		return 'zypper --non-interactive --ignore-unknown in ' . join(' ', @$pkgs);
	}
}

sub update_pkg_db
{
	my ($distro) = @_;

	if ($distro eq "alpine") {
		return "apk update";
	}

	if ($distro eq "debian") {
		return "apt-get update";
	}

	if ($distro eq "fedora") {
		return "yum update -y";
	}

	if ($distro eq "suse") {
		return "zypper --non-interactive ref";
	}

	return;
}

sub add_build_pkgs
{
	my ($required_pkgs) = @_;

	# Attempt to install required packages
	my @build_pkgs = ('make',
		'autoconf',
		'automake',
		'pkg-config',
		'gcc');

	push(@$required_pkgs, @build_pkgs);

	# We need at least one to get the sources
	push(@$required_pkgs, 'git');
	push(@$required_pkgs, 'unzip');

	# Kernel devel so that we can build modules
	push(@$required_pkgs, ('kernel-devel'));
}

sub add_runtime_pkgs
{
	my ($required_pkgs) = @_;

	# We need mkfs.foo at runtime
	my @mkfs = (
		'dosfstools',
		'xfsprogs',
		'e2fsprogs',
		'btrfsprogs',
	);
	push(@$required_pkgs, @mkfs);

	# Debian does not install bc by default!
	push(@$required_pkgs, 'bc');

	# FS quota tests needs quota tools
	push(@$required_pkgs, ('quota'));

	# NFS tests needs exportfs
	push(@$required_pkgs, ('nfs-utils'));
}

sub get_runtime_pkgs
{
	my ($pkgs, $distro) = @_;
	my $run_pkgs = [];

	add_runtime_pkgs($run_pkgs);

	$run_pkgs = map_pkgs($run_pkgs, $distro);

	push(@$pkgs, @$run_pkgs);
}

sub add_devel_libs
{
	my ($required_pkgs) = @_;

	# Attempt to install devel libraries
	my @devel_libs = (
		'libaio-devel',
		'libacl-devel',
		'libattr-devel',
		'libcap-devel',
		'libnuma-devel'
	);

	push(@$required_pkgs, @devel_libs);
}

sub get_build_pkgs
{
	my ($pkgs, $distro, $m32) = @_;
	my $foos = [];

	add_build_pkgs($foos);
	add_devel_libs($foos);

	$foos = map_pkgs($foos, $distro);

	push(@$pkgs, @$foos);

	if ($m32) {
		my $pkgs32 = [];
		add_devel_libs($pkgs32);
		push(@$pkgs32, 'gcc');

		$pkgs32 = map_pkgs($pkgs32, $distro, $m32);

		push(@$pkgs, @$pkgs32);
	}

	return $pkgs;
}

sub get_install_cmds
{
	my ($pkgs, $distro, $m32) = @_;
	my @cmds = ();

	push(@cmds, setup_m32($distro)) if $m32;
	push(@cmds, update_pkg_db($distro));

	push(@cmds, install_pkg($distro, $pkgs));

	return \@cmds;
}

sub install_ltp_pkgs
{
	my ($self, $m32) = @_;
	my $distro = detect_distro($self);

	return unless defined($distro);
	my $pkgs = [];

	get_build_pkgs($pkgs, $distro, $m32);
	get_runtime_pkgs($pkgs, $distro);

	my $cmds = get_install_cmds($pkgs, $distro, $m32);

	my @results;
	if (utils::run_cmds_retry($self, $cmds, results => \@results) != 0) {
		my $last = $results[$#results];
		printf("Failed command: %s\n  output:\n%s\n",
			$last->{cmd}, join("\n  ", @{$last->{log}}));
		return $last->{ret};
	}
	return 0;
}

use Getopt::Long;

if (not caller())
{
	my $distro;
	my $m32;
	my $build;
	my $run;
	my $help;
	my $cmd;

	GetOptions(
		"distro=s" => \$distro,
		"m32" => \$m32,
		"build" => \$build,
		"run" => \$run,
		"cmd" => \$cmd,
		"help" => \$help,
	) or die("Error in argument parsing!\n");

	if ($help) {
		print("Usage\n-----\n\n");
		print("install_pkg.pm --distro DISTRO {at least one of: --build, --run} [--cmd] [--m32]\n\n");
		print("install_pkg.pm -h|--help\n\n");
		print("Options\n-------\n\n");
		print("--help   : Print this help\n\n");
		print("--distro : Distribution name: " . join(' ', @distros) . "\n\n");
		print("--m32    : Include 32bit build dependencies\n\n");
		print("--build  : Include build dependencies\n\n");
		print("--run    : Include runtime dependencies\n\n");
		print("--cmd    : Print command line instead of package list\n\n");
		exit 0;
	}

	die("No distribution selected!\n") unless $distro;
	die("Unsupported distribution!\n") unless grep(/^$distro$/i, @distros);
	die("No packages selected!\n") unless $build or $run;

	my $pkgs = [];

	get_build_pkgs($pkgs, $distro, $m32) if $build;
	get_runtime_pkgs($pkgs, $distro) if $run;

	if ($cmd) {
		my $cmds = get_install_cmds($pkgs, $distro, $m32);
		print "$_\n" for (@$cmds);
	} else {
		print(join(' ', @$pkgs) . "\n");
	}
}

1;
