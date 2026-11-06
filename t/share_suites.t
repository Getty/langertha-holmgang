#!/usr/bin/env perl
# The example suites the distribution ships under share/suites (k22, ADR 0010).
# Claims: every shipped suite loads -- lint is part of loading, so each case's
# self-check and both mock runs hold; the set is the one ADR 0010 lists and
# covers a device, a world without devices (handlers) and generated input; each
# suite says where it comes from and under which license; and through the
# command line, mock-solution passes every case and mock-text fails every case
# (exit 0 and 1). Runs on the share/ next to t/ -- the checkout, and the build
# directory under dzil test -- without a network.
use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/lib";
use Path::Tiny qw( path );
use Test::More;

use Holmgang::CLI qw( cli );
use Langertha::Holmgang::Loader;

my $root = path( $FindBin::Bin, '..', 'share', 'suites' );
ok( -d $root, 'share/suites is there' ) or BAIL_OUT('no share/suites');

my @dirs = sort grep { -f $_->child('suite.yaml') } $root->children;
is_deeply( [ map { $_->basename } @dirs ], [qw( demo-haystack demo-lamp demo-linux )], 'the shipped suites' );

my $loader = Langertha::Holmgang::Loader->new;
my %suite;
for my $dir ( @dirs ) {
  my $s = eval { $loader->load("$dir") };
  ok( $s, $dir->basename.' loads (lint included)' ) or diag $@;
  next unless $s;
  $suite{ $s->id } = $s;
  is( $s->license, 'Perl_5', '... license Perl_5' );
  like( $s->source && $s->source->{authors}, qr/Torsten Raudssus/, '... author in source' );
  my $head = $dir->child('suite.yaml')->slurp_utf8;
  like( $head, qr/^# Origin: written for this distribution;.*invented/ms, '... origin in the header' );
  like( $head, qr/^# License: same terms as Perl itself/m, '... license in the header' );
}

# what each one is there to show
{
  my %types = map {
    my $s = $_;
    ( $s->id => { map { ( ref $_ eq 'HASH' && $_->{type} ) ? ( $_->{type} => 1 ) : () } map { values %{ $_->state } } @{ $s->cases } } )
  } values %suite;
  ok( $types{'demo-linux'}{linux}, 'demo-linux: a linux device' );
  is_deeply( $types{'demo-lamp'}, {}, 'demo-lamp: no typed entry, a world without devices' );
  my $c = $suite{'demo-haystack'} && $suite{'demo-haystack'}->cases->[0];
  is( ref( $c && $c->messages->[0]{content} ), 'ARRAY', 'demo-haystack: the case keeps its generate spec' );
  like( $c && $c->prompt_messages->[0]{content}, qr/thumb-render\[\d+\]: ERROR: .*disk quota exceeded/,
    '... and the model gets the generated journal with the planted line' );
}

# through the command line, as a user runs them
my @suite_args = map { ( '--suite', "$_" ) } @dirs;
{
  my ( $code, $out, $err ) = cli( 'lint', "$root" );
  is( $code, 0, 'holmgang lint share/suites: exit 0' ) or diag $out.$err;
  like( $out, qr/^3 suites: 3 ok, 0 refused$/m, '... 3 ok' );
}
{
  my ( $code, $out, $err ) = cli( 'run', @suite_args, '--target', 'mock-solution' );
  is( $code, 0, 'run --target mock-solution: exit 0' ) or diag $out.$err;
  my @lines = $out =~ /^demo-\S+ \S+ #1 (\w+)$/mg;
  is( scalar @lines, 4, '... four cases run' );
  is_deeply( [ grep { $_ ne 'passed' } @lines ], [], '... every one passed' );
}
{
  my ( $code, $out, $err ) = cli( 'run', @suite_args, '--target', 'mock-text' );
  is( $code, 1, 'run --target mock-text: exit 1' ) or diag $out.$err;
  my @lines = $out =~ /^demo-\S+ \S+ #1 (\w+)$/mg;
  is( scalar @lines, 4, '... four cases run' );
  is_deeply( [ grep { $_ ne 'failed' } @lines ], [], '... every one failed' );
}

done_testing;
