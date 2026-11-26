#!/usr/bin/env perl
# holmgang run --max-consecutive-errors (k74): a target that fails N cases in a
# row is taken for dead -- the line at the abort says why, the run is aborted
# in the report with the reason, the missing cases have no result, exit 1 (a
# target failure, not a setup error); 0 turns it off; --resume plays the
# missing cases and the errors again; the option is checked and in the help.
# Scripted Langertha::Engine::Virtual only; invented suites (ADR 0003).
use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../lib";
use Test::More;
use JSON::MaybeXS ();
use Path::Tiny qw( path );

use Holmgang::CLI qw( cli good_suite );
use Holmgang::SuiteDir qw( suite_dir $FAN_CASE );
use Langertha::Holmgang::Report;

my $root  = Path::Tiny->tempdir;
my $suite = suite_dir( id => 'dt-fan', root => $root,
  cases => { map { ( "c$_.yaml" => $FAN_CASE =~ s/^id: c1$/id: c$_/mr ) } 1 .. 4 } );
my $out_dir = Path::Tiny->tempdir;
my $JSON    = JSON::MaybeXS->new( canonical => 1 );

my $FAIL  = { error => { status => 500, message => 'CUDA failed' } };
my @SOLVE = ( { tool_calls => [ [ fan_set => { level => 'high' } ] ] }, { answer => 'done' } );

sub script { '--option', 'script='.$JSON->encode( [@_] ) }

sub statuses {
  my ( $report ) = @_;
  return [ map { [ map { $_->{status} } @{ $_->{repetitions} } ] } @{ $report->runs->[0]{cases} } ];
}

my $file = $out_dir->child('dead.json');
{
  my ( $code, $out, $err ) = cli( run => '--suite', $suite, '--target', 'Virtual', script( ($FAIL) x 8 ),
    '--repeat', 2, '--max-consecutive-errors', 3, '--report', "$file" );
  is( $code, 1, 'a dead target: exit 1, not 2' ) or diag $out, $err;
  like( $out, qr/^dt-fan c3 #1 error\ndt-fan c3 #1 aborted: the target failed 3 cases in a row \(status error\), so no further case of this target and variant starts; the last error: .*CUDA failed$/m,
    '... the line at the abort says why, after the case that completed the series' );
  unlike( $out, qr/^dt-fan c4 /m, '... no further case started' );
  like( $out, qr/run aborted: the target failed 3 cases in a row/, '... the evaluation notes it' );
  like( $err, qr/^holmgang: no case got an answer from the target \(3 error\); first: .*CUDA failed/m,
    '... nothing was measured: the k42 note' );
  my $r = Langertha::Holmgang::Report->read("$file");
  is( $r->runs->[0]{status}, 'aborted', 'the report: the run aborted' );
  like( $r->runs->[0]{error}, qr/\Athe target failed 3 cases in a row/, '... with the reason' );
  is_deeply( statuses($r), [ ['error'], ['error'], ['error'], [] ], '... the missing repetitions have no result' );
}

{
  # resume against a target that answers again: the errors and the missing cases are played
  my ( $code, $out ) = cli( run => '--suite', $suite, '--target', 'Virtual', script( (@SOLVE) x 8 ),
    '--repeat', 2, '--resume', "$file", '--report', "$file" );
  is( $code, 0, 'resumed against a live target: exit 0' ) or diag $out;
  my @lines = $out =~ /^dt-fan (c\d #\d) passed$/mg;
  is_deeply( \@lines, [ 'c1 #1', 'c2 #1', 'c3 #1', 'c4 #1', 'c1 #2', 'c2 #2', 'c3 #2', 'c4 #2' ], '... every repetition played' );
  my $r = Langertha::Holmgang::Report->read("$file");
  is( $r->runs->[0]{status}, 'complete', '... the run complete' );
}

{
  # a measured result next to it: the verdict (unfinished) gives exit 1
  my ( $code, $out, $err ) = cli( run => '--suite', $suite, '--target', 'Virtual', script( @SOLVE, ($FAIL) x 7 ),
    '--max-consecutive-errors', 2 );
  is( $code, 1, 'a measured case, then a dead target: exit 1 by the verdict' );
  like( $out, qr/^dt-fan c3 #1 aborted: the target failed 2 cases in a row/m, '... aborted after two errors' );
  is( $err, '', '... no no-answer note: something was measured' );
}

{
  my ( $code, $out ) = cli( run => '--suite', $suite, '--target', 'Virtual', script( ($FAIL) x 4 ),
    '--max-consecutive-errors', 0 );
  is( $code, 1, '0 turns it off: the run completes, nothing measured, exit 1 (k42)' );
  like( $out, qr/^dt-fan c4 #1 error$/m, '... every case played' );
  unlike( $out, qr/aborted/, '... nothing aborted' );

  ( $code, $out ) = cli( run => '--suite', $suite, '--target', 'Virtual', script( ($FAIL) x 4 ) );
  is( $code, 1, 'default 10: four errors do not stop the run' );
  unlike( $out, qr/aborted/, '... nothing aborted' );
}

{
  my ( $code, undef, $err ) = cli( run => '--suite', $suite, '--target', 'mock-solution', '--max-consecutive-errors', -1 );
  is( $code, 2, 'a negative count: exit 2' );
  like( $err, qr/--max-consecutive-errors must be 0 \(off\) or more/, '... said' );
  ( $code, undef, $err ) = cli( run => '--suite', $suite, '--target', 'mock-solution', '--max-consecutive-errors', 'many' );
  is( $code, 2, 'not a number: exit 2' );
  like( $err, qr/max-consecutive-errors/, '... named' );
  my $out;
  ( $code, $out ) = cli('help');
  like( $out, qr/\[--max-consecutive-errors N\]/, 'the help names the option' );
  my $pod = path( $FindBin::Bin, '..', '..', 'bin', 'holmgang' )->slurp_utf8;
  like( $pod, qr/^=(?:opt|head2) --max-consecutive-errors N$/m, 'bin/holmgang documents it' );
}

done_testing;
