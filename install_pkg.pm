#!/usr/bin/env perl
# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (c) 2017-2021 Cyril Hrubis <chrubis@suse.cz>
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
		'btrfsprogs-debian' => 'btrfs-progs',
		'btrfsprogs-fedora' => 'btrfs-progs',

		# FS quota tools
		'quota' => 'quota',

		# NFS tools
		'nfs-utils' => 'nfs-utils',
		'nfs-utils-debian' => 'nfs-kernel-server',

		# kernel devel
		'kernel-devel' => 'kernel-devel',
		'kernel-devel-debian' => 'linux-headers-`uname -r`',

		# devel libs
		'libaio-devel-alpine' => 'libaio-devel',
		'libacl-devel-alpine' => 'libacl-devel',
		'libattr-devel-alpine' => 'libattr-devel',
		'libcap-devel-alpine' => 'libcap-devel',
		'libnuma-devel-alpine' => 'numactl-devel',

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

		'libaio-devel-suse' => 'libaio-devel',
		'libacl-devel-suse' => 'libacl-devel',
		'libattr-devel-suse' => 'libattr-devel',
		'libcap-devel-suse' => 'libcap-devel',
		'libnuma-devel-suse' => 'libnuma-devel',
	);

	my $pkg = $pkg_map{"$foo-$distro"};
	return $pkg if defined $pkg;

	return $pkg_map{"$foo"};
}

sub detect_distro
{
	my ($self) = @_;

	for my $distro (qw(alpine debian fedora suse)) {
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
		return "$pkg_name:i386";
	}

	return "$pkg_name-32bit" if ($distro eq "suse");

	return;
}

sub setup_m32
{
	my ($distro) = @_;

	if ($distro eq "debian") {
		return ("dpkg --add-architecture i386", "apt-get update");
	}
	return;
}

sub install_pkg
{
	my ($distro, $foos, $m32) = @_;

	$foos = [$foos] unless (ref($foos) eq 'ARRAY');

	my @pkgs = map { foo_to_pkg($_, $distro) } @{$foos};

	@pkgs = map { pkg_to_m32($distro, $_) } @pkgs if ($m32);

	if ($distro eq 'debian') {
		return 'apt-get install -y ' . join(' ', @pkgs);

	} elsif ($distro eq 'fedora') {
		return 'yum install -y ' . join(' ', @pkgs);

	} elsif ($distro eq 'suse') {
		return 'zypper --non-interactive --ignore-unknown in ' . join(' ', @pkgs);
	}
	return;
}

sub update_pkg_db
{
	my ($distro) = @_;

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

sub install_ltp_pkgs
{
	my ($self, $m32) = @_;
	my $distro = detect_distro($self);

	return unless defined($distro);

	# Attempt to install required packages
	my @required_pkgs = ('make', 'autoconf', 'automake', 'pkg-config', 'gcc', 'bc');

	# We need at least one
	push(@required_pkgs, 'git');
	push(@required_pkgs, 'unzip');

	# Attempt to install devel libraries
	my @devel_libs = (
		'libaio-devel',
		'libacl-devel',
		'libattr-devel',
		'libcap-devel',
		'libnuma-devel');
	push(@required_pkgs, @devel_libs);

	# We need mkfs.foo at runtime
	my @mkfs = (
		'dosfstools',
		'xfsprogs',
		'e2fsprogs',
		'btrfsprogs',
	);
	push(@required_pkgs, @mkfs);

	# FS quota tests needs quota tools
	push(@required_pkgs, ('quota'));

	# NFS tests needs exportfs
	push(@required_pkgs, ('nfs-utils'));

	# Kernel devel so that we can build modules
	push(@required_pkgs, ('kernel-devel'));

	my @cmds = ();
	push(@cmds, update_pkg_db($distro));
	push(@cmds, install_pkg($distro, \@required_pkgs));

	if ($m32) {
		push(@cmds, setup_m32($distro));
		push(@cmds, install_pkg($distro, \@devel_libs, $m32));
		push(@cmds, install_pkg($distro, 'gcc', $m32));
	}

	my @results;
	if (utils::run_cmds_retry($self, \@cmds, results => \@results) != 0) {
		my $last = $results[$#results];
		printf("Failed command: %s\n  output:\n%s\n",
			$last->{cmd}, join("\n  ", @{$last->{log}}));
		return $last->{ret};
	}
	return 0;
}

1;
