#!/usr/bin/env perl
use strict;
use warnings;
use Test::More;

for (qw(
  Langertha::Holmgang
  Langertha::Holmgang::Report
  Langertha::Holmgang::Role::Simulator
  Langertha::Holmgang::Role::AnswerWorld
  Langertha::Holmgang::Simulators
  Langertha::Holmgang::Shell
  Langertha::Holmgang::Shell::Filter
  Langertha::Holmgang::Sim::Linux
  Langertha::Holmgang::Sim::Linux::Nft
  Langertha::Holmgang::Sim::Linux::Calendar
)) {
  use_ok($_);
}

done_testing;
