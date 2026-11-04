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
  Langertha::Holmgang::Sim::Linux::Monitoring
  Langertha::Holmgang::Sim::Linux::Sshd
  Langertha::Holmgang::Sim::Linux::Logrotate
  Langertha::Holmgang::Sim::Linux::Accounts
  Langertha::Holmgang::Sim::RouterOS
  Langertha::Holmgang::Sim::IOS
  Langertha::Holmgang::Sim::Linux::Kubernetes
)) {
  use_ok($_);
}

done_testing;
