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

package backend;

use strict;
use warnings;

use IPC::Open2;
use POSIX ":sys_wait_h";
use Fcntl;
use Errno;
use IO::Poll qw(POLLIN);

use log;

sub split_line
{
	my ($self) = @_;
	my @lines = split(/\n/, $self->{'buf'}, 2);

	$self->{'buf'} = $lines[1];

	return $lines[0] . "\n";
}

sub has_newline
{
	my ($self) = @_;

	return $self->{'buf'} =~ m/\n/;
}

#
# We cannot read the console pipe line by line since we need to match
# unfinished lines (i.e. without newline) such as "login:" as well. Hence we
# try to split the output by newlines if possible but return partial lines if
# we failed to attempt to read the whole line.
#
sub try_readline
{
	my ($self, $timeout) = @_;

	return split_line($self) if has_newline($self);

	my $poll = IO::Poll->new();
	$poll->mask($self->{'out_fd'} => POLLIN);

	while (1) {
		if ($poll->poll($timeout) == 0) {
			msg("$self->{'name'}: Timeouted!\n");
			return undef;
		}

		my $buf = '';
		my $ret = sysread($self->{'out_fd'}, $buf, 128);
		#print("R: '$buf'\n");
		$self->{'buf'} .= $buf;
		last if !defined($ret) && $!{EAGAIN};
		last if $ret > 0;
		return undef if !defined($ret);
		return undef if $ret == 0;
	}

	return split_line($self) if has_newline($self);

	return $self->{'buf'};
}

#
# Read output until regexp is matched, returns array of log lines on success.
#
sub wait_regexp
{
	my ($self, $regexp, $newline, $timeout) = @_;
	my $out_fd = $self->{'out_fd'};
	my @log;
	my $line;

	msg("Waiting for regexp '$regexp'\n");

	while (1) {
		$line = try_readline($self, $timeout);

		if (!defined($line)) {
			msg("$self->{'name'}: died!\n");
			return @log;
		}

		if ($line =~ /\n/) {
			msg("$self->{'name'}: $line");
			my $l = $line;
			# Strip CR LF
			$l =~ s/(\x0d|\x0a)//g;
			# Strip escape sequencies
			$l =~ s/\x1b\[[0-9;]*[a-zA-Z]//g;
			push(@log, $l);
			my $fh = $self->{'raw_logfile'};
			print($fh "$l\n") if defined($fh);
		}
		#print("N: $self->{'name'}: $line\n") if $verbose;

		next if (defined($newline) && $newline && $line !~ /\n/);

		last if ($line =~ m/$regexp/);
	}

	return @log;
}

sub wait_prompt
{
	my ($self) = @_;

	#TODO!
	#wait_regexp($self, qr/ #\s*$/);
}

sub flush
{
	my ($self) = @_;

	my $line = try_readline($self);
}

sub run_string
{
	my ($self, $string) = @_;
	my $in_fd = $self->{'in_fd'};

	msg("Writing string '$string'\n");

	print($in_fd  "$string\n");
}

my $cmd_seq_cnt = 0;

sub run_cmd
{
	my ($self, $cmd, $timeout) = @_;
	my @log;
	my $ret;

	run_string($self, "$cmd; echo cmd-exit-$cmd_seq_cnt-\$?");
	@log = wait_regexp($self, qr/cmd-exit-$cmd_seq_cnt-\d+/, 1, $timeout);

	my $last = pop(@log);

	if ($last =~ m/cmd-exit-$cmd_seq_cnt-(\d+)/) {
		msg("Cmd exit value $1\n");
		$ret = $1;
	} else {
		push(@log, $last);
		msg("Failed to parse exit value in '$last'\n");
		$ret = undef;
	}

	$cmd_seq_cnt+=1;

	wait_prompt($self);

	wantarray? ($ret, @log) : $ret;
}

sub start
{
	my ($self) = @_;

	$self->{'start'}->($self) if defined($self->{'start'});
}

sub stop
{
	my ($self) = @_;

	close($self->{'raw_logfile'}) if defined($self->{'raw_logfile'});

	$self->{'stop'}->($self) if defined($self->{'stop'});
}

sub serial_relay_force_stop
{
	my ($self) = @_;

	my $port = $self->{'serial_relay_port'};

	msg("Resetting machine backend $self->{'backend_name'} serial relay port $port\n");

	open(my $fh, '<', $port);
	sleep(0.1);
	close($fh);
}

sub force_stop
{
	my ($self) = @_;

	if (defined($self->{'force_stop'})) {
		$self->{'force_stop'}->($self);
	} else {
		print("Backend $self->{'name'} has to be force stopped manually\n");
		print("Please bring the machine into usable state and then press any key\n");
		<STDIN>;
	}
}

sub reboot
{
	my ($self) = @_;

	force_stop($self);
	start($self);
}

sub qemu_start
{
	my ($self) = @_;
	my $cmdline = "qemu-system-$self->{'qemu_system'} $self->{'qemu_params'}";

	msg("Starting qemu with: $cmdline\n");

	my ($qemu_out, $qemu_in);
	my $pid = open2($qemu_out, $qemu_in, $cmdline) or die("Fork failed");

	$self->{'pid'} = $pid;
	$self->{'in_fd'} = $qemu_in;
	$self->{'out_fd'} = $qemu_out;

	msg("Waiting for qemu to boot the machine\n");

	wait_regexp($self, qr/login:/);
	run_string($self, "root");
	wait_regexp($self, qr/[Pp]assword:/);
	run_string($self, "$self->{'root_password'}");
	wait_prompt($self);
	run_string($self, "export PS1=\$ ");
}

sub qemu_stop
{
	my ($self) = @_;

	msg("Stopping qemu pid $self->{'pid'}\n");

	run_string($self, "poweroff");

	my $timeout = 600;

	while ($timeout > 0) {
		return if waitpid($self->{'pid'}, WNOHANG);
		sleep(1);
		$timeout -= 1;
		#flush($self);
	}

	msg("Failed to stop qemu, killing it!\n");

	kill('TERM', $self->{'pid'});
	waitpid($self->{'pid'}, 0);
}

sub print_help
{
	my ($name, $param_desc) = @_;

	print("\nBackend $name parameters:\n\n");

	for (@$param_desc) {
		printf("%-20s: %s\n", ($_->[0], $_->[2]));
	}

	print("\n");
}


sub parse_params
{
	my $backend = shift();
	my $name = shift();
	my $param_desc = shift();

	for (@_) {
		my @params = split('=', $_, 2);
		my $found = 0;

		for my $desc (@$param_desc) {
			if ($params[0] eq $desc->[0]) {
				$backend->{$desc->[1]} = $params[1];
				$found = 1;
				last;
			}
		}

		if (!$found) {
			print_help($name, $param_desc);
			die("Invalid sh parameter '$params[0]'");
		}
	}
}

my $qemu_params = [
	['image', 'qemu_image', 'Path to bootable qemu image'],
	['password', 'root_password', 'Qemu image root password'],
	['opts', 'qemu_opts', 'Additional qemu command line options'],
	['system', 'qemu_system', 'Qemu system such as x86_64'],
];

sub qemu_init
{
	my %backend;
	$backend{'qemu_params'} = "-enable-kvm -display none -serial stdio";
	$backend{'qemu_system'} = 'x86_64';

	parse_params(\%backend, "qemu", $qemu_params, @_);

	die('Qemu image not defined') unless defined($backend{'qemu_image'});
	$backend{'qemu_params'} .= ' -hda ' . $backend{'qemu_image'};

	if (defined($backend{'qemu_opts'})) {
		$backend{'qemu_params'} .= ' ' . $backend{'qemu_opts'};
	}

	$backend{'start'} = \&qemu_start;
	$backend{'stop'} = \&qemu_stop;
	$backend{'force_stop'} = \&qemu_stop;
	$backend{'name'} = 'qemu';
	$backend{'buf'} = '';

	return \%backend;
}

sub ssh_start
{
	my ($self) = @_;
	my $host = $self->{'ssh_host'};
	my $user = $self->{'ssh_user'};
	my $key = $self->{'ssh_key'};

	msg("Waiting for sshd to accept connections\n");
	while (system("echo | nc -w1 $host 22 >/dev/null 2>&1")) {
		sleep(1);
	}

	my $sshcmd = 'ssh ' . ($key ? "-i $key " : " ") . "$user\@$host";
	my $cmdline = "export TERM=dumb; script -f -c '$sshcmd' /dev/null";

	msg("Starting ssh: $cmdline\n");

	my ($ssh_out, $ssh_in);
	my $pid = open2($ssh_out, $ssh_in, $cmdline) or die("Fork failed");

	$self->{'pid'} = $pid;
	$self->{'in_fd'} = $ssh_in;
	$self->{'out_fd'} = $ssh_out;

	my $flags=0;
	fcntl($ssh_out, &F_GETFL, $flags) || die $!;
	$flags |= &O_NONBLOCK;
	fcntl($ssh_out, &F_SETFL, $flags) || die $!;

	msg("Waiting for prompt\n");

	unless ($key){
		wait_regexp($self, qr/[Pp]assword:/);
		run_string($self, $self->{'root_password'});
	}
	sleep(1); #hack wait for prompt
	wait_prompt($self);
	if ($user ne 'root') {
		run_string($self, 'sudo /bin/sh');
		wait_prompt($self);
	}
}

sub ssh_stop
{
	my ($self) = @_;
	my $user = $self->{'ssh_user'};

	run_string($self, "exit");
	run_string($self, "exit") if ($user ne 'root');

	waitpid($self->{'pid'}, 0);
}

sub ssh_force_stop
{
	my ($self) = @_;

	msg("Force stopping ssh!\n");
	kill('TERM', $self->{'pid'});
	waitpid($self->{'pid'}, 0);

	serial_relay_force_stop($self);
}

my $ssh_params = [
	['password', 'root_password', "Remote machine root password"],
	['host', 'ssh_host', "Remote machine hostname or IP"],
	['user', 'ssh_user', "Remote user, if other then root use sudo to get root"],
	['key_file', 'ssh_key', 'File for public key authentication'],
	['serial_relay_port', 'serial_relay_port', "Serial relay poor man's reset dongle port"],
];

sub ssh_init
{
	my %backend;

	parse_params(\%backend, "ssh", $ssh_params, @_);

	die("ssh:host must be set!") unless defined($backend{'ssh_host'});
	die("ssh:password or ssh:key_file must be set!")
		unless (defined($backend{'root_password'})
			|| defined($backend{'ssh_key'}));
	$backend{'ssh_user'} //= 'root';

	$backend{'start'} = \&ssh_start;
	$backend{'stop'} = \&ssh_stop;
	if ($backend{'serial_relay_port'}) {
		$backend{'force_stop'} = \&ssh_force_stop;
	}
	$backend{'name'} = 'ssh';
	$backend{'buf'} = '';

	return \%backend;
}

sub sh_start
{
	my ($self) = @_;
	my $shell = $self->{'shell'};

	msg("Starting $shell\n");

	my ($sh_out, $sh_in);
	my $pid = open2($sh_out, $sh_in, $self->{'shell'}) or die("Fork failed");

	$self->{'pid'} = $pid;
	$self->{'in_fd'} = $sh_in;
	$self->{'out_fd'} = $sh_out;

	run_string($self, 'export PS1="# "');
	wait_prompt($self);
}

my $sh_params = [
	['shell', 'shell', 'Shell path e.g. "/bin/sh" or "dash"'],
	['password', 'root_password', 'Root password']
];

sub sh_init
{
	my %backend;

	$backend{'shell'} = "/bin/sh";

	parse_params(\%backend, "sh", $sh_params, @_);

	$backend{'start'} = \&sh_start;
	$backend{'stop'} = \&ssh_stop;
	$backend{'name'} = 'sh';
	$backend{'buf'} = '';

	return \%backend;
}

my @backends = (
	["sh", $sh_params, \&sh_init],
	["ssh", $ssh_params, \&ssh_init],
	["qemu", $qemu_params, \&qemu_init],
);

sub new
{
	my ($opts) = @_;

	my @backend_params = split(':', $opts);
	my $backend_type = shift @backend_params;

	msg("Running test with $backend_type parameters '@backend_params'\n");

	for (@backends) {
		return $_->[2]->(@backend_params) if ($_->[0] eq $backend_type);
	}

	die("Invalid backend type '$backend_type'\n");
}

sub help
{
	for (@backends) {
		print_help($_->[0], $_->[1]);
	}
}

sub set_logfile
{
	my ($self, $path) = @_;

	open(my $fh, '>', $path) or die("Can't open $path: $!");

	$self->{'raw_logfile'} = $fh;
}

sub check_cmd
{
	my ($self, $cmd) = @_;
	return run_cmd($self, $cmd) != 127;
}

sub read_file
{
	my ($self, $path) = @_;
	my @res = run_cmd($self, "cat $path");

	if ($res[0] != 0) {
		print("Failed to read file $path");
		return;
	}

	return @res[2 .. $#res];
}

1;
