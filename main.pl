#!/usr/bin/env perl
use threads;
use threads::shared;
use strict;
use warnings;
use lib '.';
use SyncBus;
use memhook;
use clis;

package Subleq::Interpreter;

use integer; 

sub new {
    my ($class, $memory, %opts) = @_;
    return bless {
        mem       => $memory || [],
        pc        => 0,
        # Default to 64-bit if not specified
        bit_width => $opts{bit_width} || 64,
        sync_bus  => $opts{sync_bus}, 
    }, $class;
}

sub run {
    my ($self) = @_;

    local $| = 1;

    my $mem = $self->{mem};
    my $pc  = $self->{pc} || 0;
    
    my $is_32_bit = ($self->{bit_width} == 32);

    # pre-allocate base memory (64k minimum)
    my $min_size = 65536;
    if (@$mem < $min_size) {
        $#$mem = $min_size - 1;
    }

    # zero-fill uninitialized memory slots upfront
    for my $i (0 .. $#$mem) {
        $mem->[$i] //= 0;
    }

    my $mem_len = scalar @$mem;

    while ($pc >= 0) {
        if ($pc + 2 >= $mem_len) {
            my $target_max = $pc + 2;
            my $new_len = $mem_len * 2;
            $new_len = $target_max + 1 if $new_len <= $target_max;
            
            $mem->[$_] //= 0 for $mem_len .. $new_len - 1;
            $mem_len = scalar @$mem;
        }
    
        my $a = $mem->[$pc];
        my $b = $mem->[$pc + 1];

        # hot path: pure sq execution

        if ($a >= 0 && $b >= 0 && $a < $mem_len && $b < $mem_len) {
            my $target_val = $mem->[$b] - $mem->[$a];

            # apply 32-bit signed twos complement wrapping
            # (64-bit wrapping is handled natively ig)
            if ($is_32_bit) {
                $target_val &= 0xFFFFFFFF;
                $target_val -= 0x100000000 if $target_val >= 0x80000000;
            }

            $mem->[$b] = $target_val;

            if ($target_val <= 0) {
                my $c = $mem->[$pc + 2];
                last if $c < 0; 
                $pc = $c;
            } else {
                $pc += 3;
            }
            next;
        }

      
        # cold path: handling i/o (-1), o-o-b, and errs
        
        my $c = $mem->[$pc + 2];

        if ($a < -2 || $b < -2) {
                    die "Segmentation fault: invalid address at PC=$pc (A: $a, B: $b)\n";
        }
        
        if ($a >= $mem_len || $b >= $mem_len) {
            my $max_addr = $a > $b ? $a : $b;
            my $new_len = $mem_len * 2;
               $new_len = $max_addr + 1 if $new_len <= $max_addr;
                    
               $mem->[$_] //= 0 for $mem_len .. $new_len - 1;
               $mem_len = scalar @$mem;
            }
        
        # fetch a
        my $val_a;
        if ($a == -1) {
            my $ch = getc(STDIN);
               $val_a = defined $ch ? ord($ch) : -1;
        } elsif ($a == -2 && $self->{sync_bus}) {
            # READ from Rendezvous Bus (Blocks until writer is ready)
            $val_a = $self->{sync_bus}->read();
        } else {
            $val_a = $mem->[$a];
        }
        
        # execute b
        my $target_val;
        if ($b == -1) {
            print chr($val_a & 0xFF);
            $target_val = -$val_a; 
        } elsif ($b == -2 && $self->{sync_bus}) {
            # write to bus (blocks until reader consumes)
            $self->{sync_bus}->write($val_a);
            $target_val = -$val_a; 
        } else {
            $target_val = $mem->[$b] - $val_a;
                    
            if ($is_32_bit) {
                $target_val &= 0xFFFFFFFF;
                $target_val -= 0x100000000 if $target_val >= 0x80000000;
            }
                    
            $mem->[$b] = $target_val;
        }
        
        # branching
        if ($target_val <= 0) {
            last if $c < 0;
            $pc = $c;
        } else {
            $pc += 3;
        }
    }

    $self->{pc} = $pc;
}

sub map_address {
    my ($self, $address, %callbacks) = @_;
    
    my $mem = $self->{mem};

    # ensure the mem array is large enough to hold the tied address
    if (scalar @$mem <= $address) {
        $#$mem = $address; 
    }

    # tie tis specific scalar element in the array
    tie $mem->[$address], 'MemoryHook',
        on_read  => $callbacks{on_read},
        on_write => $callbacks{on_write},
        value    => $mem->[$address] || 0;
}

package main;

if (@ARGV < 1 || @ARGV > 2) {
    die "Usage: perl $0 <source_file.sq> [config.clis]\n";
}

my $filename = $ARGV[0];
my $clis_file = $ARGV[1];

# 2. open the file
open(my $fh, '<', $filename) or die "Error: Cannot open file '$filename': $!\n";

my @program;

# 3. parse the file resiliently
while (my $line = <$fh>) {
    # strip comments
    $line =~ s/#.*//;
    
    # extract all valid integers (+&-)
    push @program, $line =~ /(-?\d+)/g;
}
close($fh);

if (!@program) {
    die "Error: No valid Subleq instructions found in '$filename'.\n";
}

my @start_pcs = split(',', $ENV{SUBLEQ_PCS} || '0');
my $sync_bus  = SyncBus->new();

my @threads;
my $thread_id = 0;

print "[SYSTEM] Booting " . scalar(@start_pcs) . " Subleq cores...\n";

foreach my $start_pc (@start_pcs) {
    $thread_id++;
    
    push @threads, threads->create(sub {
        my ($tid, $pc) = @_;
        
        # clone the program memory so each actor has independent local state
        my @local_memory = @program;
        
        my $vm = Subleq::Interpreter->new(
            \@local_memory, 
            bit_width => 32, 
            pc        => $pc,
            sync_bus  => $sync_bus
        );

        if ($clis_file) {
            clis::load_config($clis_file, $vm);
        }

        # start execution
        $vm->run();
        
        return $tid;
    }, $thread_id, $start_pc);
}

# wait for all actors to halt
foreach my $t (@threads) {
    my $tid = $t->join();
    print "\n[SYSTEM] Core $tid halted gracefully.\n";
}

# 5. boot the vm and execute
# dev can set bit_width => 32 or bit_width => 64 here;)
my $vm = Subleq::Interpreter->new(\@program, bit_width => 32);

if ($clis_file) {
    clis::load_config($clis_file, $vm);
    print "[CLIS] Configuration successfully loaded from '$clis_file'\n";
}

$vm->run();
