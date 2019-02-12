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

use strict;
use warnings;

package log;
require Exporter;
our @ISA = qw(Exporter);
our @EXPORT = qw(msg);

my $verbosity = 0;

sub msg
{
	my $val = shift();
	my $level = 1;
	my $msg;

	if ($val =~ m/^\d+$/) {
		$level = $val;
		$msg = shift();
	} else {
		$msg = $val;
	}

	print($msg) if $level <= $verbosity;
}

sub set_verbosity
{
	($verbosity) = @_;
}

1;
