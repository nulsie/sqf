package MemoryHook;
use strict;
use warnings;

sub TIESCALAR {
    my ($class, %args) = @_;
    return bless {
        on_read  => $args{on_read},
        on_write => $args{on_write},
        value    => $args{value} || 0,
    }, $class;
}

sub FETCH {
    my ($self) = @_;
    if ($self->{on_read}) {
        # allow the callback to intercept and provide a dynamic value
        return $self->{on_read}->($self->{value});
    }
    return $self->{value};
}

# invoked when the vm writes to this address
sub STORE {
    my ($self, $value) = @_;
    $self->{value} = $value;
    
    if ($self->{on_write}) {
        # trigger the side effect
        $self->{on_write}->($value);
    }
    return $self->{value};
}

1;
