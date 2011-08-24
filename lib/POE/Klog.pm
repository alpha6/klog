package POE::Klog;

use warnings;
use strict;
require Carp;

use POE;
use POE::Component::IRC::Plugin qw( :ALL );
use POE::Component::IRC::Common qw( parse_user );
use DBI;

require Klog::Model;
require Klog::Config;
require Class::Load;

our $VERSION = 0.03;

sub new {
    my $class = shift;
    my $self  = {@_};

    $self->{config} ||= Klog::Config->load;
    $self->{model}
      ||= Klog::Model->new(config => $self->{config})->build('Log');

    return bless $self, $class;
}

sub _start {
    my ($kernel, $self) = @_[KERNEL, OBJECT];
    $self->{SESSION_ID} = $_[SESSION]->ID();

    return;
}

sub _shutdown {
    my ($kernel, $self) = @_[KERNEL, OBJECT];
    $kernel->alarm_remove_all();
    $kernel->refcount_decrement($self->{SESSION_ID}, __PACKAGE__);
}

sub _channels {
    my $self = shift;
    return $self->{channels} if $self->{channels};

    my $string = $self->{config}{irc}{channels};
    my @channels = grep $_, split /\s*,\s*/, $string;

    $self->{channels} = \@channels;
}

# Required entry point for PoCo-POE
sub PCI_register {
    my $self = shift;
    my ($irc) = @_;
    $self->SUPER::PCI_register(@_);

    # Register events we are interested in
    $irc->plugin_register($self, 'SERVER',
        qw(public mode quit join part ctcp_action 353 irc_001));
    $self->{SESSION_ID} =
      POE::Session->create(object_states => [$self => [qw(_start _shutdown)]])
      ->ID();

    # Return success
    return 1;
}

sub irc_001 {
    my $self   = $_[0];
    my $sender = $_[SENDER];

    my $irc = $sender->get_heap();

    print "Connected to ", $irc->server_name(), "\n";

    $irc->yield(join => $_) for @{$self->_channels};
    return 1;
}

# Required exit point for PoCo-POE
sub PCI_unregister {
    my ($self, $irc) = @_;
    $poe_kernel->call($self->{SESSION_ID} => '_shutdown');

    return 1;
}


sub S_public {
    my ($self, $irc) = splice @_, 0, 2;

    my $sender   = ${$_[0]};
    my $channels = ${$_[1]};
    my $msg      = ${$_[2]};

    # $_[2] contains list of channels, common for Klog and quitter.
    # But in strange format :\
    for my $chan (@{$channels}) {
        $self->Log('public', $chan, $sender, $msg);
    }

    # Return an exit code
    return PCI_EAT_NONE;
}

sub S_ctcp_action {
    my ($self, $irc) = splice @_, 0, 2;

    my ($sender, $chans, $msg) = @_;
    foreach my $ch (grep /^#/, @{${$chans}}) {
        $self->Log('action', $ch, ${$sender}, ${$msg});
    }
    return PCI_EAT_NONE;
}

sub S_quit {
    my ($self, $irc) = splice @_, 0, 2;
    my $sender = ${$_[0]};
    my $msg    = ${$_[1]};

    # list of channels that are common for bot and quitter
    for (@{${$_[2]}[0]}) {
        $self->Log('quit', $_, $sender, $msg);
    }
    return PCI_EAT_NONE;
}

# NAMES
sub S_353 {
    my ($self, $irc) = splice @_, 0, 2;
    my ($x, $raw, $message) = @_;

    my $chan = $$message->[1];

    unless (exists($irc->{'awaiting_names'}{$chan})
        && $irc->{'awaiting_names'}{$chan})
    {
        return PCI_EAT_NONE;
    }

    delete $irc->{'awaiting_names'}{$chan};

    $self->Log('names', $chan, 'server', $$message->[2]);

    PCI_EAT_NONE;
}

# join and part (and maybe quit) are simirar
sub S_join {
    my ($self, $irc) = @_;
    my ($joiner, $user, $host) = parse_user(${$_[2]});
    my $chan = ${$_[3]};

    unshift @_, 'join';
    &jp;

    if ($joiner eq $irc->nick_name) {
        $irc->{'awaiting_names'}{$chan} = 1;
    }

    PCI_EAT_NONE;
}

sub S_part { unshift @_, 'part'; &jp }

sub jp {
    my ($event, $self, $irc) = splice @_, 0, 3;
    my ($sender, $chan, $msg) = @_;

# but there is some diff
    $self->Log($event, ${$chan}, ${$sender},
        $event ne 'join' ? ${$msg} : undef);
}

sub S_mode {
    my ($self, $irc) = splice @_, 0, 2;
    my $user = ${$_[0]};
    my $chan = ${$_[1]};
    my $mode = ${$_[2]};
    my $arg  = $_[3];

# should me tested. Do we really need this check here
    if ($chan =~ /^#/) {
        $self->Log('mode', $chan, $user, $mode, $arg);
    }
    return PCI_EAT_NONE;
}


# Log takes event-type, channel and event-specific args
# and put it all into db
sub Log {
    my $self = shift;
    my $line = {};
    @{$line}{qw/type target sender message/} = splice @_, 0, 4;

    $line->{nickname} = parse_user($line->{sender});

    $self->{model}->write_event($line);
}

1;

__END__

=head1 NAME

POE::Klog - [One line description of module's purpose here]


=head1 SYNOPSIS

    use POE::Klog;


=head1 DESCRIPTION

POE::Klog

=head1 ATTRIBUTES

L<POE::Klog> implements following attributes:

=head1 LICENCE AND COPYRIGHT

Copyright (C) 2011, Yaroslav Korshak.

This module is free software; you can redistribute it and/or
modify it under the same terms as Perl itself. See L<perlartistic>.
