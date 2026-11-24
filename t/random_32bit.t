#!/usr/bin/env perl
# The seeded random sources give the same numbers on a perl with 32-bit
# integers (k75). On i686 (ivsize 4) a sum or product past 2**32 - 1 is a
# double and the bit operators clamp it to 2**32 - 1, so the generator drew
# 4294967295 for every seed and every generated suite and haystack was the
# same for any seed. Holmgang::UV32 computes as that perl does; the claim is
# that Random (splitmix32, xoshiro128**) and Haystack's xorshift32 give the
# same values with it as natively.
use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/lib";
use Test::More;

use Holmgang::UV32 qw( uv32 plain );
use Langertha::Holmgang::Random;
use Langertha::Holmgang::Haystack;

# premise: the emulation clamps as the reports show
is( plain( ( uv32(4294967295) + 1 ) & 0xFFFFFFFF ), 4294967295, 'premise: 2**32 & 0xFFFFFFFF is 2**32 - 1 on i686' );
is( plain( ( uv32(0x80000001) << 1 ) ), 2, 'premise: << keeps 32 bits' );

my @SEEDS = ( 0, 1, 2, 4711, 2**31, 2**32 - 1 );

for my $seed (@SEEDS) {
  my $native = Langertha::Holmgang::Random->new( seed => $seed );
  # the same object with a seed that computes in 32 bits; the builder of
  # the state runs on first use
  my $i686 = bless { seed => uv32($seed) }, 'Langertha::Holmgang::Random';
  my @want = map { $native->next_u32 } 1 .. 64;
  my @got  = map { plain( $i686->next_u32 ) } 1 .. 64;
  is_deeply( \@got, \@want, "Random seed $seed: 64 values as with 64-bit integers" );
  my @dice_want = map { $native->int( 1, 6 ) } 1 .. 32;
  my @dice_got  = map { plain( $i686->int( 1, 6 ) ) } 1 .. 32;
  is_deeply( \@dice_got, \@dice_want, "Random seed $seed: dice the same" );
}

{
  my @first = map { plain( ( bless { seed => uv32($_) }, 'Langertha::Holmgang::Random' )->next_u32 ) } 1, 2, 3;
  isnt( $first[0], $first[1], 'neighbouring seeds start apart in 32 bits' );
  isnt( $first[1], $first[2], '... also the next pair' );
}

# Haystack's seeds: 0 .. 2**31, and the second source at seed + 7919
for my $seed ( 0, 1, 2, 7, 2**31, 2**31 + 7919 ) {
  my $native = Langertha::Holmgang::Haystack->_rng($seed);
  my $i686   = Langertha::Holmgang::Haystack->_rng( uv32($seed) );
  my @want = map { $native->() } 1 .. 64;
  my @got  = map { plain( $i686->() ) } 1 .. 64;
  is_deeply( \@got, \@want, "Haystack seed $seed: 64 values as with 64-bit integers" );
}

done_testing;
