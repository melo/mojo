# Copyright (C) 2008-2009, Sebastian Riedel.

package Mojo::Server;

use strict;
use warnings;

use base 'Mojo::Base';

use Carp 'croak';
use Mojo::Loader;

use constant RELOAD => $ENV{MOJO_RELOAD} || 0;

__PACKAGE__->attr(
    app => sub {
        my $self = shift;

        # Load
        if (my $e = Mojo::Loader->load($self->app_class)) {
            die $e if ref $e;
        }

        return $self->app_class->new;
    }
);
__PACKAGE__->attr(app_class => sub { $ENV{MOJO_APP} ||= 'Mojo::HelloWorld' });
__PACKAGE__->attr(
    build_tx_cb => sub {
        sub {
            my $self = shift;

            # Reload
            if (RELOAD) {
                if (my $e = Mojo::Loader->reload) { warn $e }
                delete $self->{app};
            }

            return $self->app->build_tx_cb->($self->app);
          }
    }
);
__PACKAGE__->attr(
    continue_handler_cb => sub {
        sub {
            my ($self, $tx) = @_;
            if ($self->app->can('continue_handler')) {
                $self->app->continue_handler($tx);

                # Close connection to prevent potential race condition
                unless ($tx->res->code == 100) {
                    $tx->keep_alive(0);
                    $tx->res->headers->connection('Close');
                }
            }
            else { $tx->res->code(100) }
        };
    }
);
__PACKAGE__->attr(
    handler_cb => sub {
        sub { shift->app->handler(shift) }
    }
);

# Are you saying you're never going to eat any animal again? What about bacon?
# No.
# Ham?
# No.
# Pork chops?
# Dad, those all come from the same animal.
# Heh heh heh. Ooh, yeah, right, Lisa. A wonderful, magical animal.
sub run { croak 'Method "run" not implemented by subclass' }

1;
__END__

=head1 NAME

Mojo::Server - HTTP Server Base Class

=head1 SYNOPSIS

    use base 'Mojo::Server';

    sub run {
        my $self = shift;

        # Get a transaction
        my $tx = $self->build_tx_cb->($self);

        # Call the handler
        $tx = $self->handler_cb->($self);
    }

=head1 DESCRIPTION

L<Mojo::Server> is a HTTP server base class.

=head1 ATTRIBUTES

L<Mojo::Server> implements the following attributes.

=head2 C<app>

    my $app = $server->app;
    $server = $server->app(MojoSubclass->new);

=head2 C<app_class>

    my $app_class = $server->app_class;
    $server       = $server->app_class('MojoSubclass');

=head2 C<build_tx_cb>

    my $btx = $server->build_tx_cb;
    $server = $server->build_tx_cb(sub {
        my $self = shift;
        return Mojo::Transaction::Single->new;
    });

=head2 C<continue_handler_cb>

    my $handler = $server->continue_handler_cb;
    $server     = $server->continue_handler_cb(sub {
        my ($self, $tx) = @_;
    });

=head2 C<handler_cb>

    my $handler = $server->handler_cb;
    $server     = $server->handler_cb(sub {
        my ($self, $tx) = @_;
    });

=head1 METHODS

L<Mojo::Server> inherits all methods from L<Mojo::Base> and implements the
following new ones.

=head2 C<run>

    $server->run;

=cut
