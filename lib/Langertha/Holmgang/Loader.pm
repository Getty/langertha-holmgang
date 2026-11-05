package Langertha::Holmgang::Loader;
# ABSTRACT: Loads suite format 2 from search directories, lints every case

use Moose;
use namespace::autoclean;
use utf8;

use Digest::SHA ();
use Encode ();
use Path::Tiny qw( path );
use YAML::XS ();
use Langertha::Holmgang::Error;
use Langertha::Holmgang::Grader;
use Langertha::Holmgang::Haystack;
use Langertha::Holmgang::Lint;
use Langertha::Holmgang::Runner;
use Langertha::Holmgang::Simulators;
use Langertha::Holmgang::Structure;
use Langertha::Holmgang::Suite;

our $VERSION = '0.001';

=synopsis

  my $loader = Langertha::Holmgang::Loader->new;

  my $suite = $loader->load('/srv/suites/example-lamp');   # a Langertha::Holmgang::Suite

  my $list = $loader->list( '/srv/suites:/data/suites' );
  # [ { id, version, title, description, topic, cases, tools, checksum, error }, … ]

  my $dir = $loader->locate( '/srv/suites:/data/suites', 'example-lamp' );
  my @ids = $loader->select_suites( $list, topics => ['netzwerk'], suites => ['example-lamp'] );

=description

A suite in format 2 is a directory with F<suite.yaml> (head, defaults, tools)
and one file per case under F<cases/>, loaded in file-name order. Each file
goes through the shape checks of L<Langertha::Holmgang::Structure>, then each
case through L<Langertha::Holmgang::Lint>: a case that does not hold does not
load, and the whole suite with it. Every refusal is a
L<Langertha::Holmgang::Error> naming the field — C<format>, C<id>,
C<suite.yaml: tools[0].name>, C<cases/c1.yaml: rules[0].regex>.

The suite's checksum is SHA-256 over C<suite.yaml>, each case file (name and
bytes) and each generated text — computed exactly as cai-platform computes its
C<digest>, so a suite has the same value in both.

=cut

has simulators => (
  is      => 'ro',
  lazy    => 1,
  builder => '_build_simulators',
);
sub _build_simulators { Langertha::Holmgang::Simulators->new }

=attr simulators

The simulator registry, shared by the structure checks, lint and the cases.

=cut

has haystack => (
  is      => 'ro',
  lazy    => 1,
  builder => '_build_haystack',
);
sub _build_haystack { Langertha::Holmgang::Haystack->new }

=attr haystack

The generator of long content, shared with the cases.

=cut

has structure => (
  is      => 'ro',
  lazy    => 1,
  builder => '_build_structure',
);
sub _build_structure {
  my ( $self ) = @_;
  return Langertha::Holmgang::Structure->new( simulators => $self->simulators, haystack => $self->haystack );
}

=attr structure

The L<Langertha::Holmgang::Structure> the files go through.

=cut

has lint => (
  is      => 'ro',
  lazy    => 1,
  builder => '_build_lint',
);
sub _build_lint {
  my ( $self ) = @_;
  return Langertha::Holmgang::Lint->new(
    grader    => Langertha::Holmgang::Grader->new( simulators => $self->simulators ),
    mock_runs => Langertha::Holmgang::Runner->lint_mock_runs,
  );
}

=attr lint

The L<Langertha::Holmgang::Lint> every case passes, by default with the two
mock runs of L<Langertha::Holmgang::Runner/lint_mock_runs> (replaying the
reference solution passes twice identically, text only fails).

=cut

sub _refuse {
  my ( $self, $field, $reason ) = @_;
  Langertha::Holmgang::Error->throw( $field, $reason );
}

sub _read_yaml {
  my ( $self, $file, $field ) = @_;
  my $bytes = eval { path($file)->slurp_raw };
  $self->_refuse( $field, 'not readable: '.( $@ =~ s/\s+\z//r ) ) unless defined $bytes;
  my $data = eval { YAML::XS::Load($bytes) };
  if ( my $err = $@ ) {
    $err =~ s/\s+\z//;
    $self->_refuse( $field, 'not valid YAML: '.$err );
  }
  $self->_refuse( $field, 'not a hash' ) unless ref $data eq 'HASH';
  return ( $data, $bytes );
}

sub load {
  my ( $self, $dir ) = @_;
  $dir =~ s{/+\z}{};
  my $dirname = path($dir)->basename;
  my $st = $self->structure;
  my ( $head, $head_bytes ) = $self->_read_yaml( $dir.'/suite.yaml', 'suite.yaml' );
  my %suite = $st->suite_head( $head, dirname => $dirname, format => 1 );

  my $sha = Digest::SHA->new(256);
  $sha->add( "suite.yaml\0", $head_bytes, "\0" );

  my $cdir = path( $dir, 'cases' );
  $self->_refuse( 'cases', 'directory cases/ missing' ) unless $cdir->is_dir;
  my @files = sort map { $_->basename } grep { $_->basename =~ /\.yaml\z/ && -f $_ } $cdir->children;
  $self->_refuse( 'cases', 'no cases' ) unless @files;

  my @cases;
  for my $file ( @files ) {
    my $f = 'cases/'.$file;
    my ( $data, $bytes ) = $self->_read_yaml( $dir.'/cases/'.$file, $f );
    $sha->add( $f."\0", $bytes, "\0" );
    for my $g ( $st->generated( $data, $f ) ) {
      my ( $field, $text ) = @$g;
      $sha->add( $field."\0", Digest::SHA::sha256_hex( Encode::encode( 'UTF-8', $text ) ), "\0" );
    }
    my $case = $st->case( $data, file => $file, tools => $suite{tools}, defaults => $suite{defaults} );
    $self->lint->lint( $case, $f );
    push @cases, $case;
  }
  return Langertha::Holmgang::Suite->new( %suite, cases => \@cases, checksum => $sha->hexdigest );
}

=method load

  my $suite = $loader->load($dir);

Reads, checks and lints one suite. The directory name is the suite's id.
Returns a L<Langertha::Holmgang::Suite>; throws a
L<Langertha::Holmgang::Error> on the first thing that does not hold.

=cut

sub _roots {
  my ( $self, @roots ) = @_;
  return grep { length } map { split /:/ } grep { defined } @roots;
}

sub list {
  my ( $self, @roots ) = @_;
  my ( %where, @ids );
  for my $root ( $self->_roots(@roots) ) {
    my $r = path($root);
    next unless $r->is_dir;
    for my $id ( sort grep { $self->structure->valid_id($_) && -f $root.'/'.$_.'/suite.yaml' } map { $_->basename } $r->children ) {
      push @ids, $id unless $where{$id};
      push @{ $where{$id} }, $root;
    }
  }
  my @out;
  for my $id ( sort @ids ) {
    if ( @{ $where{$id} } > 1 ) {
      push @out, { id => $id, error => 'suite id in more than one search directory: '.join( ' ', @{ $where{$id} } ) };
      next;
    }
    my $s = eval { $self->load( $where{$id}[0].'/'.$id ) };
    unless ( $s ) {
      my $err = $@;
      push @out, { id => $id, error => ref $err ? "$err" : ( $err =~ s/\s+\z//r ) };
      next;
    }
    push @out, {
      id          => $s->id,
      version     => $s->version,
      title       => $s->title,
      description => $s->description,
      topic       => $s->topic,
      cases       => scalar @{ $s->cases },
      tools       => scalar @{ $s->tools },
      checksum    => $s->checksum,
      error       => undef,
    };
  }
  return \@out;
}

=method list

  my $list = $loader->list( '/srv/suites:/data/suites', $more_root );

All suites under the search directories (separated by C<:>; each
subdirectory with a F<suite.yaml>), sorted by id, as a short overview:
C<id>, C<version>, C<title>, C<description>, C<topic>, C<cases> and C<tools>
(counts), C<checksum>, C<error>. A suite that does not load is listed with
C<error> (the refusal as text) instead of stopping the list; an id found in
more than one search directory is listed once, with an error.

=cut

sub locate {
  my ( $self, $roots, $id ) = @_;
  return undef unless $self->structure->valid_id($id);
  my @hits = grep { -f $_.'/'.$id.'/suite.yaml' } $self->_roots($roots);
  $self->_refuse( suite => "suite id '".$id."' in more than one search directory: ".join( ' ', @hits ) ) if @hits > 1;
  return @hits ? $hits[0].'/'.$id : undef;
}

=method locate

  my $dir = $loader->locate( '/srv/suites:/data/suites', 'example-lamp' );

The directory of suite C<$id> in the search directories, or C<undef>. The
same id in more than one of them is a refusal (field C<suite>) — which one is
meant would be a guess.

=cut

sub select_suites {
  my ( $self, $suites, %o ) = @_;
  my %ok = map { $_->{id} => $_ } grep { !$_->{error} } @$suites;
  my %pick;
  if ( $o{all} ) { $pick{$_} = 1 for keys %ok }
  my %topic;
  push @{ $topic{ $_->{topic} } }, $_->{id} for values %ok;
  for my $t ( @{ $o{topics} || [] } ) {
    $self->_refuse( topics => "unknown topic '".$t."' (".join( ', ', sort keys %topic ).')' ) unless $topic{$t};
    $pick{$_} = 1 for @{ $topic{$t} };
  }
  for my $id ( @{ $o{suites} || [] } ) {
    $self->_refuse( suites => "unknown or broken suite '".$id."'" ) unless $ok{$id};
    $pick{$id} = 1;
  }
  $self->_refuse( suites => 'no suite chosen (topic, suite or all)' ) unless %pick;
  return sort keys %pick;
}

=method select_suites

  my @ids = $loader->select_suites( $list, topics => ['netzwerk'], suites => ['example-lamp'], all => 0 );

Picks suites for a run from a L</list>: all that load (C<all>), those of one
or more topics, and single suites — joined, without duplicates, sorted by id.
An unknown topic, an unknown or broken suite, or nothing picked is a refusal
(field C<topics> or C<suites>).

=cut

__PACKAGE__->meta->make_immutable;
