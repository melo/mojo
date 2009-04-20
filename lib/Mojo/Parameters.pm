# Copyright (C) 2008-2009, Sebastian Riedel.

package Mojo::Parameters;

use strict;
use warnings;

use base 'Mojo::Base';
use overload '""' => sub { shift->to_string }, fallback => 1;

use Mojo::ByteStream;
use Mojo::URL;

__PACKAGE__->attr(pair_separator => (chained => 1, default => '&'));
__PACKAGE__->attr(params => (chained => 1, default => sub { [] }));

# Yeah, Moe, that team sure did suck last night. They just plain sucked!
# I've seen teams suck before,
# but they were the suckiest bunch of sucks that ever sucked!
# HOMER!
# I gotta go Moe my damn weiner kids are listening.
sub new {
    my $self = shift->SUPER::new();

    # Hash/Array
    if (defined $_[1]) { $self->append(@_) }

    # String
    else { $self->parse(@_) }

    return $self;
}

sub append {
    my $self = shift;

    for (@_) {
        my $value = "$_";

        # We replace whitespace with "+"
        $value =~ s/\ /\+/g;

        # *( pchar / "/" / "?" ) with the exception of ";", "&" and "="
        $value =
          Mojo::ByteStream->new($value)->url_escape($Mojo::URL::PARAM)
          ->to_string;

        # Append
        push @{$self->params}, $value;
    }

    return $self;
}

sub clone {
    my $self  = shift;
    my $clone = Mojo::Parameters->new;
    $clone->pair_separator($self->pair_separator);
    $clone->params([@{$self->params}]);
    return $clone;
}

sub merge {
    my $self = shift;
    push @{$self->params}, @{$_->params} for @_;
    return $self;
}

sub param {
    my $self = shift;
    my $name = shift;

    # We replace whitespace with "+"
    $name =~ s/\ /\+/g;

    # *( pchar / "/" / "?" ) with the exception of ";", "&" and "="
    $name = Mojo::ByteStream->new($name)->url_escape($Mojo::URL::PARAM);

    # Cleanup
    $self->remove($name) if defined $_[0];

    # Append
    for my $value (@_) {
        $self->append($name, $value);
    }

    # List
    my @values;
    my $params = $self->params;
    for (my $i = 0; $i < @$params; $i += 2) {
        push @values, $params->[$i + 1] if $params->[$i] eq $name;
    }

    # Unescape
    for (my $i = 0; $i <= $#values; $i++) {

        # We replace "+" with whitespace
        $values[$i] =~ s/\+/\ /g if $values[$i];

        # *( pchar / "/" / "?" ) with the exception of ";", "&" and "="
        $values[$i] =
          Mojo::ByteStream->new($values[$i])->url_unescape->to_string;
    }

    return wantarray ? @values : $values[0];
}

sub parse {
    my $self   = shift;
    my $string = shift;

    # Shortcut
    return $self unless defined $string;

    # Clear
    $self->params([]);

    # Detect query string without key/value pairs
    if ($string !~ /\=/) {
        $self->params([$string, undef]);
        return $self;
    }

    # Detect pair separator for reconstruction
    $self->pair_separator(';') if $string =~ /\;/ && $string !~ /\&/;

    # W3C suggests to also accept ";" as a separator
    for my $pair (split /[\&\;]+/, $string) {

        $pair =~ /^([^\=]*)(?:=(.*))?$/;

        my $name  = $1;
        my $value = $2;

        push @{$self->params}, $name, $value;
    }

    return $self;
}

sub remove {
    my ($self, $name) = @_;

    # We replace whitespace with "+"
    $name =~ s/\ /\+/g;

    # *( pchar / "/" / "?" ) with the exception of ";", "&" and "="
    $name = Mojo::ByteStream->new($name)->url_escape($Mojo::URL::PARAM);

    # Remove
    my $params = $self->params;
    for (my $i = 0; $i < @$params;) {
        if ($params->[$i] eq $name) {
            splice @$params, $i, 2;
        }
        else {
            $i += 2;
        }
    }
    $self->params($params);

    return $self;
}

sub to_hash {
    my $self   = shift;
    my $params = $self->params;

    # Format
    my %params;
    for (my $i = 0; $i < @$params; $i += 2) {
        my $name  = $params->[$i];
        my $value = $params->[$i + 1];

        # We replace "+" with whitepsace
        $name =~ s/\+/\ /g;
        $value =~ s/\+/\ /g if $value;

        # Unescape
        $name  = Mojo::ByteStream->new($name)->url_unescape->to_string;
        $value = Mojo::ByteStream->new($value)->url_unescape->to_string;

        # Array
        if (exists $params{$name}) {
            $params{$name} = [$params{$name}]
              unless ref $params{$name} eq 'ARRAY';
            push @{$params{$name}}, $value;
        }

        # String
        else { $params{$name} = $value }
    }

    return \%params;
}

sub to_string {
    my $self   = shift;
    my $params = $self->params;

    # Shortcut
    return undef unless @{$self->params};

    # Format
    my @params;
    for (my $i = 0; $i < @$params; $i += 2) {
        my $name  = $params->[$i];
        my $value = $params->[$i + 1];

        # We replace whitespace with "+"
        $name =~ s/\ /\+/g;

        # Value is optional
        if (defined $value) {

            # We replace whitespace with "+"
            $value =~ s/\ /\+/g;

            # *( pchar / "/" / "?" ) with the exception of ";", "&" and "="
            $value =
              Mojo::ByteStream->new($value)->url_escape($Mojo::URL::PARAM);

            # *( pchar / "/" / "?" ) with the exception of ";", "&" and "="
            $name =
              Mojo::ByteStream->new($name)->url_escape($Mojo::URL::PARAM);
        }

        # No value
        else {

            # *( pchar / "/" / "?" )
            $name =
              Mojo::ByteStream->new($name)->url_escape($Mojo::URL::PCHAR);
        }

        push @params, defined $value ? "$name=$value" : "$name";
    }

    my $separator = $self->pair_separator;
    return join $separator, @params;
}

1;
__END__

=head1 NAME

Mojo::Parameters - Parameters

=head1 SYNOPSIS

    use Mojo::Parameters;

    my $params = Mojo::Parameters->new(foo => 'bar', baz => 23);
    print "$params";

=head1 DESCRIPTION

L<Mojo::Parameters> is a container for form parameters.

=head1 ATTRIBUTES

=head2 C<pair_separator>

    my $separator = $params->pair_separator;
    $params       = $params->pair_separator(';');

=head2 C<params>

    my $parameters = $params->params;
    $params        = $params->params(foo => 'b;ar', baz => 23);

=head1 METHODS

L<Mojo::Parameters> inherits all methods from L<Mojo::Base> and implements
the following new ones.

=head2 C<new>

    my $params = Mojo::Parameters->new;
    my $params = Mojo::Parameters->new('foo=b%3Bar&baz=23');
    my $params = Mojo::Parameters->new(foo => 'b;ar', baz => 23);

=head2 C<append>

    $params = $params->append(foo => 'ba;r');

=head2 C<clone>

    my $params2 = $params->clone;

=head2 C<merge>

    $params = $params->merge($params2, $params3);

=head2 C<param>

    my $foo = $params->param('foo');
    my @foo = $params->param('foo');
    my $foo = $params->param(foo => 'ba;r');

=head2 C<parse>

    $params = $params->parse('foo=b%3Bar&baz=23');

=head2 C<remove>

    $params = $params->remove('foo');

=head2 C<to_hash>

    my $hash = $params->to_hash;

=head2 C<to_string>

    my $string = $params->to_string;

=cut
