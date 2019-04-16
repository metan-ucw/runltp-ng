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

package install_pkg;

use strict;
use warnings;

sub foo_to_pkg
{
	my ($self, $foo, $distro) = @_;
	my %pkg_map = (
		'git' => 'git',
		'unzip' => 'unzip',
		'autoconf' => 'autoconf',
		'automake' => 'automake',
		'make' => 'make',
		'gcc' => 'gcc',

		'libaio-devel-debian' => 'libaio-dev',
		'libacl-devel-debian' => 'libacl1-dev',
		'libattr-devel-debian' => 'libattr1-dev',
		'libcap-devel-debian' => 'libcap-dev',
		'libnuma-devel-debian' => 'libnuma-dev',

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

	if (backend::run_cmd($self, 'grep -q debian /etc/os-release') == 0) {
		return "debian";
	} elsif (backend::run_cmd($self, 'grep -q opensuse /etc/os-release') == 0) {
		return "suse";
	}

	print("Unknown distribution!\n");
	return undef;
}

sub install_pkg
{
	my ($self, $distro, $foo) = @_;

	my $pkg = foo_to_pkg($self, $foo, $distro);

	if ($distro eq "debian") {
		return 1 if (backend::run_cmd($self, "apt-get install -y $pkg"));
		return 0;
	}

	if ($distro eq "suse") {
		return 1 if (backend::run_cmd($self, "zypper --non-interactive in $pkg"));
		return 0;
	}
}

sub update_pkg_db
{
	my ($self, $distro) = @_;

	if ($distro eq "debian") {
		return 1 if backend::run_cmd($self, "apt-get update");
		return 0;
	}
}

sub install_ltp_pkgs
{
	my ($self) = @_;
	my $distro = detect_distro($self);

	return unless defined($distro);

	update_pkg_db($self, $distro);

	# Attempt to install required packages
	my @required_pkgs = ('make', 'autoconf', 'automake', 'gcc');

	install_pkg($self, $distro, $_) foreach (@required_pkgs);

	# We need at least one
	install_pkg($self, $distro, "git");
	install_pkg($self, $distro, "unzip");

	# Attempt to install devel libraries
	my @devel_libs = (
		'libaio-devel',
		'libacl-devel',
		'libattr-devel',
		'libcap-devel',
		'libnuma-devel');

	install_pkg($self, $distro, $_) foreach (@devel_libs);
}

1;
