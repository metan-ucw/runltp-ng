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

use Time::HiRes qw(clock_gettime CLOCK_MONOTONIC);

use IPC::Open2;
use POSIX ":sys_wait_h";
use Fcntl;
use Errno;
use IO::Poll qw(POLLIN);
use Text::ParseWords;

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

	my $start_time = clock_gettime(CLOCK_MONOTONIC);

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

		if (defined($timeout) and clock_gettime(CLOCK_MONOTONIC) - $start_time > $timeout) {
			msg("$self->{'name'}: timeouted!\n");
			return @log;
		}

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

	print($in_fd "$string\n");
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

	$cmd_seq_cnt += 1;

	wait_prompt($self);

	wantarray ? ($ret, @log) : $ret;
}

sub run_cmds
{
	my ($self, $cmds, %args) = @_;
	my @log;

	push(@log, {cmd => '', ret => 0, log => ''}) unless (@{$cmds});

	for my $cmd (@{$cmds}) {
		my ($retval, @output) = run_cmd($self, $cmd, $args{timeout});
		push(@log, {cmd => $cmd, ret => $retval, log => \@output});

		unless (defined($retval) && $retval == 0) {
			return wantarray ? @log : $retval;
		}
	}
	return wantarray ? @log : 0;
}

sub interactive($)
{
	my ($self) = @_;

	if (defined($self->{'interactive'})) {
		msg(0, 'Run: ' . $self->{'interactive'}->($self) . "\n");
	} else {
		msg(0, "Interactive not implemented for $self->{'name'}\n");
	}
}

sub start
{
	my ($self) = @_;

	$self->{'start'}->($self) if defined($self->{'start'});
}

sub stop
{
	my ($self, $timeout) = @_;

	close($self->{'raw_logfile'}) if defined($self->{'raw_logfile'});

	$self->{'stop'}->($self, $timeout) if defined($self->{'stop'});
}

sub serial_relay_force_stop
{
	my ($self) = @_;

	my $port = $self->{'serial_relay_port'};

	msg("Resetting machine backend $self->{'name'} serial relay port $port\n");

	open(my $fh, '<', $port);
	sleep(0.1);
	close($fh);
}

sub force_stop
{
	my ($self, $timeout) = @_;

	if (defined($self->{'force_stop'})) {
		return $self->{'force_stop'}->($self, $timeout);
	} else {
		print("Backend $self->{'name'} has to be force stopped manually\n");
		print("Please bring the machine into usable state and then press any key\n");
		<STDIN>;
	}
	return 0;
}

sub reboot($$)
{
	my ($self, $timeout) = @_;

	my $ret = force_stop($self, $timeout);
	return $ret if ($ret != 0);
	$ret = start($self);
	return $ret;
}

sub qemu_read_file($$)
{
	my ($self, $path) = @_;
	my @lines;

	if (run_cmd($self, "cat \"$path\" > /dev/$self->{'transport_dev'}")) {
		msg("Failed to write file to $self->{'transport_dev'}");
		return @lines;
	}

	if (run_cmd($self, "echo 'runltp-ng-magic-end-of-file-string' > /dev/$self->{'transport_dev'}")) {
		msg("Failed to write to $self->{'transport_dev'}");
		return @lines;
	}

	my $fh = $self->{'transport'};

	while (1) {
		my $line = <$fh>;
		# Strip CR LF
		$line =~ s/(\x0d|\x0a)//g;
		last if ($line eq "runltp-ng-magic-end-of-file-string");
		push(@lines, $line);
	}

	return @lines;
}

sub qemu_cmdline
{
	my ($self) = @_;

	return "qemu-system-$self->{'qemu_system'} $self->{'qemu_params'}";
}

sub qemu_create_overlay
{
	my ($self) = @_;

	my $ret = system('qemu-img', 'create', '-f', 'qcow2',
			 '-b', $self->{'qemu_image_backing'},
			 $self->{'qemu_image'});

	$ret == 0 || die("Failed to create image overlay: $?");
}

sub qemu_interactive($)
{
	my ($self) = @_;
	my $cmdline = qemu_cmdline($self);

	msg("Starting qemu with: $cmdline\n");
	qemu_create_overlay($self) if (defined($self->{'qemu_image_overlay'}));
	exec $cmdline || die("Failed to exec QEMU: $?");
}

sub qemu_start
{
	my ($self) = @_;
	my $cmdline = qemu_cmdline($self);

	qemu_create_overlay($self) if (defined($self->{'qemu_image_overlay'}));

	msg("Starting qemu with: $cmdline\n");

	unlink($self->{'transport_fname'});

	my ($qemu_out, $qemu_in);
	my $pid = open2($qemu_out, $qemu_in, $cmdline) or die("Fork failed");

	$self->{'pid'} = $pid;
	$self->{'in_fd'} = $qemu_in;
	$self->{'out_fd'} = $qemu_out;

	for (my $i = 0; $i < 10; $i++) {
		if (open(my $fh, '<', $self->{'transport_fname'})) {
			$self->{'transport'} = $fh;
			$self->{'read_file'} = \&qemu_read_file;
			last;
		}
		msg("Waiting for '$self->{'transport_fname'}' file to appear\n");
		sleep(1);
	}

	die("Can't open transport file") unless defined($self->{'transport'});

	msg("Waiting for qemu to boot the machine\n");

	wait_regexp($self, qr/login:/);
	run_string($self, "root");
	wait_regexp($self, qr/[Pp]assword:/);
	run_string($self, "$self->{'root_password'}");
	wait_prompt($self);
	run_string($self, "export PS1=\$ ");

	if (defined($self->{'qemu_virtfs'})) {
		run_cmd($self, 'mount -t 9p -o trans=virtio host /mnt');
	}
}

sub qemu_stop($$)
{
	my ($self, $timeout) = @_;

	close($self->{'transport'}) if defined($self->{'transport'});

	unlink($self->{'transport_fname'});

	msg("Stopping qemu pid $self->{'pid'}\n");

	run_string($self, "poweroff");

	while ($timeout > 0) {
		return 0 if waitpid($self->{'pid'}, WNOHANG);
		sleep(1);
		$timeout -= 1;
		#flush($self);
	}

	msg("Failed to stop qemu, killing it!\n");

	kill('TERM', $self->{'pid'});
	return waitpid($self->{'pid'}, 0) < 0 ? -1 : 0;
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
	['image-overlay', 'qemu_image_overlay', 'If set, an image overlay is created before each boot and changes are written to that instead of the original'],
	['password', 'root_password', 'Qemu image root password'],
	['opts', 'qemu_opts', 'Additional qemu command line options'],
	['system', 'qemu_system', 'Qemu system such as x86_64'],
	['ram', 'qemu_ram', 'Qemu RAM size, defaults to 1.5G'],
	['smp', 'qemu_smp', 'Qemu CPUs defaults to 2'],
	['virtfs', 'qemu_virtfs', 'Path to a host folder to mount in the guest (on /mnt)'],
	['serial', 'qemu_serial', 'Qemu serial port device type, currently only support isa (default) and virtio'],
	['ro-image', 'qemu_ro_image', 'Path to an image which will be exposed as read only']
];

sub qemu_init
{
	my %backend;
	my $transport_fname = "transport-" . getppid();
	my $tty_log = "ttyS0-" . getppid();
	my $ram = "1.5G";
	my $smp = 2;
	my $serial = 'isa';

	parse_params(\%backend, "qemu", $qemu_params, @_);

	$ram = $backend{'qemu_ram'} if (defined($backend{'qemu_ram'}));
	$smp = $backend{'qemu_smp'} if (defined($backend{'qemu_smp'}));
	$serial = $backend{'qemu_serial'} if (defined($backend{'qemu_serial'}));

	$backend{'transport_fname'} = $transport_fname;
	$backend{'qemu_params'} = "-enable-kvm -m $ram -smp $smp -display none";
	$backend{'qemu_params'} .= " -device virtio-rng-pci";
	$backend{'qemu_system'} = 'x86_64';

	if ($serial eq 'isa') {
		$backend{'transport_dev'} = 'ttyS1';
		$backend{'qemu_params'} .= " -chardev stdio,id=tty,logfile=$tty_log.log -serial chardev:tty";
		$backend{'qemu_params'} .= " -serial chardev:transport -chardev file,id=transport,path=$transport_fname";
	} elsif ($serial eq 'virtio') {
		$backend{'transport_dev'} = 'vport1p1';
		$backend{'qemu_params'} .= " -device virtio-serial";
		$backend{'qemu_params'} .= " -chardev stdio,id=tty,logfile=$tty_log.log --device virtconsole,chardev=tty";
		$backend{'qemu_params'} .= " -device virtserialport,chardev=transport -chardev file,id=transport,path=$transport_fname";
	} else {
		die("Unupported serial device type $backend{'qemu_serial'}");
	}

	die('Qemu image not defined') unless defined($backend{'qemu_image'});

	if (defined($backend{'qemu_image_overlay'})) {
		$backend{'qemu_image_backing'} = $backend{'qemu_image'};
		$backend{'qemu_image'} .= '.overlay';
	}

	$backend{'qemu_params'} .= ' -drive if=virtio,cache=unsafe,file=' . $backend{'qemu_image'};
	if (defined($backend{'qemu_ro_image'})) {
		$backend{'qemu_params'} .= ' -drive read-only,if=virtio,cache=unsafe,file='
		    . $backend{'qemu_ro_image'};
	}

	if (defined($backend{'qemu_opts'})) {
		$backend{'qemu_params'} .= ' ' . $backend{'qemu_opts'};
	}

	if (defined($backend{'qemu_virtfs'})) {
		$backend{'qemu_params'} .= ' -virtfs local' .
			',path=' . $backend{'qemu_virtfs'} .
			',mount_tag=host' .
			',security_model=mapped-xattr' .
			',readonly';
	}

	$backend{'interactive'} = \&qemu_interactive;
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

	my $sshcmd = 'ssh ';
	$sshcmd .= ($key ? "-i $key " : " ");
	$sshcmd .= $self->{'ssh_opts'} . ' ';
	$sshcmd .= "$user\@$host";
	$sshcmd =~ s/'/'"'"'/g;
	my $cmdline = "export TERM=dumb; script -f -c '$sshcmd' /dev/null";

	msg("Starting ssh: $cmdline\n");

	my ($ssh_out, $ssh_in);
	my $pid = open2($ssh_out, $ssh_in, $cmdline) or return -1;

	$self->{'pid'} = $pid;
	$self->{'in_fd'} = $ssh_in;
	$self->{'out_fd'} = $ssh_out;

	my $flags = 0;
	fcntl($ssh_out, F_GETFL, $flags) || return -1;
	$flags |= O_NONBLOCK;
	fcntl($ssh_out, F_SETFL, $flags) || return -1;

	msg("Waiting for prompt\n");

	unless ($key) {
		wait_regexp($self, qr/[Pp]assword:/);
		run_string($self, $self->{'root_password'});
	}
	sleep(1);    #hack wait for prompt
	wait_prompt($self);
	if ($user ne 'root') {
		run_string($self, 'sudo /bin/sh');
		wait_prompt($self);
	}
	return 0;
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
	['reset_command', 'reset_command', 'If SUT hang, given command is '
	                . 'executed to reset. If command exit with error, test gets '
	                . 'stopped otherwise ssh connection will be reinitalized. '],
	['ssh_opts', 'ssh_opts', 'Additional ssh options']
];

sub ssh_reset_command
{
	my ($self) = @_;
	my $cmd = $self->{'reset_command'};

	my $out = qx/$cmd/;
	if ($? != 0) {
		msg("SSH reset_command failed: $out");
	}
	return $? >> 8;
}

sub ssh_init
{
	my %backend;

	parse_params(\%backend, "ssh", $ssh_params, @_);

	die("ssh:host must be set!") unless defined($backend{'ssh_host'});
	die("ssh:password or ssh:key_file must be set!")
		unless (defined($backend{'root_password'})
		|| defined($backend{'ssh_key'}));
	$backend{'ssh_user'} //= 'root';
	$backend{'ssh_opts'} //= '';

	$backend{'start'} = \&ssh_start;
	$backend{'stop'} = \&ssh_stop;
	if ($backend{'serial_relay_port'}) {
		$backend{'force_stop'} = \&ssh_force_stop;
	}
	elsif ($backend{'reset_command'}) {
		$backend{'force_stop'} = \&ssh_reset_command;
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

	my @backend_params = quotewords(':', 0, $opts);
	my $backend_type = shift @backend_params;

	msg("Using $backend_type backend; parameters '@backend_params'\n");

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

sub read_file
{
	my ($self, $path) = @_;

	if (defined($self->{'read_file'})) {
		return $self->{'read_file'}->($self, $path);
	}

	my @res = utils::run_cmd_retry($self, "cat $path");

	if ($res[0] != 0) {
		print("Failed to read file $path");
		return;
	}

	return @res[2 .. $#res];
}

1;
