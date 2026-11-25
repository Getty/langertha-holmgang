#!/usr/bin/env perl
# The shipped tree is a generic engine: it names no private user of it, no
# private host and no private document (k76). Real benchmark cases live outside
# this repository (ADR 0003); nothing here points at them.
#
# Scanned: every file under lib, bin, share and t, plus cpanfile and dist.ini
# (whichever exist -- a built distribution has no dist.ini). Each name is matched
# case-insensitively and only where it starts a word (a regex escape such as \A
# in front counts as a word start), so a word that merely contains the letters
# (mosaic-, a north-crag host) is no hit. The names are
# spelled with a character class here, so this file is no hit of its own.
#
# Also: no "platform#NNN", an issue reference of another repository, which a
# hosting platform links to the issues of this one.
#
# An exception is allowed by file and line pattern below, never by name alone: a
# new use of the same name elsewhere fails.
use strict;
use warnings;
use Test::More;
use File::Find ();
use File::Spec;
use FindBin ();

my $root = File::Spec->catdir( $FindBin::Bin, File::Spec->updir );

my @NAMES = (
  qr/c[a]i[-_]/i,
  qr/c[a]i::/i,
  qr/c[i]tiai/i,
  qr/c[i]tilan/i,
  qr/c[o]rtex/i,
  qr/a[g]ent-lab/i,
  qr/e[n]twurf-evals/i,
  qr/p[i]i-/i,
);

my @ALLOW = (
  # the body marker of the simulated PEM blocks: format 2 cases carry it
  # base64-encoded and a rule pins it (ADR 0004); renaming it waits on the
  # maintainer's decision (k76)
  [ qr{\Alib/Langertha/Holmgang/Sim/Linux/Pki\.pm\z}, qr/c[a]i-sim[-:]/ ],
);

my @files;
for my $top (qw( lib bin share t )) {
  my $dir = File::Spec->catdir( $root, $top );
  next unless -d $dir;
  File::Find::find( { no_chdir => 1, wanted => sub { push @files, $_ if -f $_ } }, $dir );
}
for my $f (qw( cpanfile dist.ini )) {
  my $p = File::Spec->catfile( $root, $f );
  push @files, $p if -f $p;
}
@files = sort @files;
ok( scalar @files, 'shipped files found' );

sub scan {
  my ( $re ) = @_;
  my @hits;
  for my $path ( @files ) {
    my $rel = File::Spec->abs2rel( $path, $root );
    $rel =~ s{\\}{/}g;
    open my $fh, '<:raw', $path or die "$rel: $!";
    while ( my $line = <$fh> ) {
      next unless $line =~ $re;
      next if grep { $rel =~ $_->[0] && $line =~ $_->[1] } @ALLOW;
      push @hits, "$rel:$.";
    }
    close $fh;
  }
  return @hits;
}

my $word = qr/(?:(?<![A-Za-z0-9])|(?<=\\[A-Za-z]))/;
for my $name ( @NAMES ) {
  my @hits = scan( qr/$word$name/ );
  ok( !@hits, 'no '.$name ) or diag( join "\n", @hits );
}

my @issue = scan( qr/platform\#\d/ );
ok( !@issue, 'no issue number of another repository' ) or diag( join "\n", @issue );

# the guard sees what it is meant to see, and not what it is not
like( 'Port of '.'c'.'ai-platform', qr/$word$NAMES[0]/, 'a name at a word start is a hit' );
like( '/\A'.'c'.'ai-sim-x/', qr/$word$NAMES[0]/, 'a name after a regex escape is a hit' );
unlike( 'mosaic-tile', qr/$word$NAMES[0]/, 'letters inside a word are no hit' );
unlike( 'cragside north-crag', qr/$word(?:${\ join '|', @NAMES })/, 'crag is no hit' );
unlike( q{"apii" not found}, qr/$word$NAMES[-1]/, q{a word ending in pii is no hit} );

done_testing;
