sqf - subleq with flesh

i made an over-engineered fleshy vm/interpreter for the OISC; Subleq.

i made this thing for a cs exhibit i'm participating, and also for to practice a bit of Perl. As i said, this vm/interpreter
executes the esolang Subleq, but with some new stuff and a bit more optimization. sqf, unlike standard Subleq interpreter
is multi-threaded, has a thread-safe synchroni-bus, dynamic memory allocation and a new thing of user managed and
configed memory-mapped I/O and system side effects through an integrated and optimized DSL called CLIS.

In the Hot/Cold Path Optimization, the execution loop is strictly separated to keep standard operations lightning fast 
(99% of cycles) while delegating bounds-checking and I/O to a secondary cold path. While for dynamic memory
management, base memory starts at 64k, dynamically expanding exponentially 
if the program counter or memory accesses jump out of bounds. Multi-core execution boot multiple independent 
Subleq cores simultaneously using OS-level threads, each with its own local memory state.
Then rendezvous sync bus, a thread-safe, blocking communication bus allows independent Subleq 
threads to pass data to one another. The memory-mapped I/O and system side effects is user configed and intercepts specific 
memory reads and writes to trigger real-world side effects like desktop notifications, shell commands, random number generation, 
and timestamps with a file written CLIS(more on that coming).

Subleq operates on a single instruction taking three operands: A, B, C.
The VM executes the following logic:

1. Subtract the value at memory address A from the value at memory address B.  
2. Store the result in memory address B.  
3. If the result is less than or equal to 0, jump the Program Counter (PC) to address C.  
4. Otherwise, advance the PC by 3.

The Hot/Cold Path Architecture

To maintain maximum performance, the VM execution is split:

```perl
# HOT PATH: Standard execution
if ($a >= 0 && $b >= 0 && $a < $mem_len && $b < $mem_len) {
    my $target_val = $mem->[$b] - $mem->[$a];
    # ... applies wrapping and branching ...
    next; # Skip cold path checks entirely
}

# COLD PATH: Handling I/O (-1), SyncBus (-2), and Expansion
# ... handles dynamic memory bounds and special I/O addresses ...
```

Note: The Hot Path safely ignores complex I/O and 
boundary limits by filtering for standard valid addresses, allowing for maximum instruction throughput.

Usage

Basic execution

You must provide a Subleq source file (.sq) containing whitespace or newline-separated integers.
```bash
perl main.pl program.sq
```

Loading with a reactive-address config file

You can pass an optional .clis configuration file to map memory addresses to system functions.
```bash
perl main.pl program.sq config.clis
```

Multi-core booting

You can spawn multiple Subleq cores executing simultaneously by defining the starting Program Counters via the 
SUBLEQ_PCS environment variable (comma-separated).
```bash
# Boots 3 cores starting at addresses 0, 50, and 100
SUBLEQ_PCS=0,50,100 perl main.pl program.sq
```

Memory-Mapped I/O with CLIS

The Config Lang Integrated with Subleq (CLIS) allows you to bind memory addresses to Perl callbacks using the tie mechanism.

CLIS Syntax
```
hook <addr> <read|write> -> <action>(<args>)
```

Multi-core sync

The VM includes a built-in SyncBus for safe inter-thread communication. The bus utilizes a strict rendezvous sys: 
the writer pauses until the data is read, and the reader pauses until the data is written.

Subleq programs interface with the SyncBus using address -2:

- Write to Bus: Use -2 as operand B
* Read from Bus: Use -2 as operand A
```perl
# SyncBus.pm implements cond_wait and cond_broadcast to safely lock threads
sub write {
    my ($self, $val) = @_;
    lock($self);
    cond_wait($self) while $self->{has_data}; # Wait for empty bus
    $self->{value} = $val;
    $self->{has_data} = 1;
    cond_broadcast($self); # Wake readers
    cond_wait($self) while $self->{has_data}; # Pause until consumed
}
```

And thanks to my friend, [Kamila](https://github.com/iczelia) for the idea for this project.

---

Author: nulsie License: MIT
