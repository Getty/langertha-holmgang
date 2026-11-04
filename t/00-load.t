#!/usr/bin/env perl
use strict;
use warnings;
use Test::More;

for (qw(
  Langertha::Holmgang
  Langertha::Holmgang::Report
)) {
  use_ok($_);
}

done_testing;
