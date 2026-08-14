package clis;
use strict;
use warnings;

sub load_config {
    my ($file, $vm) = @_;

    open(my $fh, '<', $file) or die "Error: Cannot open config file '$file': $!\n";

    my $line_num = 0;
    while (my $line = <$fh>) {
        $line_num++;
        
        # 1. strip comments and whitespace
        $line =~ s/#.*//;
        $line =~ s/^\s+|\s+$//g;
        next if $line eq ''; 

        # 2. matchclis Syntax: hook <addr> <read|write> -> <action>(<args>)
        if ($line =~ /^hook\s+(\d+)\s+(write|read)\s*->\s*(\w+)\s*\((.*)\)\s*;?$/i) {
            my ($addr, $event, $action, $args_str) = ($1, lc($2), lc($3), $4);
            
            my @args = parse_clis_args($args_str);
            my $callback = compile_action($action, \@args, $line_num);

            # 3. reg compiled closure into vm
            if ($event eq 'write') {
                $vm->map_address($addr, on_write => $callback);
            } elsif ($event eq 'read') {
                $vm->map_address($addr, on_read => $callback);
            }
        } else {
            die "CLIS Syntax Error in '$file' on line $line_num: '$line'\n";
        }
    }
    close($fh);
}

sub parse_clis_args {
    my ($str) = @_;
    my @args;
    while ($str =~ /"(.*?)"|'(.*?)'|([^,\s]+)/g) {
        push @args, defined $1 ? $1 : (defined $2 ? $2 : $3);
    }
    return @args;
}


sub compile_action {
    my ($action, $args, $line_num) = @_;

    if ($action eq 'notify') {
        my $title = $args->[0] // 'Subleq VM';
        my $msg_template = $args->[1] // 'Value updated: {val}';

        $title =~ s/'/'\\''/g; 

        return sub {
            my ($val) = @_;
            
            # Security: Strictly validate that $val is an integer
            die "Security Error: Non-numeric value '$val' passed to notify\n" unless $val =~ /^-?\d+$/;

            my $msg = $msg_template;
            $msg =~ s/\{val\}/$val/g;
            
            # Security: Escape quotes in the final message
            $msg =~ s/'/'\\''/g;

            system("notify-send '$title' '$msg'");
        };
    }
    
    elsif ($action eq 'exec') {
        my $cmd_template = $args->[0] // 'echo {val}';
        
        return sub {
            my ($val) = @_;
            
            die "Security Error: Non-numeric value '$val' passed to exec\n" unless $val =~ /^-?\d+$/;

            my $cmd = $cmd_template;
            $cmd =~ s/\{val\}/$val/g;
            
            system($cmd);
        };
    }
    
    elsif ($action eq 'print') {
        my $fmt = $args->[0] // "{val}\n";
        return sub {
            my ($val) = @_;
            
            $val = 0 unless defined $val && $val =~ /^-?\d+$/;

            my $out = $fmt;
            $out =~ s/\{val\}/$val/g;
            $out =~ s/\\n/\n/g;
            $out =~ s/\\t/\t/g;
            print $out;
        };
    }
    
    elsif ($action eq 'timestamp') {
        return sub { return time(); };
    }
    
    elsif ($action eq 'random') {
        my $max = $args->[0] // 100;
        
        $max = 100 unless $max =~ /^\d+$/;
        
        return sub { return int(rand($max)); };
    }

    die "CLIS Compile Error: Unknown action '$action' on line $line_num\n";
}

1;
