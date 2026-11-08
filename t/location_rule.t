#!/usr/bin/env perl
# The one location rule of the dist ($Langertha::Holmgang::Target::LOCATION,
# k42/k44) where World and Structure cut a trailing die location: a Perl error
# that names the line of the last read handle (", <FH> line N." or "chunk N")
# loses it whole, the text before it stays. Invented worlds and fields (ADR 0003).
use strict;
use warnings;
use Test::More;

use Langertha::Holmgang::Structure;
use Langertha::Holmgang::World;

# a value() that fails like a Perl error after a read, with the handle's line or chunk
{
  package Holmgang::Test::BrokenValueWorld;
  use Moose;
  extends 'Langertha::Holmgang::World';
  our $TAIL;
  sub value { die "value broke at /tmp/invented/World.pm line 12$TAIL\n" }
  __PACKAGE__->meta->make_immutable;
}

# a haystack that croaks "<field>: <reason>" with such a location
{
  package Holmgang::Test::BrokenHaystack;
  our $TAIL;
  sub new { bless {}, shift }
  sub resolve { my ( $self, $v, $f ) = @_; die $f.": generator broke at /tmp/invented/Haystack.pm line 7$TAIL\n" }
}

my @tools = ( {
  name       => 'poke',
  parameters => { type => 'object', properties => {} },
  handlers   => [ { apply => [ { set => 'box.lid', value => 'open' } ], output => 'ok' } ],
} );

for my $tail ( '.', ', <$fh> line 2.', ', <STDIN> chunk 3.', ', <$fh> line 2' ) {
  local $Holmgang::Test::BrokenValueWorld::TAIL = $tail;
  local $Holmgang::Test::BrokenHaystack::TAIL   = $tail;

  my $w = Holmgang::Test::BrokenValueWorld->new( state => { box => { lid => 'shut' } }, tools => \@tools );
  my ( $out, undef, $ok ) = $w->call( poke => {} );
  ok( !$ok, "World apply, location '$tail': the change fails" );
  is( $out, 'Fehler: value broke', '... the error text without the location' );

  my $s = Langertha::Holmgang::Structure->new( haystack => Holmgang::Test::BrokenHaystack->new );
  my $err = eval { $s->generated( { messages => [ { role => 'user', content => [ 'a', 'b' ] } ] }, 'cases/c1.yaml' ); 1 } ? undef : $@;
  isa_ok( $err, 'Langertha::Holmgang::Error', "Structure generated, location '$tail'" );
  is( $err && $err->field,  'cases/c1.yaml: messages[0].content', '... the field as the haystack named it' );
  is( $err && $err->reason, 'generator broke', '... the reason without the location' );
}

done_testing;
