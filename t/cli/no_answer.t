#!/usr/bin/env perl
# holmgang run when the target answers no case (k42): exit 1 and a note on stderr
# when every result is error, context_exceeded or no_vision -- over the whole run,
# a note per suite next to measured ones; the report as always. Constructor
# warnings of the engine reach stderr without a Perl location. Scripted
# Langertha::Engine::Virtual and test engines only; invented suites (ADR 0003).
use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../lib";
use Test::More;
use JSON::MaybeXS ();
use Path::Tiny qw( path );

use Holmgang::CLI qw( cli good_suite threshold_suite );
use Holmgang::SuiteDir qw( suite_dir );
use Langertha::Holmgang::Report;

my $root    = Path::Tiny->tempdir;
my $good    = good_suite( id => 'na-fan', root => $root );
my $other   = good_suite( id => 'na-other', root => $root );
my $gated   = threshold_suite( id => 'na-gated', root => $root );
my $out_dir = Path::Tiny->tempdir;
my $JSON    = JSON::MaybeXS->new( canonical => 1 );

my $FAIL    = { error => { status => 401, message => 'invalid credentials' } };
my $CONTEXT = { error => { status => 400, message => 'This model\'s maximum context length is 8192 tokens' } };
my $VISION  = { error => { status => 400, message => 'image input is not supported - hint: provide the mmproj' } };
my @SOLVE   = ( { tool_calls => [ [ fan_set => { level => 'high' } ] ] }, { answer => 'done' } );

sub script { '--option', 'script='.$JSON->encode( [@_] ) }

sub statuses {
  my ( $file ) = @_;
  my $r = Langertha::Holmgang::Report->read("$file");
  return [ map { [ map { map { $_->{status} } @{ $_->{repetitions} } } @{ $_->{cases} } ] } @{ $r->runs } ];
}

my $NOTE = qr/^holmgang: no case got an answer from the target\b/m;

{
  my $file = $out_dir->child('error.json');
  my ( $code, $out, $err ) = cli( run => '--suite', $good, '--target', 'Virtual', script( ($FAIL) x 2 ),
    '--repeat', 2, '--report', "$file" );
  is( $code, 1, 'every result error: exit 1' );
  like( $err, $NOTE, '... said on stderr' );
  like( $err, qr/\b2 error\b/, '... with the count per status' );
  unlike( $err, qr/ line \d+|\.p[ml]\b/, '... without a Perl location' );
  like( $out, qr/^na-fan c1 #1 error$/m, '... the per-case lines as always' );
  like( $out, qr/^Comparison by topic/m, '... and the evaluation' );
  ok( -f $file, 'the report is written still' );
  is_deeply( statuses($file), [ [qw( error error )] ], '... with both results' );
  is( Langertha::Holmgang::Report->read("$file")->runs->[0]{status}, 'complete', '... the run complete, as before' );
}

{
  my ( $code, undef, $err ) = cli( run => '--suite', $good, '--target', 'Virtual', script( $CONTEXT, $VISION ), '--repeat', 2 );
  is( $code, 1, 'only context_exceeded and no_vision: exit 1' );
  like( $err, $NOTE, '... said' );
  like( $err, qr/\b1 context_exceeded\b/, '... context_exceeded counted' );
  like( $err, qr/\b1 no_vision\b/, '... no_vision counted' );
}

{
  # one measured result among errors: the verdicts decide as before
  my $file = $out_dir->child('mixed.json');
  my ( $code, $out, $err ) = cli( run => '--suite', $good, '--target', 'Virtual', script( $FAIL, @SOLVE ),
    '--repeat', 2, '--report', "$file" );
  is( $code, 0, 'one passed result next to an error, no threshold: exit 0' ) or diag $err;
  unlike( $err, qr/no case got an answer/, '... no note' );
  is_deeply( statuses($file), [ [qw( error passed )] ], '... error, then passed' );

  ( $code, $out, $err ) = cli( run => '--suite', $gated, '--target', 'Virtual', script( $FAIL, @SOLVE ), '--repeat', 2 );
  is( $code, 1, 'the same against a threshold it misses: exit 1 by the verdict' );
  like( $out, qr/na-gated .*NOT PASSED/, '... the verdict says so' );
  unlike( $err, qr/no case got an answer/, '... not the no-answer note' );

  # a measured failure counts as an answer: the target answered, the case failed
  ( $code, undef, $err ) = cli( run => '--suite', $good, '--target', 'mock-text' );
  is( $code, 0, 'mock-text, every result failed, no threshold: exit 0 as before' );
  unlike( $err, qr/no case got an answer/, '... failed is measured, no note' );
}

{
  # several suites: judged over the run, a note per suite that got no answer
  my $file = $out_dir->child('two.json');
  my ( $code, undef, $err ) = cli( run => '--suite', $good, '--suite', $other, '--target', 'Virtual',
    script( $FAIL, @SOLVE ), '--report', "$file" );
  is( $code, 0, 'one suite without an answer next to a measured one: exit by the verdicts' ) or diag $err;
  like( $err, qr/^holmgang: suite na-fan: no case got an answer from the target \(1 error\)$/m,
    '... a note for the suite without an answer' );
  unlike( $err, qr/na-other/, '... none for the measured one' );
  unlike( $err, $NOTE, '... and no note for the run' );
  is_deeply( statuses($file), [ ['error'], ['passed'] ], '... both in the report' );

  ( $code, undef, $err ) = cli( run => '--suite', $good, '--suite', $other, '--target', 'Virtual', script( ($FAIL) x 2 ) );
  is( $code, 1, 'two suites, no answer in either: exit 1' );
  like( $err, $NOTE, '... the note for the run' );
  like( $err, qr/\b2 error\b/, '... counted over both' );
  unlike( $err, qr/^holmgang: suite /m, '... no note per suite on top' );
}

{
  # an empty suite never reaches the run: the loader refuses it (no cases), exit 2
  my $empty = suite_dir( id => 'na-empty', root => $root, cases => {} );
  my ( $code, undef, $err ) = cli( run => '--suite', $empty, '--target', 'mock-solution' );
  is( $code, 2, 'a suite without cases: exit 2, it does not load' );
  like( $err, qr/^holmgang: suite \Q$empty\E does not load: cases: no cases$/m, '... said' );
}

{
  # an aborted run stays exit 2, whatever it measured
  my ( $code ) = cli( run => '--suite', $good, '--target', 'Holmgang::BrokenEngine', script(@SOLVE) );
  is( $code, 2, 'an aborted run: exit 2, not 1' );
}

{
  # the engine's constructor warning: on stderr, without a Perl location
  my ( $code, undef, $err ) = cli( run => '--suite', $good, '--target', 'Holmgang::WarnEngine', script(@SOLVE) );
  is( $code, 0, 'an engine that warns while it is built: the run goes on' ) or diag $err;
  like( $err, qr/^holmgang: temperature 0\.7 is not supported by this model, using 1$/m, '... the warning on stderr' );
  unlike( $err, qr/ line \d+|\.p[ml]\b|<\$fh>/, '... without the location or the handle line' );
}

done_testing;
