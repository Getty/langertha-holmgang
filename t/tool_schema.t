#!/usr/bin/env perl
# Langertha::Holmgang::ToolSchema. Claims: the load check refuses what lies
# outside the JSON Schema subset, with the field path, recursively; per call
# every violation is reported with its path, integers and numbers may come as
# text, enum compares like the expectations do, and the texts are the German
# ones the model gets.
use strict;
use warnings;
use utf8;
use Test::More;

use Langertha::Holmgang::Error;
use Langertha::Holmgang::ToolSchema qw( check_schema schema_errors );

binmode Test::More->builder->$_, ':encoding(UTF-8)' for qw( output failure_output todo_output );

sub refused {
  my ( $schema, $field, $re, $name ) = @_;
  my $e = Langertha::Holmgang::Error->caught( eval { check_schema( $schema, 'p' ); 1 } ? undef : $@ );
  ok( $e && $e->field eq $field && $e->reason =~ $re, $name ) or diag( $e ? "$e" : 'accepted' );
}

my $S = { type => 'object', required => [qw( name count )], properties => {
  name  => { type => 'string', minLength => 2, maxLength => 5, pattern => '^[a-z]+$' },
  count => { type => 'integer', minimum => 1, maximum => 9 },
  ratio => { type => 'number' },
  mode  => { type => 'string', enum => [qw( on off )] },
  on    => { type => 'boolean' },
  list  => { type => 'array', minItems => 1, maxItems => 2, items => { type => 'string' } },
  none  => { type => 'null' },
  fixed => { const => 'x' },
} };

is( check_schema( $S, 'p' ), $S, 'a schema in the subset passes and comes back' );
refused( { type => 'object', additionalProperties => 0 }, 'p.additionalProperties', qr/unknown key/, 'key outside the subset' );
refused( { type => 'tuple' }, 'p.type', qr/unknown type/, 'unknown type' );
refused( { properties => { a => { pattern => '(' } } }, 'p.properties.a.pattern', qr/invalid regular expression/, 'broken pattern, nested' );
refused( { properties => [] }, 'p.properties', qr/not a hash/, 'properties not a hash' );
refused( { items => { format => 'x' } }, 'p.items.format', qr/unknown key/, 'items checked too' );
refused( { required => 'a' }, 'p.required', qr/not a list/, 'required not a list' );
refused( { enum => 'a' }, 'p.enum', qr/not a list/, 'enum not a list' );

is_deeply( [ schema_errors( { name => 'abc', count => 3 }, $S ) ], [], 'fitting arguments' );
is_deeply( [ schema_errors( { name => 'abc', count => '3', ratio => '0.5' }, $S ) ], [], 'integer and number as text' );
is_deeply( [ schema_errors( {}, $S ) ], [ '$.name: fehlt', '$.count: fehlt' ], 'required, in schema order' );
is_deeply( [ schema_errors( 'x', $S ) ], ['$: erwartet object'], 'wrong type stops at its level' );
is_deeply( [ schema_errors( { name => 'a', count => 0 }, $S ) ], [ '$.count: kleiner als 1', '$.name: zu kurz' ], 'minimum, minLength' );
is_deeply( [ schema_errors( { name => 'abcdef', count => 10 }, $S ) ], [ '$.count: größer als 9', '$.name: zu lang' ], 'maximum, maxLength' );
is_deeply( [ schema_errors( { name => 'AB', count => 1 }, $S ) ], ['$.name: passt nicht zu ^[a-z]+$'], 'pattern' );
is_deeply( [ schema_errors( { name => 'ab', count => 1.5 }, $S ) ], ['$.count: erwartet integer'], 'integer' );
is_deeply( [ schema_errors( { name => 'ab', count => 1, mode => 'auto' }, $S ) ], ['$.mode: erlaubt sind on, off'], 'enum' );
is_deeply( [ schema_errors( { name => 'ab', count => 1, on => 'yes' }, $S ) ], ['$.on: erwartet boolean'], 'boolean needs a JSON boolean' );
is_deeply( [ schema_errors( { name => 'ab', count => 1, on => JSON::MaybeXS::true() }, $S ) ], [], '... and takes one' );
is_deeply( [ schema_errors( { name => 'ab', count => 1, list => [] }, $S ) ], ['$.list: zu wenige Einträge'], 'minItems' );
is_deeply( [ schema_errors( { name => 'ab', count => 1, list => [ 'a', 'b', 'c' ] }, $S ) ], ['$.list: zu viele Einträge'], 'maxItems' );
is_deeply( [ schema_errors( { name => 'ab', count => 1, list => [ 'a', {} ] }, $S ) ], ['$.list[1]: erwartet string'], 'items with index' );
is_deeply( [ schema_errors( { name => 'ab', count => 1, none => 0 }, $S ) ], ['$.none: erwartet null'], 'null' );
is_deeply( [ schema_errors( { name => 'ab', count => 1, fixed => 'y' }, $S ) ], [], 'const is not checked per call (as in cai-platform)' );
is_deeply( [ schema_errors( { anything => 1 }, undef ) ], [], 'no schema: nothing to check' );

done_testing;
