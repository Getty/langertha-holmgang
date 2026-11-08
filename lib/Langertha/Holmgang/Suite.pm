package Langertha::Holmgang::Suite;
# ABSTRACT: A suite: head, tools, defaults and its cases in load order

use Moose;
use namespace::autoclean;

our $VERSION = '0.001';

=synopsis

  my $suite = Langertha::Holmgang::Loader->new->load('/srv/suites/example-lamp');

  $suite->id;          # 'example-lamp'
  $suite->topic;       # 'sonstiges' without one
  $suite->cases;       # [ Langertha::Holmgang::Case, … ] in file-name order
  $suite->checksum;    # sha256 over the files and the generated texts
  $suite->case('c1');  # one case by id

=description

The head of suite format 2 (F<suite.yaml>) with its cases. Field names are
format 2's (ADR 0005); C<format: 2> is a property of the file, not of the
structure. Built by L<Langertha::Holmgang::Structure> through the loader or
the DSL.

=cut

has id => ( is => 'ro', required => 1 );

=attr id

Required. C<[a-z0-9-]>, the directory name in format 2.

=cut

has topic => ( is => 'ro', default => 'sonstiges' );

=attr topic

The axis of every evaluation; C<sonstiges> without one.

=cut

has $_ => ( is => 'ro' ) for qw( version title description license source threshold repeat checksum );

=attr version

The suite's version, an integer from 1 up; format 2 requires it.

=attr title

Required. The suite's title, a non-empty text.

=attr description

Optional free text describing the suite, or C<undef>.

=attr license

Optional license text of the suite, or C<undef>.

=attr source

C<{ title, authors, license, url, location }>.

=attr threshold

C<{ pass_rate, pass_k }> (each optional, 0..1) or C<undef>.

=attr repeat

How often a run repeats the suite by default (1..100), or C<undef>.

=attr checksum

SHA-256 (hex) over the file names and bytes of F<suite.yaml> and every case
file, plus the generated texts — the same value cai-platform computes as its
C<digest>.

=cut

has defaults => ( is => 'ro', default => sub { {} } );

=attr defaults

C<system>, C<temperature>, C<max_tokens>, C<max_turns> as written.

=cut

has tools => ( is => 'ro', default => sub { [] } );

=attr tools

The tools as written in F<suite.yaml>, in file order.

=cut

has cases => ( is => 'ro', default => sub { [] } );

=attr cases

The L<Langertha::Holmgang::Case> objects in load order.

=cut

sub case {
  my ( $self, $id ) = @_;
  my ( $c ) = grep { $_->id eq ( $id // '' ) } @{ $self->cases };
  return $c;
}

=method case

  my $case = $suite->case('c1');

The case with this id, or C<undef>.

=cut

__PACKAGE__->meta->make_immutable;
