package Langertha::Holmgang::ToolSchema;
# ABSTRACT: The JSON Schema subset of tool parameters, checked at load and per call

use strict;
use warnings;
use utf8;

use Exporter qw( import );
use JSON::MaybeXS ();
use Langertha::Holmgang::Error;
use Langertha::Holmgang::Expectation qw( same_scalar );

our $VERSION = '0.001';

our @EXPORT_OK = qw( check_schema schema_errors );

# the subset of JSON Schema a tool's parameters may use; a true constant
our @SCHEMA_KEYS = qw( type required properties items enum const pattern
  minLength maxLength minimum maximum minItems maxItems description title );

my %TYPE = map { $_ => 1 } qw( object array string number integer boolean null );

=synopsis

  use Langertha::Holmgang::ToolSchema qw( check_schema schema_errors );

  check_schema( $tool->{parameters}, 'suite.yaml: tools[0].parameters' );   # at load

  my @errors = schema_errors( $args, $tool->{parameters} );                 # per call
  # ( '$.dst: fehlt', '$.metric: erwartet integer' )

=description

Tool parameters are a subset of JSON Schema: the keys C<type>, C<required>,
C<properties>, C<items>, C<enum>, C<const>, C<pattern>, C<minLength>,
C<maxLength>, C<minimum>, C<maximum>, C<minItems>, C<maxItems>,
C<description>, C<title>, nested through C<properties> and C<items>.

L</check_schema> is the shape check of the loader: anything else is a loud
L<Langertha::Holmgang::Error>. L</schema_errors> checks the arguments of one
call; its texts go to the model (after C<Fehler: Argumente passen nicht zum
Schema:>) and are therefore German, as the suites expect them. Integers and
numbers may arrive as text (C<"3">), as many models send them. C<const> is
accepted at load but not checked per call, as in cai-platform.

=cut

sub _refuse { Langertha::Holmgang::Error->throw(@_) }

=func check_schema

  check_schema( $schema, $field );

Refuses an unknown key, an unknown C<type>, an invalid C<pattern>, a
C<properties> that is not a hash and a C<required> or C<enum> that is not a
list — recursively, with the field path. Returns the schema.

=cut

sub check_schema {
  my ( $s, $field ) = @_;
  _refuse( $field, 'not a hash' ) unless ref $s eq 'HASH';
  for my $k ( sort keys %$s ) {
    _refuse( $field.'.'.$k, 'unknown key' ) unless grep { $_ eq $k } @SCHEMA_KEYS;
  }
  if ( exists $s->{type} ) {
    _refuse( $field.'.type', 'unknown type' ) unless !ref $s->{type} && $TYPE{ $s->{type} // '' };
  }
  if ( exists $s->{pattern} ) {
    my $p = $s->{pattern};
    _refuse( $field.'.pattern', 'text missing' ) if !defined $p || ref $p || !length $p;
    _refuse( $field.'.pattern', 'invalid regular expression' ) unless eval { qr/$p/; 1 };
  }
  if ( exists $s->{properties} ) {
    _refuse( $field.'.properties', 'not a hash' ) unless ref $s->{properties} eq 'HASH';
    check_schema( $s->{properties}{$_}, $field.'.properties.'.$_ ) for sort keys %{ $s->{properties} };
  }
  check_schema( $s->{items}, $field.'.items' ) if exists $s->{items};
  _refuse( $field.'.required', 'not a list' ) if exists $s->{required} && ref $s->{required} ne 'ARRAY';
  _refuse( $field.'.enum', 'not a list' )     if exists $s->{enum}     && ref $s->{enum} ne 'ARRAY';
  return $s;
}

=func schema_errors

  my @errors = schema_errors( $data, $schema );

The violations of C<$data> against C<$schema>, each with its path from C<$>
(C<$.dst>, C<$.peers[1]>); empty when the data fit.

=cut

sub schema_errors {
  my ( $d, $s, $at ) = @_;
  $at //= '$';
  return () unless ref $s eq 'HASH';
  my @e;
  if ( defined( my $t = $s->{type} ) ) {
    my $ok
      = $t eq 'object'  ? ref $d eq 'HASH'
      : $t eq 'array'   ? ref $d eq 'ARRAY'
      : $t eq 'null'    ? !defined $d
      : $t eq 'boolean' ? JSON::MaybeXS::is_bool($d)
      : $t eq 'integer' ? ( defined $d && !ref $d && "$d" =~ /\A-?\d+\z/ )
      : $t eq 'number'  ? ( defined $d && !ref $d && "$d" =~ /\A-?\d+(?:\.\d+)?\z/ )
      : $t eq 'string'  ? ( defined $d && !ref $d )
      :                   0;
    return ( $at.': erwartet '.$t ) unless $ok;
  }
  if ( $s->{enum} && !grep { same_scalar( $d, $_ ) } @{ $s->{enum} } ) {
    push @e, $at.': erlaubt sind '.join( ', ', @{ $s->{enum} } );
  }
  if ( defined $d && !ref $d ) {
    push @e, $at.': zu kurz' if defined $s->{minLength} && length $d < $s->{minLength};
    push @e, $at.': zu lang' if defined $s->{maxLength} && length $d > $s->{maxLength};
    push @e, $at.': passt nicht zu '.$s->{pattern} if defined $s->{pattern} && $d !~ /$s->{pattern}/;
    if ( "$d" =~ /\A-?\d+(?:\.\d+)?\z/ ) {
      push @e, $at.': kleiner als '.$s->{minimum} if defined $s->{minimum} && $d < $s->{minimum};
      push @e, $at.': größer als '.$s->{maximum}  if defined $s->{maximum} && $d > $s->{maximum};
    }
  }
  if ( ref $d eq 'HASH' ) {
    for my $k ( @{ $s->{required} || [] } ) {
      push @e, $at.'.'.$k.': fehlt' unless exists $d->{$k};
    }
    my $p = $s->{properties} || {};
    for my $k ( sort keys %$p ) {
      push @e, schema_errors( $d->{$k}, $p->{$k}, $at.'.'.$k ) if exists $d->{$k};
    }
  }
  if ( ref $d eq 'ARRAY' ) {
    push @e, $at.': zu wenige Einträge' if defined $s->{minItems} && @$d < $s->{minItems};
    push @e, $at.': zu viele Einträge'  if defined $s->{maxItems} && @$d > $s->{maxItems};
    if ( $s->{items} ) {
      push @e, schema_errors( $d->[$_], $s->{items}, $at.'['.$_.']' ) for 0 .. $#$d;
    }
  }
  return @e;
}

1;
