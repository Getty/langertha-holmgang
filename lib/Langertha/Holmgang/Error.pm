package Langertha::Holmgang::Error;
# ABSTRACT: A loud refusal of input: the field path and the reason

use Moose;
use Carp qw( croak );
use Scalar::Util qw( blessed );
use overload '""' => sub { $_[0]->field.': '.$_[0]->reason }, fallback => 1;
use namespace::autoclean;

our $VERSION = '0.001';

has field => ( is => 'ro', required => 1 );

=attr field

Required. The refused field as a path, e.g. C<cases/c1.yaml: rules[0].regex>
or C<threshold.pass_rate>.

=cut

has reason => ( is => 'ro', required => 1 );

=attr reason

Required. Why the field was refused, for logs, authors and tests.

=cut

sub throw {
  my ( $class, $field, $reason ) = @_;
  croak $class->new( field => $field, reason => $reason );
}

=method throw

  Langertha::Holmgang::Error->throw( 'cases/c1.yaml: title' => 'text missing' );

Dies with a new refusal. As a string it reads C<field: reason>.

=cut

sub caught {
  my ( $class, $err ) = @_;
  return blessed $err && $err->isa($class) ? $err : undef;
}

=method caught

  my $refusal = Langertha::Holmgang::Error->caught($@) or die $@;

Returns C<$err> when it is a refusal, else C<undef>.

=cut

__PACKAGE__->meta->make_immutable;

=description

The refusal the loader, the structure checks and lint throw: not a program
error but input that does not hold, named by its field. Ported from
cai-platform's C<CAI::Platform::Refusal>.

=cut
