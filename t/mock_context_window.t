#!/usr/bin/env perl
# The mock targets with a context window (k80): the variant setting
# context_window gives mock-solution / mock-text a window; a request estimated
# above it (Haystack::estimate_tokens over messages and tools) fails before any
# tool call in words Target classifies as context_exceeded; a case under it
# runs as before; the tier curve of the evaluation shows the cut; a real engine
# refuses the setting. Network-free; invented suites only (ADR 0003).
use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/lib";
use Test::More;
use Test::Fatal qw( exception );

use Holmgang::CLI qw( cli );
use Holmgang::SuiteDir qw( suite_dir loader $FAN_CASE );
use Langertha::Engine::Virtual;
use Langertha::Holmgang::Batch;
use Langertha::Holmgang::Evaluation;
use Langertha::Holmgang::Haystack;
use Langertha::Holmgang::Report;
use Langertha::Holmgang::Runner;
use Langertha::Holmgang::Target;

# a short case in the 16k tier, a long one (about 2000 estimated tokens) in the 48k tier
my $SHORT = $FAN_CASE =~ s/^title: .*$/title: Cool the room\ntags: [stufe-16k]/mr;
my $LONG  = ( $FAN_CASE =~ s/^id: c1$/id: c2/mr =~ s/^title: .*$/title: Cool the long room\ntags: [stufe-48k]/mr )
  =~ s/content: "It is hot in here\."/'content: "It is hot in here. '.( 'warm air ' x 780 ).'"'/er;
my $root = Path::Tiny->tempdir;
my $dir  = suite_dir( id => 'cw-fan', root => $root, cases => { 'c1.yaml' => $SHORT, 'c2.yaml' => $LONG } );
my $suite = loader()->load($dir);
my ( $short, $long ) = @{ $suite->cases };

sub play {
  my ( $case, $mode, %o ) = @_;
  my $runner = Langertha::Holmgang::Runner->new(
    target => Langertha::Holmgang::Target->new( engine => Langertha::Holmgang::Runner->mock_engine( $case, $mode, %o ) ) );
  return $runner->run_case($case);
}

subtest 'mock_engine with a window' => sub {
  my $r = play( $short, 'solution', context_window => 1000 );
  is( $r->{status}, 'passed', 'a case under the window passes' );
  is( scalar @{ $r->{calls} }, 1, '... with its call' );

  $r = play( $long, 'solution', context_window => 1000 );
  is( $r->{status}, 'context_exceeded', 'a longer case is context_exceeded' );
  like( $r->{error}, qr/request \((\d+) tokens\) exceeds the available context size \(1000 tokens\)/, '... in llama.cpp\'s words' );
  my ($n) = $r->{error} =~ /request \((\d+) tokens\)/;
  ok( $n > 2000 && $n < 2600, '... the estimate is the haystack\'s measure ('.$n.')' );
  is_deeply( $r->{calls}, [], '... before any tool call' );
  is( scalar @{ $r->{turns} }, 1, '... one failed turn' );
  is( $r->{turns}[0]{input_tokens}, undef, '... the mock reports no usage' );

  is( play( $long, 'text', context_window => 1000 )->{status}, 'context_exceeded', 'mock-text too' );
  is( play( $long, 'solution', context_window => 5000 )->{status}, 'passed', 'the same case under a larger window passes' );
  is( play( $long, 'solution' )->{status}, 'passed', '... and without a window, as before' );

  # the estimate: the message texts, the tool calls, the tool schemas
  my $text = 'a' x 350;
  my $tools = [ { type => 'function', function => { name => 'x', parameters => {} } } ];
  my $est = Langertha::Holmgang::Runner->_request_tokens( { messages => [
      { role => 'user', content => [ { type => 'text', text => $text }, { type => 'image_url', image_url => { url => 'data:'.( 'b' x 9999 ) } } ] },
      { role => 'assistant', content => undef, tool_calls => [ { function => { name => 'fan_set', arguments => '{"level":"high"}' } } ] },
    ], tools => $tools } );
  my $want = Langertha::Holmgang::Haystack->estimate_tokens( join "\n", $text, 'fan_set', '{"level":"high"}' )
    + Langertha::Holmgang::Haystack->estimate_tokens( JSON::MaybeXS->new( canonical => 1 )->encode($tools) );
  is( $est, $want, 'the estimate counts texts, tool calls and tool schemas, not images' );

  for my $bad ( 0, -5, '1.5', 'big' ) {
    like( exception { Langertha::Holmgang::Runner->mock_engine( $short, 'solution', context_window => $bad ) },
      qr/context_window must be a whole number/, 'mock_engine refuses context_window '.$bad );
  }
};

subtest 'the variant setting' => sub {
  my $T = 'Langertha::Holmgang::Target';
  is_deeply( $T->check_variant( { context_window => '16000' } ), { context_window => 16000 }, 'context_window: a number of tokens' );
  for my $bad ( 0, '1.5', 'big', 10_000_000 ) {
    like( exception { $T->check_variant( { context_window => $bad } ) }, qr/variant\.context_window: tokens, a whole number/, 'refused: '.$bad );
  }
  is( exception { $T->check_variant( { context_window => 100 }, Langertha::Engine::Virtual->new( script => ['x'] ) ) }, undef,
    'accepted on the mock' );
  {
    package Local::RealEngine;
    use Moose;
    extends 'Langertha::Engine::Virtual';
    sub isa { $_[1] eq 'Langertha::Engine::Virtual' ? 0 : shift->SUPER::isa(@_) }
  }
  like( exception { $T->check_variant( { context_window => 100 }, Local::RealEngine->new( script => ['x'] ) ) },
    qr/variant\.context_window: .*is no mock target/, 'refused on any other engine' );
  is_deeply( $T->for_variant( engine => Langertha::Engine::Virtual->new( script => ['x'] ), settings => { context_window => 100, max_tokens => 5 } )->variant,
    { max_tokens => 5 }, 'no request option: for_variant leaves it out' );
  like( exception { Langertha::Holmgang::Batch->new( suites => [$suite],
      targets => [ { engine => Langertha::Engine::Virtual->new( script => ['x'] ), variants => [ { name => 'w', settings => { context_window => 100 } } ] } ] ) },
    qr/context_window needs an engine code/, 'the batch refuses it with one engine object for every case' );
};

subtest 'the tier curve shows the cut' => sub {
  my $batch = Langertha::Holmgang::Batch->new(
    suites  => [$suite],
    targets => [ {
      target   => { label => 'mock' },
      engine   => sub { my ( $case, $slot, $s ) = @_;
        Langertha::Holmgang::Runner->mock_engine( $case, 'solution', ( $s->{context_window} ? ( context_window => $s->{context_window} ) : () ) ) },
      variants => [ { name => 'w1k', settings => { context_window => 1000 } }, { name => 'w5k', settings => { context_window => 5000 } } ],
    } ],
  );
  my $report = $batch->run;
  is_deeply( $report->runs->[0]{variant}, { name => 'w1k', settings => { context_window => 1000 } }, 'the report names the window' );
  my $ev = Langertha::Holmgang::Evaluation->new( report => $report );
  my %curve = map { ( $_->{variant}.' '.$_->{tier} => $_ ) } @{ $ev->tier_curves };
  is( $curve{'w1k 16k'}{rate}, 1, 'window 1000: the 16k tier passes' );
  is( $curve{'w1k 48k'}{context_exceeded_rate}, 1, '... the 48k tier is all context_exceeded' );
  is( $curve{'w1k 48k'}{error_rate}, 0, '... not error' );
  is( $curve{'w5k 48k'}{rate}, 1, 'window 5000: the 48k tier passes' );
  is( $curve{'w5k 48k'}{context_exceeded_rate}, 0, '... nothing exceeded' );
  like( $ev->to_text, qr/^mock\s+w1k\s+\S+\s+48k\s+1\s+0[.,]0\s*%\s+100[.,]0\s*%/m, 'the text table shows it' ) or diag $ev->to_text;
};

subtest 'holmgang run' => sub {
  my ( $code, $out, $err ) = cli( run => '--suite', $dir, '--target', 'mock-solution',
    '--variant', 'w1k:context_window=1000', '--variant', 'w5k:context_window=5000' );
  like( $out, qr/^w1k cw-fan c1 #1 passed$/m, 'a case under the window passes' );
  like( $out, qr/^w1k cw-fan c2 #1 context_exceeded$/m, '... a longer one is context_exceeded' );
  like( $out, qr/^w5k cw-fan c2 #1 passed$/m, '... and passes under a larger window' );
  is( $code, 0, '... a measurement: exit 0' ) or diag $out, $err;

  ( $code, $out ) = cli( run => '--suite', $dir, '--target', 'mock-text', '--variant', 'context_window=1000' );
  like( $out, qr/^cw-fan c2 #1 context_exceeded$/m, 'mock-text, the unnamed variant' );
  like( $out, qr/\bcontext_window=1000\b/, '... named by its setting' );

  ( $code, undef, $err ) = cli( run => '--suite', $dir, '--target', 'Virtual', '--variant', 'context_window=1000' );
  is( $code, 2, 'another target: exit 2' );
  like( $err, qr/context_window applies only to mock-solution and mock-text/, '... said' );
  ( $code, undef, $err ) = cli( run => '--suite', $dir, '--target', 'mock-solution', '--variant', 'context_window=0' );
  is( $code, 2, 'a window of 0: exit 2' );
  like( $err, qr/variant\.context_window/, '... said' );
};

done_testing;
