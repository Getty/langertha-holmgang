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
  Langertha::Holmgang::Sim::Linux::Backup
  Langertha::Holmgang::Sim::Linux::Storage
  Langertha::Holmgang::Sim::Linux::Dns
  Langertha::Holmgang::Sim::Linux::Postfix
  Langertha::Holmgang::Sim::Linux::Postgres
  Langertha::Holmgang::Sim::Linux::MariaDB
  Langertha::Holmgang::Sim::Linux::Redis
  Langertha::Holmgang::Sim::Linux::RedisService
  Langertha::Holmgang::Sim::Linux::Http
  Langertha::Holmgang::Sim::Linux::Nginx
  Langertha::Holmgang::Sim::Linux::Pki
  Langertha::Holmgang::Sim::Linux::SshAccess
)) {
  use_ok($_);
}

done_testing;
