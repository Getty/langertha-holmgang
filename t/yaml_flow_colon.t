#!/usr/bin/env perl
# A case file keeps a ":" inside a plain scalar of a flow collection (k75),
# such as an IPv6 address in { ... } or [ ... ]. An older YAML::XS refused
# such a case with "found unexpected ':'", so it did not load. Claims: this
# YAML::XS reads them as the text written, and the distribution declares the
# YAML::XS that does.
use strict;
use warnings;
use FindBin;
use Test::More;
use YAML::XS ();

my $y = YAML::XS::Load("packet: { saddr: 192.0.2.1, daddr: 2001:db8::2, proto: tcp }\nnets: [ 2001:db8::/32, fe80::1 ]\n");
is( $y->{packet}{daddr}, '2001:db8::2', 'an IPv6 address in a flow mapping' );
is( $y->{packet}{proto}, 'tcp', '... and the key after it' );
is_deeply( $y->{nets}, [ '2001:db8::/32', 'fe80::1' ], '... in a flow sequence' );

SKIP: {
  my $cpanfile = "$FindBin::Bin/../cpanfile";
  skip 'no cpanfile next to t/', 1 unless -f $cpanfile;
  open my $fh, '<', $cpanfile or die 'cannot read '.$cpanfile.': '.$!;
  my $text = do { local $/; <$fh> };
  my %floor = $text =~ /^requires\s+'([^']+)',\s+'([0-9.]+)';/mg;
  cmp_ok( $floor{'YAML::XS'} // 0, '>=', 0.77, 'cpanfile: YAML::XS 0.77 or later (":" in a flow scalar)' );
}

done_testing;
