package Holmgang::UV32;
# A number that computes as a perl with 32-bit integers does (ivsize 4, an NV
# of 8 bytes, use64bitint undef), on a perl with 64-bit integers (k75). What
# the random sources do with it is what they do on i686:
#
#   + - *        exact while the result fits a 32-bit UV; beyond, a double
#                (53 bits) -- perl falls back to NV arithmetic on overflow
#   & | ^ >> <<  on the UV of each operand: a value above 2**32 - 1 clamps to
#                2**32 - 1 (perl's U_V cast); << drops what leaves 32 bits
#   %            exact on integers (perl's fmod path for a double operand)
#   <=> bool ""  as the value
#
# Every other operator dies, so nothing silently computes in 64 bits.
use strict;
use warnings;
use Carp qw( croak );
use Exporter qw( import );

our @EXPORT_OK = qw( uv32 plain );

my $UV_MAX = 4294967295;

sub uv32 { my ($v) = @_; return bless \$v, __PACKAGE__ }

sub plain { my ($v) = @_; return ref $v eq __PACKAGE__ ? $$v : $v }

# a result beyond the 32-bit UV is a double
sub _nv { my ($v) = @_; return $v > $UV_MAX || $v < -2147483648 ? unpack( 'd', pack 'd', $v ) : $v }

# the UV a bit operator sees
sub _uv {
  my ($v) = @_;
  croak 'Holmgang::UV32: negative operand of a bit operator not emulated' if $v < 0;
  return $v > $UV_MAX ? $UV_MAX : int $v;
}

sub _args { my ( $x, $y, $swap ) = @_; my @v = ( plain($x), plain($y) ); return $swap ? reverse @v : @v }

use overload
  '+'   => sub { my ( $a, $b ) = _args(@_); uv32( _nv( $a + $b ) ) },
  '-'   => sub { my ( $a, $b ) = _args(@_); uv32( _nv( $a - $b ) ) },
  '*'   => sub { my ( $a, $b ) = _args(@_); uv32( _nv( $a * $b ) ) },
  '%'   => sub { my ( $a, $b ) = _args(@_); uv32( $a % $b ) },
  '&'   => sub { my ( $a, $b ) = _args(@_); uv32( _uv($a) & _uv($b) ) },
  '|'   => sub { my ( $a, $b ) = _args(@_); uv32( _uv($a) | _uv($b) ) },
  '^'   => sub { my ( $a, $b ) = _args(@_); uv32( _uv($a) ^ _uv($b) ) },
  '<<'  => sub { my ( $a, $b ) = _args(@_); uv32( ( _uv($a) << _uv($b) ) & $UV_MAX ) },
  '>>'  => sub { my ( $a, $b ) = _args(@_); uv32( _uv($a) >> _uv($b) ) },
  '<=>' => sub { my ( $a, $b ) = _args(@_); $a <=> $b },
  'bool' => sub { plain( $_[0] ) != 0 },
  '""'   => sub { ''.plain( $_[0] ) },
  '0+'   => sub { plain( $_[0] ) },
  'nomethod' => sub { croak 'Holmgang::UV32: operator '.$_[3].' not emulated' };

1;
