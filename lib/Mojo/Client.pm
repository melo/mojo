# Copyright (C) 2008, Sebastian Riedel.

package Mojo::Client;

use strict;
use warnings;

use base 'Mojo::Base';

use IO::Socket::INET;
use IO::Select;
use Mojo;
use Mojo::Loader;
use Mojo::Message::Response;

__PACKAGE__->attr(continue_timeout   => (chained => 1, default => 3));
__PACKAGE__->attr(keep_alive_timeout => (chained => 1, default => 15));
__PACKAGE__->attr(select_timeout     => (chained => 1, default => 5));

sub connect {
    my ($self, $tx) = @_;

    my $req  = $tx->req;
    my $host = $req->url->host;
    my $port = $req->url->port || 80;

    # Proxy
    if (my $proxy = $req->proxy) {
        $host = $proxy->host;
        $port = $proxy->port || 80;
    }

    # Try to get a cached connection
    my $connection = $self->withdraw_connection("$host:$port");
    $tx->kept_alive(1) if $connection;

    # Non blocking connect
    unless ($connection) {
        $connection = $self->_connect($host, $port);
        $tx->{connect_timeout} = time + 5;

    }
    $tx->connection($connection);
    $tx->state('connect');

    # Connection header
    unless ($req->headers->connection) {
        if ($tx->keep_alive || $tx->kept_alive) {
            $req->headers->connection('Keep-Alive');
        }
        else {
            $req->headers->connection('Close');
        }
    }

    # We identify ourself
    my $version = $Mojo::VERSION;
    $req->headers->user_agent("Mozilla/5.0 (compatible; Mojo/$version; Perl)")
      unless $req->headers->user_agent;

    return $tx;
}

sub _connect {
    my ($self, $host, $port) = @_;

    my $connection = IO::Socket::INET->new(
        Proto => 'tcp',
        Type  => SOCK_STREAM
    );

    # Non blocking
    $connection->blocking(0);

    my $address = sockaddr_in($port, scalar inet_aton($host));
    $connection->connect($address);

    return $connection;
}

sub disconnect {
    my ($self, $tx) = @_;

    my $req  = $tx->req;
    my $host = $req->url->host;
    my $port = $req->url->port || 80;
    my $peer = "$host:$port";

    # Deposit connection for later or kill socket
    $tx->keep_alive
      ? $self->deposit_connection($peer, $tx->connection)
      : $tx->connection(undef);

    return $tx;
}

sub deposit_connection {
    my ($self, $name, $connection, $timeout) = @_;

    # Drop connections after 30 seconds from queue
    $timeout ||= $self->keep_alive_timeout;

    $self->{_connections} ||= [];

    # Store socket if it is in a good state
    if ($self->test_connection($connection)) {
        push @{$self->{_connections}}, [$name, $connection, time + $timeout];
        return 1;
    }
    return 0;
}

# Marge, I'm going to Moe's. Send the kids to the neighbors,
# I'm coming back loaded!
sub process {
    my ($self, @transactions) = @_;

    # Parallel async io main loop... woot!
    while (1) { last if $self->spin(@transactions) }

    # Finished transactions should be returned first
    my @sorted;
    while (my $tx = shift @transactions) {
        $tx->is_finished ? unshift(@sorted, $tx) : push(@sorted, $tx);
    }

    return @sorted;
}

sub process_all {
    my ($self, @transactions) = @_;

    my @finished;
    my @progress = @transactions;

    # Process until all transactions are finished
    while (1) {
        my @done = $self->process(@progress);
        @progress = ();
        for my $tx (@done) {
            $tx->is_finished ? push(@finished, $tx) : push(@progress, $tx);
        }
        last unless @progress;
    }

    return @finished;
}

sub process_local {
    my ($self, $class, $tx) = @_;

    # Remote server
    if (my $authority = $ENV{MOJO_AUTHORITY}) {
        $tx->req->url->authority($authority);
        return $self->process($tx);
    }

    my $app = Mojo::Loader->load_build($class);

    $tx->req->fix_headers;
    my $new_tx = $app->handler($tx);
    $new_tx->res->fix_headers;

    return $new_tx;
}

sub _spin_prepare_transactions {
    my ($self, $transaction, @transactions) = @_;

    # Prepare
    my $done = 0;
    for my $tx (@transactions) {

        # Check for request/response errors
        $tx->error('Request error.')  if $tx->req->has_error;
        $tx->error('Response error.') if $tx->res->has_error;

        # Connect transaction
        $self->connect($tx) if $tx->is_state('start');

        # Check connect status
        if (!$tx->connection->connected) {
            if (time > $tx->{connect_timeout}) {
                $tx->error("Can't connect to peer before timeout");
                $done++;
            }
            next;
        }
        elsif ($tx->is_state('connect')) {

            # We might have to handle 100 Continue
            $tx->{_continue} = $self->continue_timeout
              if ($tx->req->headers->expect || '') =~ /100-continue/;

            # Ready for next state
            $tx->state('write_start_line');
            $tx->{_to_write} = $tx->req->start_line_length;
        }

        # Map
        my $name = $self->_socket_name($tx->connection);
        $transaction->{$name} = $tx;

        # Request start line written
        if ($tx->is_state('write_start_line')) {
            if ($tx->{_to_write} <= 0) {
                $tx->state('write_headers');
                $tx->{_offset}   = 0;
                $tx->{_to_write} = $tx->req->header_length;
            }
        }

        # Request headers written
        if ($tx->is_state('write_headers')) {
            if ($tx->{_to_write} <= 0) {
                $tx->{_continue}
                  ? $tx->state('read_continue')
                  : $tx->state('write_body');
                $tx->{_offset}   = 0;
                $tx->{_to_write} = $tx->req->body_length;
            }
        }

        # 100 Continue timeout
        if ($tx->is_state('read_continue')) {
            $tx->state('write_body') unless $tx->{_continue};
        }

        # Request body written
        if ($tx->is_state('write_body')) {
            $tx->state('read_response') if $tx->{_to_write} <= 0;
        }

        # Done?
        if ($tx->is_done) {
            $done++;

            # Disconnect
            $self->disconnect($tx) if $tx->is_done;
        }
    }

    return $done ? 1 : 0;
}

sub _get_next_chunk {
    my ($self, $tx) = @_;
    my $req = $tx->req;
    my $chunk;

    # Body
    $chunk = $req->get_body_chunk($tx->{_offset} || 0)
      if $tx->is_state('write_body');

    # Headers
    $chunk = $req->get_header_chunk($tx->{_offset} || 0)
      if $tx->is_state('write_headers');

    # Start line
    $chunk = $req->get_start_line_chunk($tx->{_offset} || 0)
      if $tx->is_state('write_start_line');

    return $chunk;
}

sub _check_expired_continue_request {
    my ($self, @transactions) = @_;

    # Make sure we don't wait longer than 5 seconds for a 100 Continue
    for my $tx (@transactions) {
        next unless $tx->{_continue};
        my $continue = $tx->{_continue};
        $tx->{_started} ||= time;
        $continue -= time - $tx->{_started};
        $continue = 0 if $continue < 0;
        $tx->{_continue} = $continue;
    }

    return;
}

sub _spin_network {
    my ($self, $transaction, @transactions) = @_;

    # Sort read/write sockets
    my @read_select;
    my @write_select;
    my $waiting = 0;
    for my $tx (@transactions) {

        # Not yet connected
        next if $tx->is_state('connect');

        my $connection = $tx->connection;

        # We always try to read as suggested by RFC 2616 for HTTP 1.1 clients
        push @read_select, $connection;

        # Write sockets
        if ($tx->is_state(qw/write_start_line write_headers write_body/)) {
            push @write_select, $connection;
        }

        $waiting++;
    }

    # No sockets ready yet
    return 0 unless $waiting;

    my $read_select  = @read_select  ? IO::Select->new(@read_select)  : undef;
    my $write_select = @write_select ? IO::Select->new(@write_select) : undef;

    # Select
    my ($read, $write, undef) =
      IO::Select->select($read_select, $write_select, undef,
        $self->select_timeout);

    $self->_check_expired_continue_request(@transactions);

    $read  ||= [];
    $write ||= [];

    # Make a random decision about reading or writing
    my $do = -1;
    $do = 0 if @$read;
    $do = 1 if @$write;
    $do = int(rand(3)) - 1 if @$read && @$write;

    # Write
    if ($do == 1) {

        my ($tx, $req, $chunk);

        # Check for content
        for my $connection (sort { int(rand(3)) - 1 } @$write) {

            my $name = $self->_socket_name($connection);
            $tx  = $transaction->{$name};
            $req = $tx->req;

            $chunk = $self->_get_next_chunk($tx);

            # Content generator ready?
            last if defined $chunk;
        }
        return 0 unless defined $chunk;

        # Write chunk
        my $written = $tx->connection->syswrite($chunk, length $chunk);
        $tx->error("Can't write request: $!") unless defined $written;
        return 1 if $tx->has_error;

        $tx->{_to_write} -= $written;
        $tx->{_offset} += $written;
    }

    # Read
    elsif ($do == 0) {

        my $connection = $read->[rand(@$read)];
        my $name       = $self->_socket_name($connection);
        my $tx         = $transaction->{$name};
        my $res        = $tx->res;

        # Early response, most likely an error
        $tx->state('read_response')
          if $tx->is_state(qw/write_start_line write_headers write_body/);

        my $buffer;
        my $read = $connection->sysread($buffer, 1024, 0);
        $tx->error("Can't read from socket: $!") unless defined $read;
        return 1 if $tx->has_error;

        # Read 100 Continue
        if ($tx->is_state('read_continue')) {
            $res->done if $read == 0;
            $res->parse($buffer);

            # We got a 100 Continue response
            if ($res->is_done && $res->code == 100) {
                $tx->res(Mojo::Message::Response->new);
                $tx->continued(1);
                $tx->{_continue} = 0;
            }

            # We got something else
            elsif ($res->is_done) {
                $tx->res($res);
                $tx->continued(0);
                $tx->done;
            }
        }

        # Read response
        elsif ($tx->is_state('read_response')) {
            $tx->done if $read == 0;
            $res->parse($buffer);
            $tx->done if $res->is_done;
        }
    }

    return 0;
}

sub spin {
    my ($self, @transactions) = @_;

    # Name to transaction map for fast lookups
    my %transaction;

    # Prepare
    my $done =
      $self->_spin_prepare_transactions(\%transaction, @transactions);
    return 1 if $done;

    return $self->_spin_network(\%transaction, @transactions);
}

sub test_connection {
    my ($self, $connection) = @_;

    # There are garbage bytes on the socket, or the peer closed the
    # connection if it is readable
    return IO::Select->new($connection)->can_read(0) ? 0 : 1;
}

sub withdraw_connection {
    my ($self, $match) = @_;

    # Shortcut
    return 0 unless $self->{_connections};

    my $result;
    my @connections;

    # Check all connections for name, timeout and if they are still alive
    for my $conn (@{$self->{_connections}}) {
        my ($name, $connection, $timeout) = @{$conn};
        if ($match eq $name) {
            $result = $connection
              if (time < $timeout) && $self->test_connection($connection);
        }
        else { push(@connections, $conn) if time < $timeout }
    }

    $self->{_connections} = \@connections;
    return $result;
}

sub _socket_name {
    my ($self, $s) = @_;

    # Temporary workaround for win32 weirdness
    my $n = '';
    for my $h ($s->sockaddr, $s->sockport, $s->peeraddr, $s->peerport) {
        $n .= unpack 'H*', $h;
    }
    return $n;
}

1;
__END__

=head1 NAME

Mojo::Client - Client

=head1 SYNOPSIS

    use Mojo::Client;
    use Mojo::Transaction;

    my $tx = Mojo::Transaction->new;
    $tx->req->method('GET');
    $tx->req->url->parse('http://cpan.org');

    my $client = Mojo::Client->new;
    $client->process($tx);

=head1 DESCRIPTION

L<Mojo::Client> is a full featured async io HTTP 1.1 client.

=head1 ATTRIBUTES

=head2 C<continue_timeout>

    my $timeout = $client->continue_timeout;
    $client     = $client->continue_timeout(5);

=head2 C<keep_alive_timeout>

    my $keep_alive_timeout = $client->keep_alive_timeout;
    $client                = $client->keep_alive_timeout(15);

=head2 C<select_timeout>

    my $timeout = $client->select_timeout;
    $client     = $client->select_timeout(5);

=head1 METHODS

L<Mojo::Client> inherits all methods from L<Mojo::Base> and implements the
following new ones.

=head2 C<connect>

    $tx = $client->connect($tx);

=head2 C<disconnect>

    $tx = $client->disconnect($tx);

=head2 C<deposit_connection>

    $client->deposit_connection($name, $connection, $timeout);

=head2 C<process>

    @transactions = $client->process(@transactions);

=head2 C<process_all>

    @transactions = $client->process_all(@transactions);

=head2 C<process_local>

    $tx = $client->process_local('MyApp', $tx);

Returns a processed L<Mojo::Transaction> object.
Expects a Mojo application class name and a L<Mojo::Transaction> object as
arguments.

=head2 C<spin>

    my $done = $client->spin(@transactions);

=head2 C<test_connection>

    my $alive = $client->test_connection($connection);

=head2 C<withdraw_connection>

    my $connection = $client->withdraw_connection($name);

=cut
