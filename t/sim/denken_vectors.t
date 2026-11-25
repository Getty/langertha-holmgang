#!/usr/bin/env perl
# The checkers of the answer world denken against the judgement of Python:
# every answer in a vectors file (JSON, graded by score_answer of
# reasoning-gym 0.1.25) is graded the same here — right only
# at the full score. The file holds a suite's own puzzles, so it never enters
# this repo (ADR 0003): it runs only against a copy kept outside this checkout,
# named by HOLMGANG_DENKEN_VECTORS, and skips without it. A mismatch names the
# task and the grade, not the answer.
use strict;
use warnings;
use utf8;
use Test::More;
use JSON::MaybeXS ();
use Path::Tiny qw( path );

use Langertha::Holmgang::Sim::Denken;

my $file = $ENV{HOLMGANG_DENKEN_VECTORS};
plan skip_all => 'set HOLMGANG_DENKEN_VECTORS to a vectors file of graded answers' unless $file;

my $D = 'Langertha::Holmgang::Sim::Denken';
my $data = JSON::MaybeXS->new( utf8 => 1 )->decode( path($file)->slurp_raw );

is( $data->{reasoning_gym}, '0.1.25', 'vectors from reasoning-gym 0.1.25' );
my %by_art;
push @{ $by_art{ $_->{art} } }, $_ for @{ $data->{vektoren} };
is_deeply( [ sort keys %by_art ], [ $D->can('arten')->() ], 'vectors for every task' );

my %several = map { $_ => 1 } qw( graph_color countdown jugs cryptarithm shortest_path propositional_logic );
for my $art ( sort keys %by_art ) {
  subtest $art => sub {
    my ( $n, $i, %seen ) = ( 0, 0 );
    for my $v ( @{ $by_art{$art} } ) {
      $i++;
      my $j = 0;
      for my $x ( @{ $v->{antworten} } ) {
        $j++;
        my ( $ok ) = $D->can('pruefe')->( $art, $v->{pruefung}, $x->{antwort} );
        my $want = $x->{richtig} ? 1 : 0;
        $seen{$want}++;
        $n++;
        next if $ok == $want;
        fail( sprintf '%s: vector %d, answer %d -> %s (Python: %s)', $art, $i, $j,
          $ok ? 'richtig' : 'falsch', $want ? 'richtig' : 'falsch' );
      }
    }
    ok( $n > 20, "$n answers checked" );
    ok( $seen{1}, 'right answers among them' );
    ok( $seen{0}, 'wrong answers among them' );
    if ( $several{$art} ) {
      # more than one right answer per puzzle (a checker, not a fixed answer)
      my $multi = grep { ( grep { $_->{richtig} } @{ $_->{antworten} } ) > 1 } @{ $by_art{$art} };
      ok( $multi, "$multi puzzles with several right answers" );
    }
  };
}

done_testing;
