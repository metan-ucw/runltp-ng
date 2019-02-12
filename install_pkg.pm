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
	);

	my $pkg = $pkg_map{"$foo-$distro"};
	return $pkg if defined $pkg;

	return $pkg_map{"$foo"};
}

sub install_pkg
{
	my ($self, $foo) = @_;
	my $distro;

	if (backend::check_cmd($self, 'apt-get > /dev/null 2>&1')) {
		$distro = "debian"
	} else {
		print("Unknown distribution!\n");
		return 1;
	}

	my $pkg = foo_to_pkg($self, $foo, $distro);

	if ($distro eq "debian") {
		return 1 if (backend::run_cmd($self, "apt-get install -y $pkg"));
		return 0;
	}
}

sub install_ltp_pkgs
{
	my ($self) = @_;

	# Attempt to install required packages
	install_pkg($self, "git");
	install_pkg($self, "unzip");
	install_pkg($self, "make");
	install_pkg($self, "autoconf");
	install_pkg($self, "automake");
	install_pkg($self, "gcc");

	# Attempt to install devel libraries
	install_pkg($self, 'libaio-devel');
	install_pkg($self, 'libacl-devel');
	install_pkg($self, 'libattr-devel');
	install_pkg($self, 'libcap-devel');
	install_pkg($self, 'libnuma-devel');
}

1;
