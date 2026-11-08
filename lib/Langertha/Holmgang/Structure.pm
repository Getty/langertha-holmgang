package Langertha::Holmgang::Structure;
# ABSTRACT: The shape checks of suite format 2, shared by the loader and the DSL

use Moose;
use namespace::autoclean;
use utf8;

use JSON::MaybeXS ();
use Scalar::Util qw( blessed );
use Langertha::Holmgang::Case;
use Langertha::Holmgang::Error;
use Langertha::Holmgang::Expectation ();
use Langertha::Holmgang::Haystack;
use Langertha::Holmgang::Simulators;
use Langertha::Holmgang::Target ();
use Langertha::Holmgang::ToolSchema qw( check_schema );
use Langertha::Holmgang::World;

our $VERSION = '0.001';

# true constants: the vocabulary of format 2
our @RULE_KINDS = qw( state unchanged_except calls not_called only_tools check packet login );
our @MATCHERS   = @Langertha::Holmgang::Expectation::MATCHERS;
our @OPS        = @Langertha::Holmgang::World::OPS;
our @CASE_KEYS  = qw( id title tags difficulty system messages state observe rules solution
  alternatives wrong_solutions temperature max_tokens max_turns source weight );
our @SUITE_KEYS = qw( format id version title description license defaults source tools topic threshold repeat );

my %SIMULATOR_PARAMS = ( run_command => [qw( host command )], write_file => [qw( host path content )] );
my %HOOK = map { $_ => 1 } qw( prerouting input forward output postrouting );
my %L4   = map { $_ => 1 } qw( tcp udp icmp icmpv6 );

my $ID_RE   = qr/\A[a-z0-9][a-z0-9-]{0,63}\z/;
my $TOOL_RE = qr/\A[A-Za-z_][A-Za-z0-9_-]{0,63}\z/;

=synopsis

  my $structure = Langertha::Holmgang::Structure->new;

  my %head  = $structure->suite_head( $suite_yaml, dirname => 'example-lamp' );
  my @texts = $structure->generated( $case_yaml, 'cases/c1.yaml' );   # for the checksum
  my $case  = $structure->case( $case_yaml,
    file     => 'c1.yaml',
    tools    => $head{tools},
    defaults => $head{defaults},
  );

=description

The strict shape checks of suite format 2 (cai-platform
C<docs/entwurf-evals.md> §3): an unknown key, a wrong type, a bad id or
regular expression, a call of a tool the suite does not offer — each is a
L<Langertha::Holmgang::Error> naming the field (C<cases/c1.yaml:
rules[0].regex>). Both front ends call this module, so the DSL cannot build
what the loader would refuse (ADR 0005). Lint (L<Langertha::Holmgang::Lint>)
runs after it, on every load.

The checks leave the data as written: a L<Langertha::Holmgang::Case> holds its
own values, not a normalised copy. Generated content
(C<< { generate => … } >>) is resolved here once to check it, and the initial
state is prepared once by the simulators to check it; both results go into
the case.

=cut

has simulators => (
  is      => 'ro',
  lazy    => 1,
  builder => '_build_simulators',
);
sub _build_simulators { Langertha::Holmgang::Simulators->new }

=attr simulators

The simulator registry: device types, answer worlds and their tools,
C<prepare>.

=cut

has haystack => (
  is      => 'ro',
  lazy    => 1,
  builder => '_build_haystack',
);
sub _build_haystack { Langertha::Holmgang::Haystack->new }

=attr haystack

Resolves generated content; shared with the cases, so a text is generated once.

=cut

sub _refuse {
  my ( $self, $field, $reason ) = @_;
  Langertha::Holmgang::Error->throw( $field, $reason );
}

sub valid_id {
  my ( $self, $id ) = @_;
  return defined $id && !ref $id && $id =~ $ID_RE ? 1 : 0;
}

=method valid_id

  $structure->valid_id('example-lamp');   # 1

True for a suite, case or topic id: lower-case letters, digits, dashes, at
most 64 characters, not starting with a dash. Keeps paths like C<../x> out.

=cut

#### Small checks

sub _keys_ok {
  my ( $self, $h, $field, @ok ) = @_;
  $self->_refuse( $field, 'not a hash' ) unless ref $h eq 'HASH';
  my %ok = map { $_ => 1 } @ok;
  for my $k ( sort keys %$h ) {
    $self->_refuse( $field.'.'.$k, 'unknown key' ) unless $ok{$k};
  }
  return;
}

sub _text {
  my ( $self, $v, $field, $optional ) = @_;
  return undef if $optional && !defined $v;
  $self->_refuse( $field, 'text missing' ) if !defined $v || ref $v || !length $v;
  return "$v";
}

sub _num {
  my ( $self, $v, $field, $min, $max ) = @_;
  $self->_refuse( $field, 'not a number' ) if !defined $v || ref $v || $v !~ /\A-?(?:\d+\.?\d*|\.\d+)\z/;
  $self->_refuse( $field, 'outside '.$min.'..'.$max ) if $v < $min || defined $max && $v > $max;
  return 0 + $v;
}

sub _regex {
  my ( $self, $v, $field ) = @_;
  $self->_text( $v, $field );
  $self->_refuse( $field, 'invalid regular expression' ) unless eval { qr/$v/; 1 };
  return "$v";
}

# a mark true/false (missing = false)
sub _flag {
  my ( $self, $v, $field ) = @_;
  return 0 unless defined $v;
  $self->_refuse( $field, 'true or false' )
    if ref $v ? !JSON::MaybeXS::is_bool($v) : !grep { $v eq $_ } '1', '0', '';
  return $v ? 1 : 0;
}

sub _list {
  my ( $self, $v, $field, $nonempty ) = @_;
  $self->_refuse( $field, 'not a list' ) unless ref $v eq 'ARRAY';
  $self->_refuse( $field, 'empty list' ) if $nonempty && !@$v;
  return $v;
}

sub _scalars {
  my ( $self, $v, $field ) = @_;
  $self->_list( $v, $field, 1 );
  $self->_refuse( $field, 'list of values expected' ) if grep { !defined || ref } @$v;
  return $v;
}

# a path: dotted text or a list of segments
sub _path {
  my ( $self, $p, $field ) = @_;
  if ( ref $p eq 'ARRAY' ) {
    $self->_refuse( $field, 'empty path' ) unless @$p;
    $self->_refuse( $field, 'segments must be text' ) if grep { !defined || ref || !length } @$p;
    return $p;
  }
  $self->_text( $p, $field );
  $self->_refuse( $field, 'path with an empty segment' ) if grep { !length } split /\./, $p, -1;
  return $p;
}

sub _arg_patterns {
  my ( $self, $m, $field ) = @_;
  $self->_refuse( $field, 'not a hash' ) unless ref $m eq 'HASH';
  $self->_regex( $m->{$_}, $field.'.'.$_ ) for sort keys %$m;
  return $m;
}

# a pattern for a list element: a regex (text) or a hash field -> regex | expectations
sub _element {
  my ( $self, $m, $field ) = @_;
  return $self->_regex( $m, $field ) unless ref $m;
  $self->_refuse( $field, 'pattern (text) or hash field -> pattern expected' ) unless ref $m eq 'HASH' && %$m;
  for my $f ( sort keys %$m ) {
    ref $m->{$f} ? $self->_matchers( $m->{$f}, $field.'.'.$f, 1 ) : $self->_regex( $m->{$f}, $field.'.'.$f );
  }
  return $m;
}

# expectations on a value (Expectation::condition); with $bare without path
sub _matchers {
  my ( $self, $c, $field, $bare ) = @_;
  $self->_keys_ok( $c, $field, ( $bare ? () : 'path' ), @MATCHERS );
  $self->_path( $c->{path}, $field.'.path' ) unless $bare;
  my @m = grep { exists $c->{$_} } @MATCHERS;
  $self->_refuse( $field, 'no expectation ('.join( ', ', @MATCHERS ).')' ) unless @m;
  for my $k ( @m ) {
    my $v = $c->{$k};
    if    ( $k eq 'exists' || $k eq 'absent' ) { }
    elsif ( $k eq 'equals' ) { $self->_refuse( $field.'.equals', 'value expected' ) if !defined $v || ref $v }
    elsif ( $k eq 'in' || $k eq 'contains' || $k eq 'excludes' ) { $self->_scalars( $v, $field.'.'.$k ) }
    elsif ( $k eq 'regex' )  { $self->_regex( $v, $field.'.regex' ) }
    elsif ( $k eq 'length' ) { $self->_num( $v, $field.'.length', 0, 100_000 ) }
    elsif ( $k eq 'any' || $k eq 'none' ) { $self->_element( $v, $field.'.'.$k ) }
    else {    # before
      $self->_refuse( $field.'.before', 'exactly two patterns' ) unless ref $v eq 'ARRAY' && @$v == 2;
      $self->_element( $v->[$_], $field.'.before['.$_.']' ) for 0, 1;
    }
  }
  return $c;
}

sub _op {
  my ( $self, $o, $field ) = @_;
  $self->_refuse( $field, 'not a hash' ) unless ref $o eq 'HASH';
  my @kind = grep { exists $o->{$_} } @OPS;
  $self->_refuse( $field, 'exactly one change ('.join( ', ', @OPS ).')' ) unless @kind == 1;
  my $kind = $kind[0];
  my %need = ( set => ['value'], push => ['value'], insert => [qw( at value )], delete => [],
    remove => ['where'], move => [qw( from to )] );
  $self->_keys_ok( $o, $field, $kind, @{ $need{$kind} } );
  exists $o->{$_} or $self->_refuse( $field.'.'.$_, 'missing' ) for @{ $need{$kind} };
  $self->_path( $o->{$kind}, $field.'.'.$kind );
  $self->_element( $o->{where}, $field.'.where' ) if exists $o->{where};
  return $o;
}

sub _handler {
  my ( $self, $h, $field, @keys ) = @_;
  $self->_keys_ok( $h, $field, @keys ? @keys : qw( match when apply output error ) );
  $self->_arg_patterns( $h->{match} // {}, $field.'.match' );
  my $when = $self->_list( $h->{when} // [], $field.'.when' );
  $self->_matchers( $when->[$_], $field.'.when['.$_.']' ) for 0 .. $#$when;
  my $apply = $self->_list( $h->{apply} // [], $field.'.apply' );
  $self->_op( $apply->[$_], $field.'.apply['.$_.']' ) for 0 .. $#$apply;
  $self->_text( $h->{output}, $field.'.output', 1 ) unless @keys;
  return $h;
}

#### Suite head and tools

sub tool {
  my ( $self, $t, $field ) = @_;
  $self->_keys_ok( $t, $field, qw( name description parameters handlers simulator ) );
  my $name = $t->{name} // '';
  $self->_refuse( $field.'.name', 'invalid tool name' ) unless !ref $name && $name =~ $TOOL_RE;
  my $params = $t->{parameters} // { type => 'object', properties => {} };
  $self->_refuse( $field.'.parameters', 'JSON Schema (type: object) expected' )
    unless ref $params eq 'HASH' && ( $params->{type} // '' ) eq 'object';
  check_schema( $params, $field.'.parameters' );
  $self->_text( $t->{description}, $field.'.description' );
  if ( defined( my $sim = $t->{simulator} ) ) {
    my $sims  = $self->simulators;
    my $world = !ref $sim && !$SIMULATOR_PARAMS{$sim} ? $sims->world_tools($sim) : undef;
    $self->_refuse( $field.'.simulator', 'run_command, write_file or an answer world ('
      .join( ', ', grep { $sims->world_tools($_) } $sims->types ).')' )
      unless !ref $sim && ( $SIMULATOR_PARAMS{$sim} || $world );
    $self->_refuse( $field.'.handlers', 'simulator or handlers, not both' ) if exists $t->{handlers};
    $self->_refuse( $field.'.name', 'the world '.$sim.' has no tool '.$name.' ('.join( ', ', sort keys %$world ).')' )
      if $world && !$world->{$name};
    for my $p ( @{ $world ? $world->{$name} : $SIMULATOR_PARAMS{$sim} } ) {
      $self->_refuse( $field.'.parameters', 'required parameter '.$p.' missing' )
        unless grep { $_ eq $p } @{ $params->{required} || [] };
    }
  }
  else {
    my $hs = $self->_list( $t->{handlers}, $field.'.handlers', 1 );
    $self->_handler( $hs->[$_], $field.'.handlers['.$_.']' ) for 0 .. $#$hs;
  }
  return $t;
}

=method tool

  $structure->tool( $tool, 'suite.yaml: tools[0]' );

Checks one tool of the suite: C<name>, C<description>, C<parameters> (the
subset of L<Langertha::Holmgang::ToolSchema>, C<type: object>), and exactly one
of C<simulator> (C<run_command>, C<write_file> with their required
parameters, or an answer world that knows the tool's name) or C<handlers>.

=cut

sub suite_head {
  my ( $self, $head, %o ) = @_;
  $self->_refuse( 'suite.yaml', 'not a hash' ) unless ref $head eq 'HASH';
  if ( exists $o{format} || exists $head->{format} ) {
    my $format = $head->{format} // '';
    $self->_refuse( 'format', 'format 1 (judge and rubric) is not read any more — format 2: end state and rules' )
      if $format eq '1';
    $self->_refuse( 'format', 'only format 2 is known' ) unless $format eq '2';
  }
  $self->_keys_ok( $head, 'suite.yaml', @SUITE_KEYS );
  my %out;
  if ( defined( my $t = $head->{threshold} ) ) {
    $self->_keys_ok( $t, 'threshold', qw( pass_rate pass_k ) );
    $self->_refuse( 'threshold', 'pass_rate or pass_k (0..1) expected' ) unless exists $t->{pass_rate} || exists $t->{pass_k};
    $self->_num( $t->{$_}, 'threshold.'.$_, 0, 1 ) for grep { exists $t->{$_} } qw( pass_rate pass_k );
    $out{threshold} = { map { $_ => 0 + $t->{$_} } grep { exists $t->{$_} } qw( pass_rate pass_k ) };
  }
  my $repeat = $head->{repeat};
  $self->_refuse( 'repeat', 'integer 1..100 (runs per suite)' )
    if defined $repeat && ( ref $repeat || $repeat !~ /\A[1-9]\d{0,2}\z/ || $repeat > 100 );
  $out{repeat} = 0 + $repeat if defined $repeat;
  if ( defined $head->{topic} ) {
    $self->_refuse( 'topic', 'topic as an id ([a-z0-9-])' ) unless $self->valid_id( $head->{topic} );
    $out{topic} = $head->{topic};
  }
  my @tools;
  if ( defined $head->{tools} ) {
    my $l = $self->_list( $head->{tools}, 'suite.yaml: tools' );
    my %seen;
    for my $i ( 0 .. $#$l ) {
      my $tool = $self->tool( $l->[$i], 'suite.yaml: tools['.$i.']' );
      $self->_refuse( 'suite.yaml: tools', 'tool '.$tool->{name}.' twice' ) if $seen{ $tool->{name} }++;
      push @tools, $tool;
    }
  }
  my $id = $head->{id};
  if ( defined $o{dirname} ) {
    $self->_refuse( 'id', "must be '".$o{dirname}."' (the directory)" )
      unless !ref $id && ( $id // '' ) eq $o{dirname} && $self->valid_id( $o{dirname} );
  }
  else {
    $self->_refuse( 'id', 'invalid id' ) unless $self->valid_id($id);
  }
  my $version = $head->{version};
  $self->_refuse( 'version', 'integer >= 1' ) unless defined $version && !ref $version && $version =~ /\A[1-9]\d{0,5}\z/;
  my $defaults = $head->{defaults} // {};
  $self->_keys_ok( $defaults, 'defaults', qw( system temperature max_tokens max_turns ) );
  $self->_text( $head->{title}, 'title' );
  $self->_text( $head->{$_}, $_, 1 ) for qw( description license );
  $self->_source( $head->{source}, 'source' );
  return (
    %out,
    id       => $id,
    version  => 0 + $version,
    title    => $head->{title},
    defaults => $defaults,
    tools    => \@tools,
    ( map { defined $head->{$_} ? ( $_ => $head->{$_} ) : () } qw( description license source ) ),
  );
}

=method suite_head

  my %args = $structure->suite_head( $suite_yaml, dirname => $dir, format => 1 );

Checks the head of a suite and returns the arguments for
L<Langertha::Holmgang::Suite> (without C<cases> and C<checksum>). With
C<dirname> the C<id> must equal it; with C<format> (the loader) the file must
say C<format: 2>, and format 1 is refused with its own reason.

=cut

sub _source {
  my ( $self, $src, $field ) = @_;
  return unless defined $src;
  $self->_keys_ok( $src, $field, qw( title authors license url location ) );
  $self->_text( $src->{title}, $field.'.title' );
  $self->_text( $src->{$_}, $field.'.'.$_, 1 ) for qw( authors license url location );
  return $src;
}

#### Generated content

# Haystack croaks "<field>: <reason>"; the field starts with the one we passed
sub _resolve {
  my ( $self, $v, $field ) = @_;
  my $text = eval { $self->haystack->resolve( $v, $field ) };
  return $text unless $@;
  my $err = $@;
  die $err if blessed $err;
  $err =~ s/$Langertha::Holmgang::Target::LOCATION\.?\n?\z//;
  $err =~ s/\s+\z//;
  if ( index( $err, $field ) == 0 ) {
    my $rest = substr( $err, length $field );
    if ( $rest =~ /\A((?:[.\[][^:]*)?): (.*)\z/s ) {
      $self->_refuse( $field.$1, $2 );
    }
  }
  $self->_refuse( $field, $err );
}

sub generated {
  my ( $self, $data, $f ) = @_;
  my @out;
  return @out unless ref $data eq 'HASH';
  my $put = sub {
    my ( $h, $k, $field ) = @_;
    return unless ref $h->{$k} eq 'HASH' || ref $h->{$k} eq 'ARRAY';
    push @out, [ $field, $self->_resolve( $h->{$k}, $field ) ];
  };
  if ( ref $data->{messages} eq 'ARRAY' ) {
    my $i = 0;
    for my $m ( @{ $data->{messages} } ) {
      $put->( $m, 'content', $f.': messages['.$i.'].content' ) if ref $m eq 'HASH';
      $i++;
    }
  }
  return @out unless ref $data->{state} eq 'HASH';
  for my $dev ( sort keys %{ $data->{state} } ) {
    my $files = ref $data->{state}{$dev} eq 'HASH' ? $data->{state}{$dev}{files} : undef;
    next unless ref $files eq 'HASH';
    for my $p ( sort keys %$files ) {
      $put->( $files->{$p}, 'content', $f.': state.'.$dev.'.files.'.$p.'.content' ) if ref $files->{$p} eq 'HASH';
    }
  }
  return @out;
}

=method generated

  my @texts = $structure->generated( $case_yaml, 'cases/c1.yaml' );
  # ( [ 'cases/c1.yaml: messages[0].content', $text ], … )

The generated contents of a case — message contents, then file contents of
the state by device and path — each with its field and its text, in the order
the checksum takes them. Refuses a broken generate spec with its field.

=cut

#### Cases

sub case {
  my ( $self, $data, %o ) = @_;
  my $f = defined $o{file} ? 'cases/'.$o{file} : $o{field} // 'case';
  $self->_keys_ok( $data, $f, @CASE_KEYS );
  my $id = $data->{id} // '';
  if ( defined $o{file} ) {
    ( my $want = $o{file} ) =~ s/\.yaml\z//;
    $self->_refuse( $f.': id', "must be '".$want."' (the file name)" ) unless !ref $id && $id eq $want;
  }
  $self->_refuse( $f.': id', 'invalid id' ) unless $self->valid_id($id);

  # messages
  $self->_refuse( $f.': messages', 'list missing' ) unless ref $data->{messages} eq 'ARRAY' && @{ $data->{messages} };
  my @prompt;
  my $i = 0;
  for my $m ( @{ $data->{messages} } ) {
    my $mf = $f.': messages['.$i.']';
    $self->_keys_ok( $m, $mf, qw( role content untrusted ) );
    $self->_flag( $m->{untrusted}, $mf.'.untrusted' );
    my $role = $m->{role} // '';
    $self->_refuse( $mf.'.role', 'user or assistant (the system prompt goes under system:)' )
      unless $role eq 'user' || $role eq 'assistant';
    my $content = ref $m->{content} ? $self->_resolve( $m->{content}, $mf.'.content' ) : $m->{content};
    push @prompt, { role => $role, content => $self->_text( $content, $mf.'.content' ) };
    $i++;
  }
  $self->_refuse( $f.': messages', 'the last message must be from the user' ) unless $prompt[-1]{role} eq 'user';

  # state, prepared once to check it
  my $initial = $self->_state( $data->{state}, $f.': state' );

  my @tools = sort { $a->{name} cmp $b->{name} } @{ $o{tools} || [] };
  $self->_refuse( $f.': tools', 'the suite offers no tools (suite.yaml: tools)' ) unless @tools;
  my %tools = map { $_->{name} => 1 } @tools;

  my $ol = $self->_list( $data->{observe} // [], $f.': observe' );
  $self->_observe( $ol->[$_], $f.': observe['.$_.']' ) for 0 .. $#$ol;

  my $rl = $self->_list( $data->{rules}, $f.': rules', 1 );
  my @kinds = map { $self->_rule( $rl->[$_], $f.': rules['.$_.']', \%tools, $data->{state} ) } 0 .. $#$rl;
  my @required = map { $kinds[$_] } grep { _required( $rl->[$_] ) } 0 .. $#$rl;
  $self->_refuse( $f.': rules', 'at least one required rule' ) unless @required;
  # the "no tool" family: doing nothing is right. An empty solution only with the
  # required rule only_tools: [] — then lint checks that every wrong solution fails.
  my $nothing = ref $data->{solution} eq 'ARRAY' && !@{ $data->{solution} };
  $self->_refuse( $f.': solution', 'empty only with the required rule only_tools: [] (the "no tool" family)' )
    if $nothing && !grep { _required( $_ ) && exists $_->{only_tools} && ref $_->{only_tools} eq 'ARRAY' && !@{ $_->{only_tools} } } @$rl;
  # a check command runs on the end state and so checks it too
  $self->_refuse( $f.': rules', 'at least one required rule on the end state (state, check, packet or login)' )
    unless $nothing || grep { /\A(?:state|check|packet|login)\z/ } @required;

  for my $k (qw( alternatives wrong_solutions )) {
    next if $nothing && $k eq 'alternatives' && !exists $data->{$k};
    my $wl = $self->_list( $data->{$k}, $f.': '.$k, 1 );
    for my $j ( 0 .. $#$wl ) {
      my $wf = $f.': '.$k.'['.$j.']';
      $self->_keys_ok( $wl->[$j], $wf, qw( title calls ) );
      $self->_text( $wl->[$j]{title}, $wf.'.title' );
      $self->_calls( $wl->[$j]{calls}, $wf.'.calls', \%tools );
    }
  }

  my $tags = $data->{tags} // [];
  $self->_refuse( $f.': tags', 'not a list of texts' ) unless ref $tags eq 'ARRAY' && !grep { ref } @$tags;
  my $difficulty = $data->{difficulty};
  $self->_refuse( $f.': difficulty', 'leicht, mittel or schwer' )
    if defined $difficulty && !grep { $difficulty eq $_ } qw( leicht mittel schwer );

  my $defaults = $o{defaults} || {};
  my %range = ( temperature => [ 0, 2 ], max_tokens => [ 1, 200_000 ], max_turns => [ 1, 50 ] );
  for my $k ( sort keys %range ) {
    next unless exists $data->{$k} || exists $defaults->{$k};
    $self->_num( exists $data->{$k} ? $data->{$k} : $defaults->{$k}, $f.': '.$k, @{ $range{$k} } );
  }
  $self->_num( $data->{weight}, $f.': weight', 0 ) if exists $data->{weight};
  $self->_refuse( $f.': weight', 'a positive number' ) if exists $data->{weight} && $data->{weight} <= 0;
  $self->_text( $data->{title}, $f.': title' );
  $self->_text( $data->{system} // $defaults->{system}, $f.': system', 1 );
  $self->_calls( $data->{solution}, $f.': solution', \%tools ) unless $nothing;
  $self->_source( $data->{source}, $f.': source' );

  return Langertha::Holmgang::Case->new(
    ( map { exists $data->{$_} ? ( $_ => $data->{$_} ) : () } @CASE_KEYS ),
    tools           => \@tools,
    defaults        => $defaults,
    simulators      => $self->simulators,
    haystack        => $self->haystack,
    initial_state   => $initial,
    prompt_messages => \@prompt,
  );
}

=method case

  my $case = $structure->case( $case_yaml,
    file     => 'c1.yaml',            # the id must be the file name; fields start "cases/c1.yaml"
    tools    => \@suite_tools,
    defaults => \%suite_defaults,
  );

Checks one case of format 2 and returns its L<Langertha::Holmgang::Case>.
Without C<file>, C<field> names the start of every field path. Lint is not
part of it.

=cut

sub _required { my ( $r ) = @_; return !exists $r->{required} || $r->{required} ? 1 : 0 }

# an observation: answer to a diagnostic command, may depend on the state, never changes it
sub _observe {
  my ( $self, $h, $field ) = @_;
  $self->_keys_ok( $h, $field, qw( match when output error ) );
  $self->_refuse( $field.'.match', 'host and command as patterns' ) unless ref $h->{match} eq 'HASH' && $h->{match}{command};
  $self->_refuse( $field.'.output', 'text expected (may be empty)' ) if !defined $h->{output} || ref $h->{output};
  $self->_handler( $h, $field, qw( match when output error ) );
  return $h;
}

# the state: devices (hashes with type) need a known simulator; generated file contents
# resolved, then prepared — the case's initial state
sub _state {
  my ( $self, $state, $field ) = @_;
  $self->_refuse( $field, 'hash (the state of the world) missing' ) unless ref $state eq 'HASH' && %$state;
  my %types = map { $_ => 1 } $self->simulators->types;
  for my $k ( sort keys %$state ) {
    next unless ref $state->{$k} eq 'HASH' && exists $state->{$k}{type};
    $self->_refuse( $field.'.'.$k.'.type', 'device type '.join( ', ', sort keys %types ) ) unless $types{ $state->{$k}{type} // '' };
  }
  my $s = Langertha::Holmgang::World->clone($state);
  for my $dev ( sort keys %$s ) {
    my $files = ref $s->{$dev} eq 'HASH' ? $s->{$dev}{files} : undef;
    next unless ref $files eq 'HASH';
    for my $p ( sort keys %$files ) {
      my $e = $files->{$p};
      next unless ref $e eq 'HASH' && ref $e->{content};
      $e->{content} = $self->_resolve( $e->{content}, $field.'.'.$dev.'.files.'.$p.'.content' );
    }
  }
  eval { $self->simulators->prepare($s); 1 } or do {
    my $err = $@;
    die $err if Langertha::Holmgang::Error->caught($err);
    $self->_refuse( $field, "$err" =~ s/\s+\z//r );
  };
  return $s;
}

sub _call {
  my ( $self, $c, $field, $tools, $with_args ) = @_;
  $self->_keys_ok( $c, $field, qw( tool args ) );
  my $tool = $self->_text( $c->{tool}, $field.'.tool' );
  $self->_refuse( $field.'.tool', "the case offers no tool '".$tool."'" ) unless $tools->{$tool};
  my $args = $c->{args} // {};
  $self->_refuse( $field.'.args', 'not a hash' ) unless ref $args eq 'HASH';
  $self->_arg_patterns( $args, $field.'.args' ) unless $with_args;
  return $c;
}

sub _calls {
  my ( $self, $l, $field, $tools ) = @_;
  $self->_list( $l, $field, 1 );
  $self->_call( $l->[$_], $field.'['.$_.']', $tools, 1 ) for 0 .. $#$l;
  return $l;
}

# one rule; returns its kind
sub _rule {
  my ( $self, $r, $field, $tools, $state ) = @_;
  $self->_refuse( $field, 'not a hash' ) unless ref $r eq 'HASH';
  my @kind = grep { exists $r->{$_} } @RULE_KINDS;
  $self->_refuse( $field, 'exactly one kind: '.join( ', ', @RULE_KINDS ) ) unless @kind == 1;
  my $kind = $kind[0];
  $self->_text( $r->{title}, $field.'.title' );
  my %rest = %$r;
  delete @rest{qw( title required )};
  if ( $kind eq 'state' ) {
    my $path = delete $rest{state};
    $self->_matchers( { %rest, path => $path }, $field );
  }
  elsif ( $kind eq 'check' ) {
    $self->_check_rule( \%rest, $field, $state );
  }
  elsif ( $kind eq 'login' ) {
    $self->_keys_ok( \%rest, $field, qw( login result ) );
    my $l = $r->{login};
    $self->_keys_ok( $l, $field.'.login', qw( host user from key port iif daddr auth ) );
    $self->_text( $l->{$_}, $field.'.login.'.$_ ) for qw( host user from );
    for my $k (qw( key iif daddr )) { $self->_text( $l->{$k}, $field.'.login.'.$k ) if defined $l->{$k} }
    if ( defined $l->{port} ) {
      $self->_refuse( $field.'.login.port', 'port 1-65535' )
        unless !ref $l->{port} && $l->{port} =~ /\A\d+\z/ && $l->{port} >= 1 && $l->{port} <= 65535;
    }
    my $auth = $l->{auth} // ( defined $l->{key} ? 'publickey' : '' );
    $self->_refuse( $field.'.login.auth', 'publickey (with key) or password' )
      unless $auth eq 'password' || ( $auth eq 'publickey' && defined $l->{key} );
    my $v = $r->{result} // '';
    $self->_refuse( $field.'.result', 'allowed or denied' ) unless !ref $v && ( $v eq 'allowed' || $v eq 'denied' );
  }
  elsif ( $kind eq 'packet' ) {
    $self->_keys_ok( \%rest, $field, qw( packet verdict boot ) );
    $self->_packet( $r->{packet}, $field.'.packet' );
    my $v = $r->{verdict} // '';
    $self->_refuse( $field.'.verdict', 'accept or drop' ) unless !ref $v && ( $v eq 'accept' || $v eq 'drop' );
    if ( my $b = $r->{boot} ) {
      $self->_refuse( $field.'.boot', 'true or an absolute path' ) unless !ref $b || "$b" eq '1';
    }
  }
  else {
    $self->_keys_ok( \%rest, $field, $kind );
    if ( $kind eq 'unchanged_except' ) {
      my $p = $self->_list( $r->{unchanged_except}, $field.'.unchanged_except' );
      $self->_path( $p->[$_], $field.'.unchanged_except['.$_.']' ) for 0 .. $#$p;
    }
    elsif ( $kind eq 'only_tools' ) {
      my $l = $self->_list( $r->{only_tools}, $field.'.only_tools' );
      for my $i ( 0 .. $#$l ) {
        my $t = $l->[$i];
        $self->_refuse( $field.'.only_tools['.$i.']', "the case offers no tool '".( $t // '' )."'" )
          unless defined $t && !ref $t && $tools->{$t};
      }
    }
    elsif ( $kind eq 'calls' ) {
      my $l = $self->_list( $r->{calls}, $field.'.calls', 1 );
      $self->_call( $l->[$_], $field.'.calls['.$_.']', $tools ) for 0 .. $#$l;
    }
    else {
      $self->_call( $r->{not_called}, $field.'.not_called', $tools );
    }
  }
  return $kind;
}

# rule check: a command { host, command } on a copy of the end state, expect { exit, output, lines }
sub _check_rule {
  my ( $self, $r, $field, $state ) = @_;
  $self->_keys_ok( $r, $field, qw( check expect ) );
  my $c = $r->{check};
  $self->_refuse( $field.'.check', 'hash { host, command } expected' ) unless ref $c eq 'HASH';
  $self->_keys_ok( $c, $field.'.check', qw( host command ) );
  my $host = $self->_text( $c->{host}, $field.'.check.host' );
  $self->_refuse( $field.'.check.host', "no device '".$host."' in the state" ) unless ref( ( $state || {} )->{$host} ) eq 'HASH';
  my $e = $r->{expect};
  $self->_refuse( $field.'.expect', 'hash { exit, output, lines } missing' ) unless ref $e eq 'HASH';
  $self->_keys_ok( $e, $field.'.expect', qw( exit output lines ) );
  $self->_refuse( $field.'.expect', 'at least one expectation: exit, output or lines' ) unless grep { exists $e->{$_} } qw( exit output lines );
  $self->_num( $e->{exit}, $field.'.expect.exit', 0, 255 ) if exists $e->{exit};
  for my $k (qw( output lines )) {
    next unless exists $e->{$k};
    $self->_refuse( $field.'.expect.'.$k, 'hash of expectations expected' ) unless ref $e->{$k} eq 'HASH';
    $self->_matchers( $e->{$k}, $field.'.expect.'.$k, 1 );
  }
  $self->_text( $c->{command}, $field.'.check.command' );
  return;
}

# the packet of a rule packet: fields and values checked
sub _packet {
  my ( $self, $p, $field ) = @_;
  $self->_keys_ok( $p, $field, qw( host hook iif oif saddr daddr proto sport dport icmp_type icmp_code ct ct_status ) );
  $self->_text( $p->{host}, $field.'.host' );
  $self->_refuse( $field.'.hook', join( '|', sort keys %HOOK ) ) unless !ref $p->{hook} && $HOOK{ $p->{hook} // '' };
  my %fam;
  for my $k (qw( saddr daddr )) {
    my $a = $self->_text( $p->{$k}, $field.'.'.$k );
    $self->_refuse( $field.'.'.$k, 'IPv4 or IPv6 address' ) unless $a =~ /\A\d+\.\d+\.\d+\.\d+\z|\A[0-9a-f:]*:[0-9a-f:]*\z/i;
    $fam{$k} = $a =~ /:/ ? 1 : 0;
  }
  $self->_refuse( $field.'.daddr', 'same family as saddr' ) unless $fam{saddr} == $fam{daddr};
  $self->_refuse( $field.'.proto', join( '|', sort keys %L4 ) ) unless !ref $p->{proto} && $L4{ $p->{proto} // '' };
  my $l4 = $p->{proto} eq 'tcp' || $p->{proto} eq 'udp';
  for my $k (qw( sport dport )) {
    next unless defined $p->{$k};
    $self->_refuse( $field.'.'.$k, 'port 1-65535' ) unless !ref $p->{$k} && $p->{$k} =~ /\A\d+\z/ && $p->{$k} >= 1 && $p->{$k} <= 65535;
    $self->_refuse( $field.'.'.$k, 'only with tcp/udp' ) unless $l4;
  }
  $self->_refuse( $field.'.dport', 'missing (tcp/udp)' ) if $l4 && !defined $p->{dport};
  for my $k (qw( iif oif icmp_type icmp_code ct_status )) { $self->_text( $p->{$k}, $field.'.'.$k ) if defined $p->{$k} }
  if ( defined $p->{ct} ) {
    $self->_refuse( $field.'.ct', 'new|established|related|invalid' ) unless !ref $p->{ct} && $p->{ct} =~ /\A(?:new|established|related|invalid)\z/;
  }
  return;
}

__PACKAGE__->meta->make_immutable;
