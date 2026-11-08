package Langertha::Holmgang::Case;
# ABSTRACT: One case of a suite: its own format 2 values and what derives from them

use Moose;
use namespace::autoclean;
use utf8;

use JSON::MaybeXS ();
use Langertha::Holmgang::Haystack;
use Langertha::Holmgang::Simulators;

our $VERSION = '0.001';

# built-in fallbacks of the settings, below the suite's defaults; a true constant
my %DEFAULT = ( temperature => 0, max_tokens => 2000, max_turns => 12, system => '' );

my $JSON = JSON::MaybeXS->new( utf8 => 0, canonical => 1, allow_nonref => 1 );

=synopsis

  my $case = $suite->cases->[0];

  $case->id;                         # 'c1'
  $case->rules;                      # as format 2 writes them
  $case->effective('max_turns');     # own value, else the suite's default, else 12
  $case->prompt_messages;            # [ { role, content } ] — generated text resolved, no untrusted mark
  $case->initial_state;              # the state the world starts from
  $case->tier;                       # '48k' from the tag stufe-48k, or undef
  $case->is_hard;                    # tag injection or verbot
  $case->has_untrusted;              # a message or state hash marked untrusted
  $case->no_tool;                    # solution: [] — the "no tool" family

=description

A case holds B<only its own values>, exactly as format 2 writes them (ADR
0005): rules, handlers, expectations, tool calls and the state stay plain
hashes and lists, generated content (C<< { generate => … } >> or a list of
parts) stays the spec. A key the case does not have is C<undef>. What derives
from them — the effective settings, the resolved texts, the length tier, the
hard and untrusted marks — comes from methods, never copied in, so an export
writes back what was written.

Cases are built by L<Langertha::Holmgang::Structure>, which checks the shape
first; the loader and the DSL both go through it.

=cut

has id => ( is => 'ro', required => 1 );

=attr id

Required. C<[a-z0-9-]>, the file name without C<.yaml> in format 2.

=cut

has $_ => ( is => 'ro' ) for qw(
  title tags difficulty system messages state observe rules solution
  alternatives wrong_solutions temperature max_tokens max_turns source weight
);

=attr title

Required. The case's title, a non-empty text.

=attr tags

A list of texts, or C<undef>; L</tier> and L</is_hard> read them through
L</tag_list>.

=attr difficulty

C<leicht>, C<mittel> or C<schwer>, as format 2 writes it.

=attr system

The case's own system prompt; L</effective> falls back to the suite's.

=attr messages

C<[ { role, content, untrusted } ]> as written; C<content> may be a generate
spec. What goes out is L</prompt_messages>.

=attr state

The world as written (devices keyed by host name). The world starts from
L</initial_state>.

=attr observe

The observations as written: C<[ { match, when, output, error } ]>, answers to
diagnostic commands that may depend on the state but never change it.

=attr rules

The rules as written; the grader checks them on the end state, and a case
passes when every required one is met.

=attr solution

A list of C<{ tool, args }>; C<[]> in the "no tool" family.

=attr alternatives

Other correct paths, C<[ { title, calls } ]>; lint replays each and it must
pass like the reference solution.

=attr wrong_solutions

C<[ { title, calls } ]>.

=attr temperature

The case's own temperature (0..2) or C<undef>; L</effective> falls back to the
suite's default, else 0.

=attr max_tokens

The case's own token limit per turn (1..200000) or C<undef>; L</effective>
falls back to the suite's default, else 2000.

=attr max_turns

The case's own turn limit (1..50) or C<undef>; L</effective> falls back to
the suite's default, else 12.

=attr source

Where the case comes from, C<{ title, authors, license, url, location }>, or
C<undef>.

=attr weight

Optional positive number (ADR 0005); L</effective_weight> is 1 without it.

=cut

has tools => ( is => 'ro', default => sub { [] } );

=attr tools

The suite's tools, in the order they are offered to the model (by name, as in
cai-platform). Context, not a value of the case.

=cut

has defaults => ( is => 'ro', default => sub { {} } );

=attr defaults

The suite's C<defaults> (C<system>, C<temperature>, C<max_tokens>,
C<max_turns>). Context, not a value of the case.

=cut

has simulators => (
  is      => 'ro',
  lazy    => 1,
  builder => '_build_simulators',
);
sub _build_simulators { Langertha::Holmgang::Simulators->new }

=attr simulators

The simulator registry that prepares the initial state.

=cut

has haystack => (
  is      => 'ro',
  lazy    => 1,
  builder => '_build_haystack',
);
sub _build_haystack { Langertha::Holmgang::Haystack->new }

=attr haystack

The generator of long content (L<Langertha::Holmgang::Haystack>).

=cut

has initial_state => (
  is      => 'ro',
  lazy    => 1,
  builder => '_build_initial_state',
);

sub _build_initial_state {
  my ( $self ) = @_;
  my $state = $JSON->decode( $JSON->encode( $self->state // {} ) );
  for my $dev ( sort keys %$state ) {
    my $files = ref $state->{$dev} eq 'HASH' ? $state->{$dev}{files} : undef;
    next unless ref $files eq 'HASH';
    for my $p ( sort keys %$files ) {
      my $f = $files->{$p};
      next unless ref $f eq 'HASH' && ( ref $f->{content} eq 'HASH' || ref $f->{content} eq 'ARRAY' );
      $f->{content} = $self->haystack->resolve( $f->{content}, 'state.'.$dev.'.files.'.$p.'.content' );
    }
  }
  $self->simulators->prepare($state);
  return $state;
}

=attr initial_state

The state the world starts from: a copy of L</state> with generated file
contents resolved, prepared by each device's simulator (the running values a
service read from its files at boot). Built when first needed; the structure
check hands it in after checking it.

=cut

has prompt_messages => (
  is      => 'ro',
  lazy    => 1,
  builder => '_build_prompt_messages',
);

sub _build_prompt_messages {
  my ( $self ) = @_;
  my $i = 0;
  return [ map {
    my $c = $_->{content};
    $c = $self->haystack->resolve( $c, 'messages['.$i.'].content' ) if ref $c;
    $i++;
    +{ role => $_->{role}, content => $c };
  } @{ $self->messages || [] } ];
}

=attr prompt_messages

The messages as they go to the model: C<role> and C<content> only, generated
content resolved, the C<untrusted> mark left out.

=cut

sub effective {
  my ( $self, $key ) = @_;
  my $own = $self->can($key) && exists $DEFAULT{$key} ? $self->$key : undef;
  return $own // $self->defaults->{$key} // $DEFAULT{$key};
}

=method effective

  $case->effective('temperature');

The value of a setting (C<system>, C<temperature>, C<max_tokens>,
C<max_turns>): the case's own, else the suite's C<defaults>, else the
built-in one (C<''>, C<0>, C<2000>, C<12>).

=cut

sub effective_weight { $_[0]->weight // 1 }

=method effective_weight

The case's weight, 1 without one.

=cut

sub tag_list { @{ $_[0]->tags || [] } }

=method tag_list

The tags as a list.

=cut

sub tier {
  my ( $self ) = @_;
  for ( $self->tag_list ) { return $1 if /\Astufe-(\d+k)\z/ }
  return;
}

=method tier

The length tier from the tag C<stufe-E<lt>tierE<gt>> (C<16k>, C<48k>, C<96k>,
C<160k>), or C<undef>.

=cut

sub is_hard {
  my ( $self ) = @_;
  return ( grep { $_ eq 'injection' || $_ eq 'verbot' } $self->tag_list ) ? 1 : 0;
}

=method is_hard

True for a case tagged C<injection> or C<verbot>: one forbidden call fails the
suite's verdict.

=cut

sub has_untrusted {
  my ( $self ) = @_;
  return 1 if grep { ref $_ eq 'HASH' && $_->{untrusted} } @{ $self->messages || [] };
  return $self->_marked( $self->state ) ? 1 : 0;
}

# a hash with untrusted: true anywhere in the state
sub _marked {
  my ( $self, $d ) = @_;
  if ( ref $d eq 'HASH' ) {
    my $u = $d->{untrusted};
    return 1 if $u && ( !ref $u || JSON::MaybeXS::is_bool($u) );
    return ( grep { $self->_marked($_) } values %$d ) ? 1 : 0;
  }
  return ( grep { $self->_marked($_) } @$d ) ? 1 : 0 if ref $d eq 'ARRAY';
  return 0;
}

=method has_untrusted

True when a message or a hash in the state is marked C<untrusted>: the case
carries foreign content, and C<injection_held> is defined for it.

=cut

sub no_tool {
  my ( $self ) = @_;
  return ref $self->solution eq 'ARRAY' && !@{ $self->solution } ? 1 : 0;
}

=method no_tool

True in the "no tool" family: C<solution: []>, where doing nothing is right.

=cut

__PACKAGE__->meta->make_immutable;
