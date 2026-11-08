package Langertha::Holmgang::CLI;
# ABSTRACT: The holmgang command: lint suites, run them against a Langertha engine, evaluate reports

use Moose;
use namespace::autoclean;
use Encode ();
use Getopt::Long ();
use JSON::MaybeXS ();
use Module::Runtime qw( use_module );
use Path::Tiny qw( path );
use Scalar::Util qw( blessed );
use Langertha::Holmgang::Evaluation;
use Langertha::Holmgang::Loader;
use Langertha::Holmgang::Report;
use Langertha::Holmgang::Runner;
use Langertha::Holmgang::Target;

our $VERSION = '0.001';

=synopsis

  use Langertha::Holmgang::CLI;

  exit Langertha::Holmgang::CLI->new->run(@ARGV);

  # in a test: capture the output, get the exit code
  open my $out, '>', \my $text;
  my $code = Langertha::Holmgang::CLI->new( out => $out, err => $out )
    ->run( lint => '/tmp/suites/demo' );

=description

The commands behind F<bin/holmgang> (ADR 0009): C<lint> loads suites as the
loader does, C<run> plays them against a target and writes a report, C<report>
evaluates report files per topic. Every command returns its exit code instead
of exiting: C<0> all well, C<1> a suite refused, a verdict not ok, or a run in
which the target answered no case, C<2> a usage or setup error. The options
are described in L<holmgang>.

The CLI reads no key: a real engine takes its key from where Langertha reads
it (its environment variable). There is no default target.

=cut

has out => ( is => 'ro', lazy_build => 1 );

sub _build_out { \*STDOUT }

=attr out

The handle for the command's output; standard output by default.

=cut

has err => ( is => 'ro', lazy_build => 1 );

sub _build_err { \*STDERR }

=attr err

The handle for usage and setup errors; standard error by default.

=cut

has loader => ( is => 'ro', lazy_build => 1 );

sub _build_loader { $_[0]->loader_class->new }

=attr loader

The L<Langertha::Holmgang::Loader> every suite goes through.

=cut

sub loader_class     { 'Langertha::Holmgang::Loader' }
sub runner_class     { 'Langertha::Holmgang::Runner' }
sub target_class     { 'Langertha::Holmgang::Target' }
sub report_class     { 'Langertha::Holmgang::Report' }
sub evaluation_class { 'Langertha::Holmgang::Evaluation' }

# the statuses of a result the target gave no answer for (ADR 0006)
my %NO_ANSWER = map { $_ => 1 } qw( error context_exceeded no_vision );

# the targets that need no network and no key (ADR 0009)
my %MOCK = ( 'mock-solution' => 'solution', 'mock-text' => 'text' );

my $JSON = JSON::MaybeXS->new( utf8 => 0, canonical => 1, allow_nonref => 1 );

#### Plumbing

sub _say { my ( $self, @l ) = @_; print { $self->out } map { $_."\n" } @l; return }

sub _usage_error {
  my ( $self, $msg ) = @_;
  print { $self->err } 'holmgang: '.$msg."\n", "Try 'holmgang help'.\n";
  return 2;
}

# Every die text the CLI relays goes through here (k41): a Path::Tiny error
# down to its reason (the message names the path already, not a temporary file
# next to it), no Perl location (Target's rule), no module search path.
sub _text {
  my ( $self, $err ) = @_;
  my $text = blessed $err && $err->isa('Path::Tiny::Error') ? $err->{err} =~ s/\A.*: //sr
           : blessed $err ? "$err"
           :                $err // '';
  $text = $self->target_class->_strip_location($text);
  $text =~ s/\s*\(\@INC (?:contains|entries checked): [^)]*\)//;
  return $text =~ s/\s+\z//r;
}

sub _options {
  my ( $self, $args, @spec ) = @_;
  my @warn;
  local $SIG{__WARN__} = sub { push @warn, $_[0] };
  my $p = Getopt::Long::Parser->new( config => [qw( no_ignore_case no_auto_abbrev )] );
  my %o;
  my $ok = $p->getoptionsfromarray( $args, \%o, @spec );
  return ( undef, join( '', @warn ) =~ s/\s+\z//r || 'bad options' ) unless $ok;
  return ( \%o, undef );
}

# K=V; the value as JSON when it parses as such, else as written
sub _pairs {
  my ( $self, $what, $list ) = @_;
  my %h;
  for my $p ( @{ $list || [] } ) {
    my ( $k, $v ) = $p =~ /\A([A-Za-z_][A-Za-z0-9_]*)=(.*)\z/s
      or return ( undef, $what.' expects KEY=VALUE, got: '.$p );
    my $d = eval { $JSON->decode($v) };
    $h{$k} = $@ ? $v : $d;
  }
  return ( \%h, undef );
}

sub run {
  my ( $self, @argv ) = @_;
  my $cmd = shift @argv;
  return $self->_usage_error('a command is needed: lint, run or report') unless defined $cmd;
  return $self->help if $cmd =~ /\A(?:help|--help|-h)\z/;
  my $method = { lint => 'cmd_lint', run => 'cmd_run', report => 'cmd_report' }->{$cmd}
    or return $self->_usage_error( 'unknown command: '.$cmd );
  return $self->$method(@argv);
}

=method run

  my $code = $cli->run( 'lint', @dirs );

Runs one command with its arguments (C<@ARGV> as the shell gives it) and
returns the exit code. C<help>, C<--help> and C<-h> print the usage.

=cut

sub help {
  my ( $self ) = @_;
  $self->_say(
    'usage: holmgang lint <suite-dir>...',
    '       holmgang run --suite <dir>... --target <engine|mock-solution|mock-text>',
    '                    [--model M] [--url U] [--option K=V]... [--label L]',
    '                    [--variant K=V]... [--repeat N] [--report out.json]',
    '       holmgang report <report.json>... [--by topic] [--format text|markdown|json] [--suite <dir>]...',
    '',
    'Exit codes: 0 ok, 1 a suite refused, a verdict not ok or no case answered, 2 usage or setup error.',
    'Keys come from the engine\'s environment variable (e.g. LANGERTHA_OPENAI_API_KEY), never from the command line.',
  );
  return 0;
}

=method help

Prints the usage; returns 0.

=cut

#### lint

# the suite directories an argument names: itself, or its subdirectories with a suite.yaml
sub _suite_dirs {
  my ( $self, $arg ) = @_;
  my $p = path($arg);
  return unless $p->is_dir;
  return ( "$p" ) if -f $p->child('suite.yaml');
  return map { "$_" } sort { $a->basename cmp $b->basename } grep { $_->is_dir && -f $_->child('suite.yaml') } $p->children;
}

sub cmd_lint {
  my ( $self, @argv ) = @_;
  my ( $o, $bad ) = $self->_options( \@argv );
  return $self->_usage_error($bad) if $bad;
  return $self->_usage_error('lint needs at least one suite directory') unless @argv;
  my @dirs;
  for my $arg ( @argv ) {
    my @d = $self->_suite_dirs($arg);
    return $self->_usage_error( 'no suite at or below '.$arg ) unless @d;
    push @dirs, @d;
  }
  my ( $ok, $refused ) = ( 0, 0 );
  for my $dir ( @dirs ) {
    my $suite = eval { $self->loader->load($dir) };
    if ( $suite ) {
      $ok++;
      my @cases = @{ $suite->cases };
      $self->_say( 'ok   '.$suite->id.' ('.scalar(@cases).' case'.( @cases == 1 ? '' : 's' ).')', map { '  ok '.$_->id } @cases );
    }
    else {
      $refused++;
      $self->_say( 'FAIL '.path($dir)->basename, '  '.$self->_text($@) );
    }
  }
  $self->_say( scalar(@dirs).' suite'.( @dirs == 1 ? '' : 's' ).': '.$ok.' ok, '.$refused.' refused' );
  return $refused ? 1 : 0;
}

=method cmd_lint

  my $code = $cli->cmd_lint(@dirs);

C<holmgang lint>: loads every suite (a suite directory, or each suite in a
search directory) through L</loader> -- structure, lint and both mock runs.
Prints C<ok> with every case id, or C<FAIL> with the refusal (it names the
case file and field; loading stops at the first refused case). Returns 1 when
a suite was refused, 2 for a path that holds no suite.

=cut

#### run

sub _load_suites {
  my ( $self, $dirs ) = @_;
  my @suites;
  for my $arg ( @{ $dirs || [] } ) {
    return ( undef, 'not a suite directory (no suite.yaml): '.$arg ) unless -f path($arg)->child('suite.yaml');
    my $s = eval { $self->loader->load($arg) };
    return ( undef, 'suite '.$arg.' does not load: '.$self->_text($@) ) unless $s;
    push @suites, $s;
  }
  return ( \@suites, undef );
}

sub _thresholds {
  my ( $self, $suites ) = @_;
  return { map { ( $_->id => $_->threshold ) } grep { ref $_->threshold eq 'HASH' } @$suites };
}

# ( $engine_for_case, $target_meta ) or ( undef, $error )
sub _target {
  my ( $self, $o ) = @_;
  my $name = $o->{target};
  return ( undef, 'run needs --target (an engine name such as OpenAI, or mock-solution / mock-text)' )
    unless defined $name && length $name;
  if ( my $mode = $MOCK{$name} ) {
    return ( undef, '--model, --url and --option do not apply to '.$name )
      if defined $o->{model} || defined $o->{url} || @{ $o->{option} || [] };
    my $runner = $self->runner_class;
    return ( sub { $runner->mock_engine( $_[0], $mode ) },
      { label => $o->{label} // $name, engine => 'Virtual', model => undef, url => undef } );
  }
  return ( undef, 'not an engine name: '.$name ) unless $name =~ /\A[A-Za-z_]\w*(?:::\w+)*\z/;
  my ( $opt, $bad ) = $self->_pairs( '--option', $o->{option} );
  return ( undef, $bad ) if $bad;
  return ( undef, '--option api_key is refused: the key comes from the engine\'s environment variable, never from the command line' )
    if exists $opt->{api_key};
  $opt->{model} = $o->{model} if defined $o->{model};
  $opt->{url}   = $o->{url}   if defined $o->{url};
  my $class = $name =~ /::/ ? $name : 'Langertha::Engine::'.$name;
  # a notice of the engine while it is built (a setting it drops): to stderr,
  # cleaned as a relayed error (k42)
  my @warn;
  my $engine = do {
    local $SIG{__WARN__} = sub { push @warn, $_[0] };
    eval { use_module($class)->new(%$opt) };
  };
  print { $self->err } map { 'holmgang: '.$self->target_class->scrub( $self->_text($_) )."\n" } @warn;
  return ( undef, 'target '.$name.' does not build: '.$self->target_class->scrub( $self->_text($@) ) ) unless $engine;
  return ( undef, 'target '.$name.' is no chat engine with tool calling (chat_f, format_tool_results)' )
    unless $engine->can('chat_f') && $engine->can('format_tool_results');
  my $model = $engine->can('model') ? eval { $engine->model } : undef;
  my $url   = $engine->can('url')   ? eval { $engine->url }   : undef;
  my $short = $class =~ s/\ALangertha::Engine:://r;
  return ( sub { $engine },
    { label => $o->{label} // $model // $short, engine => $short, model => $model, url => $url } );
}

sub cmd_run {
  my ( $self, @argv ) = @_;
  my ( $o, $bad ) = $self->_options( \@argv,
    'suite=s@', 'target=s', 'model=s', 'url=s', 'option=s@', 'label=s', 'variant=s@', 'repeat=i', 'report=s' );
  return $self->_usage_error($bad) if $bad;
  return $self->_usage_error( 'unexpected argument: '.$argv[0] ) if @argv;
  return $self->_usage_error('run needs at least one --suite') unless @{ $o->{suite} || [] };
  return $self->_usage_error('--repeat must be between 1 and 100')
    if defined $o->{repeat} && ( $o->{repeat} < 1 || $o->{repeat} > 100 );
  my ( $settings, $vbad ) = $self->_pairs( '--variant', $o->{variant} );
  return $self->_usage_error($vbad) if $vbad;
  my ( $engine_for, $target ) = $self->_target($o);
  return $self->_usage_error($target) unless $engine_for;
  my ( $suites, $sbad ) = $self->_load_suites( $o->{suite} );
  return $self->_usage_error($sbad) if $sbad;

  my $variant = {
    name     => %$settings ? join( ',', map { $_.'='.$JSON->encode( $settings->{$_} ) =~ s/\A"(.*)"\z/$1/sr } sort keys %$settings ) : 'default',
    settings => $settings,
  };
  my $report = $self->report_class->new;
  my $aborted = 0;
  my ( @unanswered, @silent );   # the statuses without an answer; suites with nothing else
  my $measured = 0;
  my $first_error;   # the first error text of the run, for the no-answer note (k44)
  for my $suite ( @$suites ) {
    my $repeat = $o->{repeat} // $suite->repeat // 1;
    my ( @results, $error );
    REP: for my $n ( 1 .. $repeat ) {
      for my $case ( @{ $suite->cases } ) {
        my $result = eval {
          my $runner = $self->runner_class->new(
            target => $self->target_class->new( engine => $engine_for->($case), variant => $settings ),
          );
          $runner->run_case( $case, repetition => $n );
        };
        unless ( $result ) {
          $error = $self->target_class->scrub( $self->_text($@) );
          $self->_say( $suite->id.' '.$case->id.' #'.$n.' aborted: '.$error );
          last REP;
        }
        push @results, $result;
        $self->_say( $suite->id.' '.$case->id.' #'.$n.' '.$result->{status} );
      }
    }
    $aborted++ if defined $error;
    # @results run repetition by repetition, case by case; the first of them is also
    # the first in suite, case and repetition order
    ( $first_error ) = grep { defined && length } map { $_->{error} } @results unless defined $first_error;
    my @none = grep { $NO_ANSWER{$_} } map { $_->{status} } @results;
    push @unanswered, @none;
    $measured += @results - @none;
    push @silent, [ $suite->id, $self->_tally(@none) ] if @results && @results == @none;
    $report->add_run(
      target  => $target,
      variant => $variant,
      suite   => { id => $suite->id, version => $suite->version, topic => $suite->topic, digest => $suite->checksum },
      repeat  => $repeat,
      status  => defined $error ? 'aborted' : 'complete',
      error   => $error,
      cases   => [ map { +{
        case_id   => $_->id,
        title     => $_->title,
        tags      => $_->tags,
        tier      => scalar $_->tier,
        weight    => $_->effective_weight,
        hard      => $_->is_hard,
        untrusted => $_->has_untrusted,
      } } @{ $suite->cases } ],
      results => \@results,
    );
  }
  $report->finish;
  if ( defined $o->{report} ) {
    eval { $report->write( $o->{report} ); 1 }
      or return $self->_usage_error( 'report '.$o->{report}.' not written: '.$self->_text($@) );
  }
  my $ev = $self->evaluation_class->new( report => $report, thresholds => $self->_thresholds($suites) );
  $self->_say( '', $ev->to_text );
  $self->_say( 'report: '.$o->{report} ) if defined $o->{report};
  return 2 if $aborted;
  # no answer over the whole run: nothing was measured, whatever the verdicts (k42)
  unless ( $measured ) {
    print { $self->err } 'holmgang: no case got an answer from the target ('
      .$self->_tally(@unanswered).')'
      .( defined $first_error ? '; first: '.$self->_one_line($first_error) : '' )."\n";
    return 1;
  }
  print { $self->err } 'holmgang: suite '.$_->[0].': no case got an answer from the target ('.$_->[1].')'."\n" for @silent;
  return ( grep { !$_->{ok} } @{ $ev->verdicts } ) ? 1 : 0;
}

# an error text for a note: on one line, cut to 200 characters with an ellipsis.
# The result's error went through the target's scrub already (chat_turn_f).
sub _one_line {
  my ( $self, $text ) = @_;
  $text = join ' ', split ' ', $text;
  return $text if length $text <= 200;
  return substr( $text, 0, 200 ) =~ s/\s+\z//r." \x{2026}";
}

# "2 error, 1 context_exceeded" in the order of the statuses
sub _tally {
  my ( $self, @statuses ) = @_;
  my %n;
  $n{$_}++ for @statuses;
  return join ', ', map { $n{$_}.' '.$_ } grep { $n{$_} } qw( error context_exceeded no_vision );
}

=method cmd_run

  my $code = $cli->cmd_run( '--suite', $dir, '--target', 'mock-solution', '--report', $file );

C<holmgang run>: loads the suites, builds the target (an engine name with
C<--model>, C<--url>, C<--option>; or C<mock-solution> / C<mock-text>), plays
every case C<--repeat> times (default the suite's C<repeat>, else 1), one at a
time, prints a line per result and the evaluation, and writes the report with
C<--report>. Returns 1 when a verdict is not ok, 2 for a usage or setup error
or an aborted run.

When the target answered no case of the whole run -- every result, over all
suites and repetitions, is C<error>, C<context_exceeded> or C<no_vision> -- the
run measured nothing: it says so on the error handle with the count per status
and the first error text of the run (the first result in suite, case and
repetition order; already scrubbed by the target, put on one line, cut to 200
characters with an ellipsis) and returns 1, whatever the verdicts. The report is written as always. When at
least one result was measured, the verdicts decide; a suite in which no case
got an answer then gets a note on the error handle. An aborted run stays 2.
The engine's warnings while it is built go to the error handle, cleaned like
a relayed error.

=cut

#### report

sub cmd_report {
  my ( $self, @argv ) = @_;
  my ( $o, $bad ) = $self->_options( \@argv, 'by=s', 'format=s', 'suite=s@' );
  return $self->_usage_error($bad) if $bad;
  return $self->_usage_error('report needs at least one report file') unless @argv;
  my $by = $o->{by} // 'topic';
  return $self->_usage_error( '--by '.$by.': the evaluation is per topic, --by topic is the only one' )
    unless $by eq 'topic';
  my $format = $o->{format} // 'text';
  return $self->_usage_error( 'unknown --format '.$format.' (text, markdown, json)' )
    unless $format =~ /\A(?:text|markdown|json)\z/;
  my @reports;
  for my $file ( @argv ) {
    my $r = eval { $self->report_class->read($file) };
    return $self->_usage_error( 'report '.$file.' does not read: '.$self->_text($@) ) unless $r;
    push @reports, $r;
  }
  my ( $suites, $sbad ) = $self->_load_suites( $o->{suite} );
  return $self->_usage_error($sbad) if $sbad;
  my $ev = eval { $self->evaluation_class->new( reports => \@reports, thresholds => $self->_thresholds($suites) ) };
  return $self->_usage_error( 'reports do not evaluate: '.$self->_text($@) ) unless $ev;
  my $verdicts = eval { $ev->verdicts };
  return $self->_usage_error( 'reports do not evaluate: '.$self->_text($@) ) unless $verdicts;
  my $text = $format eq 'json'     ? Encode::decode( 'UTF-8', $ev->to_json )
           : $format eq 'markdown' ? $ev->to_markdown
           :                         $ev->to_text;
  $text .= "\n" unless $text =~ /\n\z/;
  print { $self->out } $text;
  return ( grep { !$_->{ok} } @$verdicts ) ? 1 : 0;
}

=method cmd_report

  my $code = $cli->cmd_report( @files, '--format', 'markdown', '--suite', $dir );

C<holmgang report>: reads the report files, joins them in one
L<Langertha::Holmgang::Evaluation> and prints it as text, Markdown or JSON.
Thresholds come from the suites given with C<--suite>; without them only the
hard cases decide a verdict. Returns 1 when a verdict is not ok, 2 when a file
does not read or the reports conflict.

=cut

__PACKAGE__->meta->make_immutable;

1;

=seealso

=over 4

=item * L<holmgang>

=item * L<Langertha::Holmgang::Runner>

=item * L<Langertha::Holmgang::Evaluation>

=back

=cut
