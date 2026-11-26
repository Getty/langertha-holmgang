#!/usr/bin/env perl
# Langertha::Holmgang::Batch, a dead target (k74): after max_consecutive_errors
# results error in a row (per target and variant, in the order they end) no
# further case of that target and variant starts, the cases in play finish,
# its runs are aborted with a reason, the missing cases get no result; any
# other status starts the count anew; other variants go on; a resume plays the
# missing cases and the results error again. Network-free:
# Langertha::Engine::Virtual and test engines over it; invented suites only
# (ADR 0003).
use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/lib";
use Test::More;
use Test::Fatal qw( exception );

use Holmgang::SuiteDir qw( suite_dir loader $FAN_CASE );
use Holmgang::HeldEngine;
use Langertha::Engine::Virtual;
use Langertha::Virtual::Rules qw( answer tool after error );
use Langertha::Holmgang::Batch;
use Langertha::Holmgang::Evaluation;
use Langertha::Holmgang::Report;

sub fan_suite {
  my ( $id, $n ) = @_;
  return loader()->load( suite_dir( id => $id, cases => { map { ( "c$_.yaml" => $FAN_CASE =~ s/^id: c1$/id: c$_/mr ) } 1 .. $n } ) );
}

sub fan_rules { ( rules => [ after('fan_set') => answer('done'), qr/./ => tool( fan_set => { level => 'high' } ) ] ) }

my $KEY = 'hgtest0dead0key0invented0do0not0use';
sub dead   { Langertha::Engine::Virtual->new( api_key => $KEY, rules => [ qr/./ => error( 500, 'CUDA failed with key '.$KEY ) ] ) }
sub alive  { Langertha::Engine::Virtual->new( fan_rules() ) }
sub window { Langertha::Engine::Virtual->new( rules => [ qr/./ => error( 400, 'request (90000 tokens) exceeds the available context size (8192 tokens)' ) ] ) }

sub statuses {
  my ( $run ) = @_;
  return { map { my $c = $_; ( $c->{case_id} => [ map { $_->{status} } @{ $c->{repetitions} } ] ) } @{ $run->{cases} } };
}

my $s6 = fan_suite( 'dead-six', 6 );
my $s2 = fan_suite( 'dead-two', 2 );

subtest 'a series of N errors stops the run; the rest gets no result' => sub {
  my ( @events, @played );
  my $batch = Langertha::Holmgang::Batch->new(
    suites   => [ $s6, $s2 ],
    targets  => [ { target => { label => 'gpu' }, engine => sub { dead() } } ],
    max_consecutive_errors => 3,
    on_event => sub { push @events, $_[0]; push @played, $_[0]{case}->id if $_[0]{type} eq 'result' },
  );
  my $report = $batch->run;
  is_deeply( \@played, [qw( c1 c2 c3 )], 'three cases played, then no further one' );
  my ( $a, $b ) = @{ $report->runs };
  is( $a->{status}, 'aborted', 'the run is aborted' );
  like( $a->{error}, qr/\Athe target failed 3 cases in a row \(status error\), so no further case of this target and variant starts; the last error: /,
    '... its error names the series' );
  like( $a->{error}, qr/500 Internal Server Error - .*CUDA failed/, '... and the last error text' );
  unlike( $report->to_json, qr/\Q$KEY\E/, '... scrubbed: the key is nowhere in the report' );
  is_deeply( statuses($a), { ( map { ( "c$_" => ['error'] ) } 1 .. 3 ), ( map { ( "c$_" => [] ) } 4 .. 6 ) },
    '... the missing cases have no result, not error' );
  is( $b->{status}, 'aborted', 'the next suite of the same target and variant is aborted too' );
  is( $b->{error}, $a->{error}, '... with the same reason' );
  is_deeply( statuses($b), { c1 => [], c2 => [] }, '... and none of its cases started' );
  my @aborted = grep { $_->{type} eq 'aborted' } @events;
  is( scalar @aborted, 1, 'one aborted event' );
  is( $aborted[0]{consecutive_errors}, 3, '... with the length of the series' );
  is( $aborted[0]{case}->id.'#'.$aborted[0]{repetition}, 'c3#1', '... for the case that completed it' );
  is( $aborted[0]{error}, $a->{error}, '... and the run\'s error' );
  is( $events[-1]{type}, 'aborted', '... after that case\'s result' );

  # the evaluation counts no missing case as failed
  my $ev = Langertha::Holmgang::Evaluation->new( report => $report );
  my ($v) = grep { $_->{suite_id} eq 'dead-six' } @{ $ev->verdicts };
  is( $v->{results}, 3, 'the evaluation counts the three results only' );
  is_deeply( [ @{ $v->{counts} }{qw( error failed passed )} ], [ 3, 0, 0 ], '... three error, nothing failed' );
  ok( !$v->{ok}, '... the verdict is not ok' );
  is( $v->{unfinished}{status}, 'aborted', '... unfinished: aborted' );
  like( $ev->to_text, qr/run aborted: the target failed 3 cases in a row/, '... the text says why' );
};

subtest 'the default is 10; 0 turns it off' => sub {
  my $s12 = fan_suite( 'dead-twelve', 12 );
  my $r = Langertha::Holmgang::Batch->new( suites => [$s12], targets => [ { engine => sub { dead() } } ] )->run->runs->[0];
  is( $r->{status}, 'aborted', 'default: aborted' );
  is( scalar( grep { @$_ } values %{ statuses($r) } ), 10, '... after 10 errors' );
  my $off = Langertha::Holmgang::Batch->new( suites => [$s12], targets => [ { engine => sub { dead() } } ], max_consecutive_errors => 0 )
    ->run->runs->[0];
  is( $off->{status}, 'complete', '0: never aborted' );
  is_deeply( statuses($off), { map { ( "c$_" => ['error'] ) } 1 .. 12 }, '... every case played' );
};

subtest 'any other status starts the count anew' => sub {
  my $s7 = fan_suite( 'dead-seven', 7 );
  # c3 answers, c5 hits the window: error error passed error context_exceeded error error error
  my %engine = ( c3 => \&alive, c5 => \&window );
  my $report = Langertha::Holmgang::Batch->new( suites => [$s7],
    targets => [ { engine => sub { ( $engine{ $_[0]->id } // \&dead )->() } } ], max_consecutive_errors => 3 )->run;
  my $r = $report->runs->[0];
  is_deeply( statuses($r), { c1 => ['error'], c2 => ['error'], c3 => ['passed'], c4 => ['error'], c5 => ['context_exceeded'],
    c6 => ['error'], c7 => ['error'] }, 'a measured result and a context_exceeded reset the series' );
  is( $r->{status}, 'complete', '... so the run completes' );

  my $s8 = fan_suite( 'dead-eight', 8 );
  my $r8 = Langertha::Holmgang::Batch->new( suites => [$s8],
    targets => [ { engine => sub { ( $_[0]->id eq 'c1' ? \&alive : \&dead )->() } } ], max_consecutive_errors => 3 )->run->runs->[0];
  is_deeply( [ map { scalar @{ statuses($r8)->{"c$_"} } } 1 .. 8 ], [ 1, 1, 1, 1, 0, 0, 0, 0 ], 'a series after a pass: three errors, then stop' );
  is( $r8->{status}, 'aborted', '... aborted' );
};

subtest 'the cases in play finish' => sub {
  my $e = Holmgang::HeldEngine->new( rules => [ qr/./ => error( 500, 'CUDA failed' ) ] );
  my @played;
  my $batch = Langertha::Holmgang::Batch->new( suites => [$s6], targets => [ { engine => $e, concurrency => 3 } ],
    max_consecutive_errors => 2, on_event => sub { push @played, $_[0]{case}->id if $_[0]{type} eq 'result' } );
  my $f = $batch->run_f;
  is( $e->in_flight, 3, 'three requests open' );
  $e->release;
  is( $e->in_flight, 3, 'one error: the series is not complete, c4 takes the free slot' );
  $e->release;
  is_deeply( \@played, [qw( c1 c2 )], 'two errors: the series is complete' );
  is( $e->in_flight, 2, '... no further case started, c3 and c4 still in play' );
  my $mid = $batch->report->runs->[0];
  is( $mid->{status}, 'aborted', 'a checkpoint now: aborted' );
  like( $mid->{error}, qr/\Athe target failed 2 cases in a row/, '... with the reason, not unfinished' );
  $e->release for 1 .. 2;
  ok( $f->is_done, 'the batch finished' );
  is_deeply( \@played, [qw( c1 c2 c3 c4 )], 'the cases in play finished and have their results' );
  is( scalar @{ $e->requests }, 4, '... no request beyond those four' );
  is( $f->get->runs->[0]{status}, 'aborted', '... the run aborted' );
};

subtest 'another variant goes on' => sub {
  # the variant with max_tokens 7 meets a dead target, the other one a live one
  my $engine = sub {
    Langertha::Engine::Virtual->new( rules => [
      sub { ( $_[0]{body}{max_tokens} // 0 ) == 7 } => error( 500, 'CUDA failed' ),
      after('fan_set') => answer('done'),
      qr/./ => tool( fan_set => { level => 'high' } ),
    ] );
  };
  my $report = Langertha::Holmgang::Batch->new( suites => [ $s6, $s2 ], max_consecutive_errors => 2,
    targets => [ { engine => $engine, variants => [ { name => 'sick', settings => { max_tokens => 7 } },
      { name => 'well', settings => { max_tokens => 100 } } ] } ] )->run;
  is_deeply( [ map { $_->{variant}{name}.' '.$_->{suite}{id}.' '.$_->{status} } @{ $report->runs } ],
    [ 'sick dead-six aborted', 'sick dead-two aborted', 'well dead-six complete', 'well dead-two complete' ],
    'the sick variant is aborted, the well one complete' );
  is_deeply( statuses( $report->runs->[2] ), { map { ( "c$_" => ['passed'] ) } 1 .. 6 }, '... every case of it passed' );

  # a second target goes on too
  my $two = Langertha::Holmgang::Batch->new( suites => [$s2], max_consecutive_errors => 1,
    targets => [ { target => { label => 'x' }, engine => sub { dead() } }, { target => { label => 'y' }, engine => sub { alive() } } ] )->run;
  is_deeply( [ map { $_->{status} } @{ $two->runs } ], [qw( aborted complete )], 'another target goes on' );
};

subtest 'resume plays the missing cases and the errors again' => sub {
  my $file = Path::Tiny->tempfile;
  my $first = Langertha::Holmgang::Batch->new( suites => [ $s6, $s2 ], targets => [ { target => { label => 'gpu' }, engine => sub { dead() } } ],
    max_consecutive_errors => 3 )->run;
  $first->write("$file");
  my @played;
  my $second = Langertha::Holmgang::Batch->new( suites => [ $s6, $s2 ], targets => [ { target => { label => 'gpu' }, engine => sub { alive() } } ],
    resume => Langertha::Holmgang::Report->read("$file"),
    on_event => sub { push @played, $_[0]{suite}->id.' '.$_[0]{case}->id if $_[0]{type} eq 'result' } )->run;
  is_deeply( \@played, [ ( map { "dead-six c$_" } 1 .. 6 ), 'dead-two c1', 'dead-two c2' ], 'the three errors and the missing cases are played' );
  is_deeply( [ map { $_->{status} } @{ $second->runs } ], [qw( complete complete )], '... both runs complete' );
  is_deeply( statuses( $second->runs->[0] ), { map { ( "c$_" => ['passed'] ) } 1 .. 6 }, '... no error left' );

  # any other status is taken over, as before
  my $mixed = Langertha::Holmgang::Batch->new( suites => [$s2], max_consecutive_errors => 0,
    targets => [ { target => { label => 'gpu' }, engine => sub { $_[0]->id eq 'c1' ? window() : dead() } } ] )->run;
  my @again;
  Langertha::Holmgang::Batch->new( suites => [$s2], targets => [ { target => { label => 'gpu' }, engine => sub { alive() } } ],
    resume => $mixed, on_event => sub { push @again, $_[0]{case}->id if $_[0]{type} eq 'result' } )->run;
  is_deeply( \@again, ['c2'], 'a context_exceeded is kept, only the error is played again' );
};

subtest 'what is refused' => sub {
  for my $bad ( -1, '1.5', 'ten', undef ) {
    like( exception { Langertha::Holmgang::Batch->new( suites => [$s2], targets => [ { engine => sub { alive() } } ],
      max_consecutive_errors => $bad ) }, qr/max_consecutive_errors must be a whole number from 0/,
      'max_consecutive_errors '.( $bad // 'undef' ) );
  }
};

done_testing;
