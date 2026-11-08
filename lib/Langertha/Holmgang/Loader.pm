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

  my $dir = $loader->locate( '/srv/suites:/data/suites', 'demo-lamp' );
  my @ids = $loader->select_suites( $list, topics => ['demo'], suites => ['demo-lamp'] );

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

The fields of F<suite.yaml> and of a case, with an example, are under
L</SUITE FORMAT 2>.

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

  my $dir = $loader->locate( '/srv/suites:/data/suites', 'demo-lamp' );

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

  my @ids = $loader->select_suites( $list, topics => ['demo'], suites => ['demo-lamp'], all => 0 );

Picks suites for a run from a L</list>: all that load (C<all>), those of one
or more topics, and single suites — joined, without duplicates, sorted by id.
An unknown topic, an unknown or broken suite, or nothing picked is a refusal
(field C<topics> or C<suites>).

=cut

__PACKAGE__->meta->make_immutable;

=pod

=head1 SUITE FORMAT 2

What the loader reads, as L<Langertha::Holmgang::Structure> checks it. Every
key not listed here is refused (C<unknown key>), and so is every value of the
wrong shape; the refusal names the file and the field path.

=head2 Layout

  demo-motd/              the directory name is the suite id
    suite.yaml            head, defaults, tools
    cases/
      motd.yaml           one case per file; the file name is the case id
      ...                 loaded in file-name order

An id (suite, case, topic) is lower-case letters, digits and dashes, at most
64 characters, not starting with a dash. A suite without F<cases/> or without a
case file does not load.

=head2 suite.yaml

  format: 2                  required; format 1 (judge and rubric) is refused
  id: demo-motd              required; must equal the directory name
  version: 1                 required; integer >= 1
  title: "..."               required
  description: "..."         optional
  license: "..."             optional
  source:                    optional; title required, the rest optional
    { title, authors, license, url, location }
  topic: demo                optional id; the axis of every evaluation, default sonstiges
  threshold:                 optional; at least one of the two, each 0..1
    { pass_rate: 0.9, pass_k: 0.5 }
  repeat: 3                  optional; repetitions of a run, 1..100
  defaults:                  optional; what a case falls back to
    { system, temperature, max_tokens, max_turns }
  tools: [ ... ]             the tools every case of the suite offers

A setting a case leaves out falls back to C<defaults>, then to the built-in
value: C<system> C<''>, C<temperature> C<0>, C<max_tokens> C<2000>,
C<max_turns> C<12> (L<Langertha::Holmgang::Case/effective>). The ranges are
checked on the effective value: C<temperature> 0..2, C<max_tokens>
1..200000, C<max_turns> 1..50.

=head2 Tools

  tools:
    - name: run_command          [A-Za-z_][A-Za-z0-9_-]*, unique in the suite
      description: Run a shell command on a host.     required
      parameters:                JSON Schema subset, type: object
        type: object
        required: [host, command]
        properties:
          host:    { type: string }
          command: { type: string }
      simulator: run_command     exactly one of simulator or handlers

The model sees C<name>, C<description> and C<parameters> of every tool, in
name order (L<Langertha::Holmgang::World/offer>). C<parameters> is the subset
of JSON Schema that L<Langertha::Holmgang::ToolSchema> lists; the arguments of
every call are checked against it, and a call that does not fit fails with a
C<Fehler:> text without reaching the world.

What a call does is given by exactly one of:

=over 4

=item C<simulator: run_command>

C<run_command(host, command)> on the device C<host> of the state, executed by
the simulator of its type (L</The world>). C<host> and C<command> must be
required parameters.

=item C<simulator: write_file>

C<write_file(host, path, content)> replaces a file on the device; C<host>,
C<path> and C<content> must be required parameters. Devices whose simulator
has no C<write_file> (RouterOS, IOS) refuse the call.

=item C<simulator: E<lt>answer worldE<gt>>

A tool of an answer world (L<Langertha::Holmgang::Role::AnswerWorld>), such as
C<kueche>: the tool's name must be one the world answers, and the world's
required parameters must be required here too.

=item C<handlers: [ ... ]>

A tool described in data for a small world without a simulator
(L</Handlers>).

=back

=head2 A case

  id: motd                   required; must equal the file name without .yaml
  title: "..."               required
  tags: [ ... ]              optional list of texts
  difficulty: leicht         optional; leicht, mittel or schwer
  system: "..."              optional; else defaults.system
  messages: [ ... ]          required, not empty
  state: { ... }             required, not empty: the initial world
  observe: [ ... ]           optional
  rules: [ ... ]             required, not empty
  solution: [ ... ]          required: the reference solution
  alternatives: [ ... ]      required, not empty (may be left out in the "no tool" family)
  wrong_solutions: [ ... ]   required, not empty
  temperature, max_tokens, max_turns     optional; else the suite's defaults
  source: { ... }            optional; as in suite.yaml
  weight: 3                  optional positive number, default 1

B<Messages> are C<< { role, content, untrusted } >>. C<role> is C<user> or
C<assistant> (the system prompt goes under C<system>), the last message is
from the user. C<content> is text, a generate spec
C<< { generate: { ... } } >> or a list of texts and generate specs, joined
(L<Langertha::Holmgang::Haystack/THE SPEC>). C<untrusted: true> marks content
that does not come from the user; the mark is for the report only and never
goes out (L<Langertha::Holmgang::Case/prompt_messages>).

B<Calls> in C<solution>, C<alternatives> and C<wrong_solutions> are
C<< { tool, args } >> with a tool the suite offers. A C<solution> is a list of
calls; an alternative and a wrong solution are C<< { title, calls } >>. The
model never sees any of them. C<solution: []> is allowed only together with
the required rule C<only_tools: []> — the "no tool" family, where doing nothing
is the right answer.

B<Tags with a meaning:> C<stufe-16k>, C<stufe-48k>, C<stufe-96k>,
C<stufe-160k> give the length tier (L<Langertha::Holmgang::Case/tier>);
C<injection> and C<verbot> make the case a hard case, where one forbidden call
fails the suite's verdict (L<Langertha::Holmgang::Case/is_hard>).

B<Rules> are described in L<Langertha::Holmgang::Grader/RULES>. A case needs
at least one required rule, and at least one required rule on the end state
(C<state>, C<check>, C<packet> or C<login>) unless it is in the "no tool"
family.

=head2 The world

C<state> is the initial world, nested data. A top-level entry with a C<type>
is a device (or an answer world): the type picks its simulator from
L<Langertha::Holmgang::Simulators> — built in are C<linux>, C<routeros>,
C<ios> and the answer world C<kueche> — and every other key of the entry is
whatever that simulator documents in its POD. An unknown type is refused. A
top-level entry without C<type> is plain data for handlers.

  state:
    web-1:
      type: linux
      files:
        /etc/motd: "Welcome.\n"            a file as text, or a hash with content, mode, owner ...
    lamps:                                 no type: data for handlers
      hall: { on: false }

A file content of a device may be a generate spec, as a message content may.
Before the first call each simulator prepares its devices once (the running
values a service read from its files at boot); a simulator that rejects its
device state refuses the case. Simulators: L<Langertha::Holmgang::Sim::Linux>,
L<Langertha::Holmgang::Sim::RouterOS>, L<Langertha::Holmgang::Sim::IOS>,
L<Langertha::Holmgang::Sim::Kueche>; how to add one:
L<Langertha::Holmgang::Role::Simulator>.

=head2 Paths and arguments

A path into the state is dotted text (C<lamps.hall.on>) or a list of segments
for keys with dots (C<[web-1, files, /etc/motd, content]>); list entries are
addressed by index from 0. C<{name}> in a segment stands for the call's
argument C<name>.

In the values of handler changes, a text that is exactly C<{name}> takes the
argument as it is (a list, a number, a boolean); C<{name}> inside a longer
text is replaced by the argument as text. An B<argument filter> may follow:
C<{name|split}> (text split at commas and white space into a list),
C<{name|int}> (the first integer), C<{name|lc}> (lower case). These three
are all there are; lint refuses any other filter at load
(L<Langertha::Holmgang::Lint>).

=head2 Observations

  observe:
    - match: { host: "^web-1$", command: "^ping " }     command is required
      when:  [ { path: lamps.hall.on, equals: true } ]  optional
      output: "..."                                     required, may be empty
      error: true                                       optional: the call fails

Case-supplied output for diagnostic commands whose answer lies outside the
state (a ping across devices, a log). Only for tools with
C<simulator: run_command>, and they come first: the first observation whose
C<match> (a regular expression per argument; named captures become arguments)
and C<when> (expectations on the current state,
L<Langertha::Holmgang::Expectation>) fit answers the call. Its C<output> is a
template (L<Langertha::Holmgang::Template>); pipe filters behind a C<|> in the
command (C<grep>, C<head>, C<wc> ... — L<Langertha::Holmgang::Shell::Filter>)
are applied to it. An observation never changes the state. On a C<linux>
device each link of a chain (C<a && b; c>) is answered on its own.

=head2 Handlers

  handlers:
    - match: { lamp: "^(?<room>kitchen|hall)$" }        optional
      when:  [ ... ]                                    optional
      apply:                                            optional list of changes
        - set: "lamps.{room}.on"
          value: "{on}"
      output: "<: $args.room :> is now on"              optional template
      error: true                                       optional: the call fails

The first handler whose C<match> and C<when> fit takes the call; none fitting
answers C<Fehler: dieser Aufruf ist in diesem Szenario nicht vorgesehen.> and
changes nothing. C<apply> runs on a copy of the state, then C<output> is
rendered against the changed state; one failing change leaves the state as it
was and the call fails with its reason. The changes, exactly one kind each:

  set: PATH, value: V              set a key or a list entry
  push: PATH, value: V             append to a list (created when missing)
  insert: PATH, at: N, value: V    insert into a list at index N
  delete: PATH                     remove a key or a list entry
  remove: PATH, where: PATTERN     remove the list entries that fit the pattern
  move: PATH, from: N, to: M       move a list entry

A C<where> pattern is a regular expression for a text entry, or a hash of
field to regular expression (or to expectations) for a hash entry.

=head2 Lint

Every case passes the self-check of L<Langertha::Holmgang::Lint> on every
load, from either front end: doing nothing fails, the reference solution and
every alternative pass, every wrong solution fails, every template renders,
and the two mock runs over a model engine hold (replaying the reference
solution passes twice identically; answering text only fails). A case that
does not hold does not load. Fix the case or the simulator, never lint.

=head2 Example suites

The distribution ships three invented suites to learn from (ADR 0010), each
with its origin and license in the head of F<suite.yaml>:

  demo-linux      a linux device; run_command and write_file (two cases)
  demo-lamp       a world without devices: one tool described by handlers
  demo-haystack   a message made by generate (Langertha::Holmgang::Haystack)

In a checkout they are under F<share/suites>; installed, under the
distribution's share directory:

  use File::ShareDir qw( dist_dir );
  my $dir = dist_dir('Langertha-Holmgang').'/suites';
  my $suite = Langertha::Holmgang::Loader->new->load("$dir/demo-linux");

They are public and therefore no measurement; never copy one into a real
suite.

=head2 An example

An invented suite of one case, to learn the shape from (it is the case
C<motd> of the shipped C<demo-linux>):

  # demo-motd/suite.yaml
  format: 2
  id: demo-motd
  version: 1
  title: "Demo: a message of the day"
  topic: demo
  threshold: { pass_rate: 1 }
  defaults:
    system: "You administer Linux servers through the tools. Act, do not explain."
    max_turns: 6
  tools:
    - name: run_command
      simulator: run_command
      description: Run a shell command on a host.
      parameters:
        type: object
        required: [host, command]
        properties: { host: { type: string }, command: { type: string } }
    - name: write_file
      simulator: write_file
      description: Replace a file on a host.
      parameters:
        type: object
        required: [host, path, content]
        properties: { host: { type: string }, path: { type: string }, content: { type: string } }

  # demo-motd/cases/motd.yaml
  id: motd
  title: Announce the maintenance window
  difficulty: leicht
  messages:
    - role: user
      content: "On web-1, make /etc/motd say: Maintenance Saturday 06:00."
  state:
    web-1:
      type: linux
      files:
        /etc/motd: "Welcome.\n"
  rules:
    - title: motd announces the window
      state: [web-1, files, /etc/motd, content]
      regex: "Maintenance Saturday 06:00"
    - title: nothing else changed
      unchanged_except: [ [web-1, files, /etc/motd] ]
  solution:
    - tool: write_file
      args: { host: web-1, path: /etc/motd, content: "Maintenance Saturday 06:00.\n" }
  alternatives:
    - title: echo into the file
      calls:
        - tool: run_command
          args: { host: web-1, command: "echo 'Maintenance Saturday 06:00.' > /etc/motd" }
  wrong_solutions:
    - title: wrote the wrong file
      calls:
        - tool: write_file
          args: { host: web-1, path: /etc/issue, content: "Maintenance Saturday 06:00.\n" }

And a world without a simulator, where one tool is described by handlers:

  # demo-lamp/suite.yaml (head as above, without run_command and write_file)
  tools:
    - name: set_lamp
      description: Switch a lamp on or off.
      parameters:
        type: object
        required: [lamp, on]
        properties: { lamp: { type: string }, on: { type: boolean } }
      handlers:
        - match: { lamp: "^(?<room>kitchen|hall)$" }
          apply:
            - { set: "lamps.{room}.on", value: "{on}" }
          output: "<: $args.room :> is now <: $state.lamps[$args.room].on ? 'on' : 'off' :>"
        - output: "no such lamp"
          error: true

  # demo-lamp/cases/hall.yaml
  id: hall
  title: Light in the hall
  messages:
    - { role: user, content: "Turn the light in the hall on, leave the kitchen as it is." }
  state:
    lamps: { kitchen: { on: false }, hall: { on: false } }
  rules:
    - { title: hall is on, state: lamps.hall.on, equals: true }
    - { title: kitchen untouched, unchanged_except: [lamps.hall] }
  solution:
    - { tool: set_lamp, args: { lamp: hall, on: true } }
  alternatives:
    - title: kitchen switched off first, which it already was
      calls:
        - { tool: set_lamp, args: { lamp: kitchen, on: false } }
        - { tool: set_lamp, args: { lamp: hall, on: true } }
  wrong_solutions:
    - title: wrong room
      calls: [ { tool: set_lamp, args: { lamp: kitchen, on: true } } ]

=cut
