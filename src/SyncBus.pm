package SyncBus;
use strict;
use warnings;
use threads;
use threads::shared;

sub new {
    my ($class) = @_;
    
    # create a thread-safe shared hash for the bus state
    my $self = &share({});
    $self->{value}    = 0;
    $self->{has_data} = 0;
    
    return bless $self, $class;
}

# thread A writes to s and pauses until thread b reads s
sub write {
    my ($self, $val) = @_;
    lock($self);
    
    # wait if previous data hasnt been consumed yet
    cond_wait($self) while $self->{has_data};
    
    $self->{value} = $val;
    $self->{has_data} = 1;
    
    # wake up any waiting readers
    cond_broadcast($self);
    
    # pause the writing thread until the reader consumes the value
    cond_wait($self) while $self->{has_data};
}

# thread B reads S, pausing until thread a writes to S
sub read {
    my ($self) = @_;
    lock($self);
    
    # pause the reading thread until a writer pushes data
    cond_wait($self) until $self->{has_data};
    
    my $val = $self->{value};
    $self->{has_data} = 0;
    
    # wake up the waiting writer to acknowl receipt
    cond_broadcast($self);
    
    return $val;
}

1;
