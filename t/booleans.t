#!/usr/bin/env perl
# Case data keeps its booleans (k75). A YAML true/false and a Perl !!1/!!0 in a
# suite.pl are booleans, not the text "1"/"" -- the schema check (type
# boolean), the answer worlds and the export to YAML rely on telling them
# apart. Only perl 5.36 (builtin::is_bool) can, and JSON::MaybeXS::is_bool
# sees core booleans from 1.004006 on; before, a case with a boolean argument
# in its solution failed lint and did not load. Claims: on this perl the four
# are booleans and their text look-alikes are not; the distribution declares
# the perl and the JSON::MaybeXS that make it so.
use strict;
use warnings;
use FindBin;
use Test::More;
use JSON::MaybeXS ();
use YAML::XS ();

my $y = YAML::XS::Load("t: true\nf: false\n");
ok( JSON::MaybeXS::is_bool( $y->{t} ), 'YAML true is a boolean' );
ok( JSON::MaybeXS::is_bool( $y->{f} ), 'YAML false is a boolean' );
ok( JSON::MaybeXS::is_bool( !!1 ), 'Perl !!1 is a boolean' );
ok( JSON::MaybeXS::is_bool( !!0 ), 'Perl !!0 is a boolean' );
ok( !grep( { JSON::MaybeXS::is_bool($_) } 1, 0, '1', '', 'true', 'false' ), '... 1, 0, "1", "", "true", "false" are not' );

SKIP: {
  my $cpanfile = "$FindBin::Bin/../cpanfile";
  skip 'no cpanfile next to t/', 2 unless -f $cpanfile;
  open my $fh, '<', $cpanfile or die 'cannot read '.$cpanfile.': '.$!;
  my $text = do { local $/; <$fh> };
  my %floor = $text =~ /^requires\s+'([^']+)',\s+'([0-9.]+)';/mg;
  cmp_ok( $floor{perl} // 0, '>=', 5.036, 'cpanfile: perl 5.036 or later (builtin::is_bool)' );
  cmp_ok( $floor{'JSON::MaybeXS'} // 0, '>=', 1.004006, 'cpanfile: JSON::MaybeXS 1.004006 or later (is_bool on core booleans)' );
}

done_testing;
