#!/usr/bin/env perl
# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (c) 2017-2021 Cyril Hrubis <chrubis@suse.cz>
#
# Linux Test Project test runner

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
