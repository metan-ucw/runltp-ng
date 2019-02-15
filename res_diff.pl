#!/usr/bin/perl
#
# Copyright (c) 2017-2019 Cyril Hrubis <chrubis@suse.cz>
#
# Compares two json formatted result files
#

use strict;
use warnings;

use JSON;

use Data::Dumper;

sub load_json
{
	my ($fname) = @_;
	local $/;

	open(my $fh, '<', $fname) or die("Can't open $fname $!");

	return <$fh>;
}

sub json_to_hash
{
	my ($json) = @_;
	my $results = $json->{'tests'}->{'results'};
	my %tid_hash;

	foreach my $test (@$results) {
		$tid_hash{$test->{'tid'}} = $test;
	}

	return \%tid_hash;
}

my @res_str = ('passed', 'failed', 'skipped', 'broken', 'warnings');

sub print_diff
{
	my ($res_a, $res_b) = @_;

	print("\n-------------------------------\n");
	print("$res_a->{'tid'}\n");

	foreach my $key (@res_str) {
		print("$key: $res_a->{$key} -> $res_b->{$key}\n") if ($res_a->{$key} != $res_b->{$key});
	}

	my $mlen = 0;
	foreach my $line (@{$res_a->{'log'}}) {
		$mlen = length($line) if length($line) > $mlen;
	}

	print("\n");

	for (my $i = 0; $i < @{$res_a->{'log'}}; $i++) {
		my $line_a = $res_a->{'log'}->[$i];
		my $line_b = $res_b->{'log'}->[$i];

		print("$line_a");

		if (not $line_b) {
			print("\n");
			next;
		}

		for (my $j = length($line_a); $j < $mlen; $j++) {
			print(" ");
		}
		print(" | ");
		print("$line_b\n");
	}

	for (my $i = @{$res_a->{'log'}}; $i < @{$res_b->{'log'}}; $i++) {
		my $line_b = $res_b->{'log'}->[$i];
		for (my $j = 0; $j < $mlen; $j++) {
			print(" ");
		}
		print(" | ");
		print("$line_b\n");
	}
}

sub check_diff
{
	my ($res_a, $res_b) = @_;

	if ($res_a->{'passed'} != $res_b->{'passed'} or
	    $res_a->{'failed'} != $res_b->{'failed'} or
	    $res_a->{'skipped'} != $res_b->{'skipped'} or
	    $res_a->{'broken'} != $res_b->{'broken'} or
	    $res_a->{'warnings'} != $res_b->{'warnings'}) {
		print_diff($res_a, $res_b);
	}
}

sub print_res
{
	my ($res) = @_;

	print("$res->{'tid'}\n");

	foreach my $key (@res_str) {
		print("$key: $res->{$key}\t");
	}

	print("\n");
}

sub compare_res_hashes
{
	my ($res_hash_a, $res_hash_b) = @_;
	my @removed;
	my @added;
	my @compare;

	foreach my $key (keys %$res_hash_a) {
		if (exists($res_hash_b->{$key})) {
			push(@compare, $key);
		} else {
			push(@removed, $key);
		}
	}

	foreach my $key (keys %$res_hash_b) {
		push(@added, $key) if not exists($res_hash_a->{$key});
	}

	print("==== Newly added tests ====\n");

	foreach my $key (@added) {
		print_res($res_hash_b->{$key});
	}

	print("\n");

	print("==== Removed tests ====\n");

	foreach my $key (@removed) {
		print("$key\n");
	}

	print("\n");

	printf("==== Result difference ====\n");

	foreach my $key (@compare) {
		check_diff($res_hash_a->{$key}, $res_hash_b->{$key});
	}
}

my $res_hash_a = json_to_hash(decode_json(load_json($ARGV[0])));
my $res_hash_b = json_to_hash(decode_json(load_json($ARGV[1])));

compare_res_hashes($res_hash_a, $res_hash_b);
