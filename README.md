Runltp-ng
=========

This installs and runs the Linux Test Project on a system in a virtual machine
or a remote system over SSH. You specify which tests you want to run, the
details of the system under test (SUT) and it does the rest.

Unlike the original runltp script, this does not execute on the SUT. It runs
on a seperate host which controls the SUT.

Quickstart
==========

You can get help with `./runltp --help`.

QEMU
----

First you need a VM image which boots without user input and starts a serial
terminal on ttyS0 (See Grub section below).

For Debian and SUSE atleast you may automatically install LTP by doing
something like the following.

```
$ ./runltp --verbose --setup --install=mybranch --repouri=/mnt/ltp\
           --backend=qemu:ram=4G:smp=4:image=/local/vm.qcow2:virtfs=/local:password=123\
```

This assums you have a local checkout of the LTP at `/local/ltp` with a branch
`mybranch`. The `virtfs` backend option will cause `/local` to be mounted on
the virtual machine at `/mnt` (as read-only).

The `--setup` option will try to install the required packages for building
the LTP before trying to clone/download and build it.

The `--install` option specifies which branch to install. If Git is present,
then it will try to do a git clone otherwise it will try to guess the archive
location and download that. `--repouri` can be a local or remote Git
repository or omitted to use the main repo.

The `--verbose` flag causes the SUTs serial I/O to be printed to stdout as
well as other info. Otherwise this information is just available in the
logs.

If you want the OpenPOSIX test suite or the Syzkaller reproducers to be
installed then you could do something like.

```
$ ./runltp --run=syzkaller --install=master\
           --backend=qemu:ram=4G:smp=4:image=/local/vm.qcow2:password=123\
```

This will also try to run a runtest file called syzkaller, but no such file
exists. To run the tests:

```
$ ./runltp-ng --run=syzkaller1 --timeout=20\
              --backend=qemu:ram=4G:smp=4:image=/local/vm.qcow2:password=123:image-overlay=1 
```

This will run the tests with an overall timeout of 20 seconds (usually it is
300+). The backend option `image-overlay=1` means that all changes to the VM
image during execution are written to a temporary image overlay which is
recreated if the runner is forced to reboot the SUT.

Sometimes you can skip installation altogether and just run tests from your
host machine.

```
$ ./runltp --run=syscalls --ltpdir=/mnt\
           --backend=qemu:ram=4G:smp=4:image=/local/vm.qcow2:virtfs=/opt/ltp:password=123
```

This assumes you have the LTP installed in `/opt/ltp` on your host and the
guest and host share the same version of libc (or you compiled LTP with static
linking).

You can also run a single command.

```
$ ./runltp --cmd=/mnt/testcases/kernel/systemcalls/bpf/bpf_prog02\
           --backend=qemu:ram=4G:smp=4:image=/local/vm.qcow2:virtfs=/home/me/ltp:password=123
```

The option `--cmd` just specifies some text to pass to the shell. If used with
`--run` then it is executed before the tests.

Once you have executed `runltp` a number of log files will be written to its
directory. These include the raw serial output and a HTML report amongst other
things.

Kernel automation cookbook
==========================

Preface
-------

Automated kernel testing always was and is a bit more complicated than testing
the userspace. There are a few reasons for that but the main reason is that the
machine the testcases are executed on may and will crash in the middle of a
testrun throwing away the test results. This naturally calls for a separation
of the machine that decides what testcase to run and logs the results from the
machine that actually runs the tests.

This requirement has became the main motivation for replacing the dated LTP
test execution framework with something that meets this requirement as it
became more and more clear that rebooting the machine manually and disabling
tests does not scale. It became more of a burden as we started to implement
more and more kernel regression tests and it became less and less likely that
the machine will outlive the actuall testrun.

The second but still important reason for a new testrunner is to implement a
continuous integration (CI) for the LTP testsuite itself. The LTP release
process a tedious one and currently relies on different parties to execute the
testsuite and manually review the results. Because of that the releases are
done four times year and require significant amount of manual labor. With the
new LTP execution framework you should be able to run the testsuite on a few
different virtual machines and compare results of latest git HEAD against last
stable snapshot which may shorten the release cycle from three months to a few
weeks.


Design goals
------------

Main design goal is simplicity. What I wanted to avoid is a "one solution fits
all" monster hence the LTP upstream test execution framework should be rather
considered to be reference implementation or a "recipe" rather than finished
and polished solution. It may fit your needs after a few minor tweaks though.
For the same reason the installation of the system is left out, it's expected
to be used on pre-installed qemu images or on physical machines installed by
other means.

The core functionality is build upon a unix shell wrapped in pipes which is
used to install the LTP as well as to execute testcases. This allows for a
different backends to be included in the test runner. The backends differ in
the way the shell is reached but once that has been set up the generic code
takes on.

The most useful backends at the moment are qemu backend, that can run the tests
inside of a virtual machine and the ssh backend that runs tests over ssh.

As discussed previously the system under test (SUT) is separated from the test
execution framework in order to be able to recover from kernel crashes, however
separation is only half of the solution. Successful recovery needs to be able
to detect that kernel has been broken and to reboot the SUT so that we can
continue with the testrun.

Detecting kernel corruptions is a tricky problem since once that happens all
bets are off and we enter the land of undefined behavior. Sometimes the problem
manifests too late to be easily connected to the test that triggered it as
well. Hoewever happily for us the recent kernels are quite good in detecting
various unexpected conditions and they produce a trace and set the tainted
flags, at least that seems to be the case for most of our regression tests.
Hence checking the taint flags after a failed testcase should, most of the
time, suffice in detecting if kernel was broken. Another possibility we have to
handle is that the shell we use to run tests, or the whole machine will hang,
which is easily done with a timeout.

Once we detect that SUT kernel is in undefined state we have to reboot the
machine so that we can continue with the rest of the testrun. Unfortunately
issuing poweroff command rarely works in such situation hence we need a way to
force reboot the SUT. The implementation is backend specific and may even
differ greatly for a single backend. See below for a details.

HOWTO
-----


### Backends

All backends needs to be able to reach internet after a successfull login/boot
and have to have installed all the tools needed to compile the LTP testsuite
plus git in order to download and compile the LTP.

### QEMU backend

The qemu backend runs the testcases inside of an virtual machine. The
testrunner expects that the machine is configured to start a console on a first
serial port (console=ttyS0 on x86 kernel command line), the path to the virtual
machine harddisk image as well as root password has to be specified on the
command line. Older distributions may need getty enabled in /etc/inittab as
well so that we can log in on the serial console.

The force reboot is implemented by killing the qemu process and does not
require any user specific setup.

#### GRUB2 configuration

To enable console on ttyS0 for a VM do:

* open /etc/default/grub
* add "console=ttyS0, console=tty0"  to 'GRUB\_CMDLINE\_LINUX'
* run grub-mkconfig -o /boot/grub/grub.cfg

### SSH backend

The ssh backend runs testcases runs testcases over SSH remote shell, the
destination hostname or IP address as well as root password are required to be
passed on the command line.

The force reboot defaults to manual one, i.e. the test runner waits for the
user to reboot the machine which defeats the purpose of the automated testing.
You can use serial\_relay dongle on a reset switch as a poor man's solution for
remote reboot which I used to verify the test runner implementation or adapt the
test runner to support your solution to reboot the servers such as IPMI.

### Serial relay reboot dongle

This is a quick and dirty solution for rebooting a machine (mis)using the RTS
signal line on the serial port to toggle a relay connected to a reset switch on
a SUT. Keep in mind that this is a simple solution I've used to test the test
runner rather than a real solution to the problem.

You can easily buy a cheap relay board with several relays and write a few
lines of perl to interface it with the testrunner.

Schematics:
```
                                           | to the reset switch |
                                           |          _-`        |
   Serial port                             +-------o-`   o-------+

     1 o                                     c     +-----+
            o 6                              ---+--|     |--+--------------c
     2 o          RTS    1k             b | /   |  +-----+  |             12V
            o 7 -------[IIII]----+--------|     |           |        (for 12V relay)
     3 o                         |        | \   +----|>|----+
            o 8                  |    2n3904 |e |   1n4148
     4 o             +----|>|----+           |  |
            o 9      |  1n4148               |  |     1k     ``
  +- 5 o             |                       |  +---[IIII]---|>|---+
  |  gnd             |                       |                     |       GND
  +------------------+-----------------------+---------------------+--------c

```

