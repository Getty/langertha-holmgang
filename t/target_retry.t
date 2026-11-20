#!/usr/bin/env perl
use strict;
use warnings;
use utf8;
use Test::More;
use Test::Fatal qw( exception );
use Langertha::Engine::Virtual;
use Langertha::Virtual::Rules qw( answer error );
use Langertha::Holmgang::Target;

# A turn that fails for a passing reason (a proxy's 502/503/504, a 429, a
# dropped connection) is asked again before it ends the case; a turn that fails
# for good (a 400, a 500, a broken GPU, the variant's own deadline) is not.
# Every repeat is counted on the turn. Network-free: the Virtual engine has no
# loop, so there is no pause between the attempts.

my $USER = [ { role => 'user', content => 'Bitte pruefen.' } ];

# fails with the given reactions in order, then answers
sub flaky {
  my ( @fail ) = @_;
  my $n = 0;
  my $engine = Langertha::Engine::Virtual->new( rules => [ qr/./ => sub { $n++ < @fail ? $fail[ $n - 1 ] : answer('ok') } ] );
  return ( $engine, \$n );
}

sub turn { my ( $t ) = @_; my $f = $t->chat_turn_f( messages => $USER ); ok $f->is_done, 'done, not failed'; $f->get }

subtest 'a passing failure is asked again and counted' => sub {
  for my $case (
    [ 502, '{"error":{"message":"Upstream error: Request timeout","type":"upstream_error"}}' ],
    [ 503, 'Service Unavailable' ],
    [ 504, 'Gateway Timeout' ],
    [ 429, 'Too Many Requests' ],
  ) {
    my ( $engine, $n ) = flaky( error(@$case) );
    my $turn = turn( Langertha::Holmgang::Target->new( engine => $engine ) );
    is $turn->{error_class}, undef, "$case->[0]: answered on the second attempt";
    is $turn->{response}->content, 'ok', "$case->[0]: the answer of the repeat";
    is $turn->{retries}, 1, "$case->[0]: one repeat counted";
    is $$n, 2, "$case->[0]: two requests";
  }
};

subtest 'retries run out: the last failure stands, with the count' => sub {
  my ( $engine, $n ) = flaky( ( error( 502, 'Bad Gateway' ) ) x 5 );
  my $turn = turn( Langertha::Holmgang::Target->new( engine => $engine ) );
  is $turn->{error_class}, 'error', 'still an error';
  like $turn->{error}, qr/502/, 'the text of the last attempt';
  is $turn->{retries}, 2, 'two repeats by default';
  is $$n, 3, 'three requests in all';
};

subtest 'retries => 0 turns it off; retries => 4 allows more' => sub {
  my ( $engine, $n ) = flaky( ( error( 503, 'down' ) ) x 3 );
  my $turn = turn( Langertha::Holmgang::Target->new( engine => $engine, retries => 0 ) );
  is $turn->{error_class}, 'error', 'off: the first failure ends it';
  is $turn->{retries}, 0, 'no repeat';
  is $$n, 1, 'one request';

  ( $engine, $n ) = flaky( ( error( 503, 'down' ) ) x 3 );
  $turn = turn( Langertha::Holmgang::Target->new( engine => $engine, retries => 4 ) );
  is $turn->{error_class}, undef, 'four allowed: answered on the fourth attempt';
  is $turn->{retries}, 3, 'three repeats';
};

subtest 'a lasting failure is not asked again' => sub {
  for my $case (
    [ 400, 'bad request' ],
    [ 401, 'unauthorized' ],
    [ 500, 'upstream down' ],
    [ 502, 'CUDA error: an illegal memory access was encountered' ],
    [ 503, 'CudaFailed: device lost' ],
    [ 400, 'maximum context length is 8192 tokens' ],
  ) {
    my ( $engine, $n ) = flaky( error(@$case) );
    my $turn = turn( Langertha::Holmgang::Target->new( engine => $engine ) );
    isnt $turn->{error_class}, undef, "$case->[0] $case->[1]: fails";
    is $turn->{retries}, 0, "$case->[0] $case->[1]: no repeat";
    is $$n, 1, "$case->[0] $case->[1]: one request";
  }
};

subtest 'a turn that answers carries retries 0' => sub {
  my $turn = turn( Langertha::Holmgang::Target->new( engine => Langertha::Engine::Virtual->new( rules => [ qr/./ => answer('ok') ] ) ) );
  is $turn->{retries}, 0, 'nothing repeated';
};

subtest 'retryable: the signatures' => sub {
  my $T = 'Langertha::Holmgang::Target';
  ok $T->retryable($_), $_ for (
    'Langertha::Engine::vLLM request failed: 502 Bad Gateway - {"error":{"message":"Upstream error: Inactivity timeout"}}',
    'Langertha::Engine::vLLM request failed: 429 Too Many Requests - slow down',
    'Langertha::Engine::vLLM request failed: 504 Gateway Timeout',
    'Connection refused',
    'Connection reset by peer',
    'Server closed connection without sending any data back',
    "Can't connect to cortex.ai.citilan.de:8888",
  );
  ok !$T->retryable($_), $_ for (
    'timeout: deadline (1800 s)',
    'Langertha::Engine::vLLM request failed: 500 Internal Server Error - CUDA error',
    'Langertha::Engine::vLLM request failed: 400 Bad Request',
    'Langertha::Engine::vLLM request failed: 503 Service Unavailable - CudaFailed',
    'Langertha::Engine::vLLM request failed: 502 Bad Gateway - out of memory',
    '',
  );
  ok !$T->retryable(undef), 'undef';
};

subtest 'on an event loop the repeats wait, twice as long each time' => sub {
  plan skip_all => 'IO::Async not installed' unless eval { require IO::Async::Loop; 1 };
  require Time::HiRes;
  my $loop = IO::Async::Loop->new;
  my ( $engine, $n ) = flaky( error( 502, 'a' ), error( 502, 'b' ) );
  no warnings 'redefine';
  local *Langertha::Engine::Virtual::async_loop = sub { $loop };    # the Virtual engine has no loop of its own
  my $t = Langertha::Holmgang::Target->new( engine => $engine, retry_delay => 0.2 );
  my $t0 = Time::HiRes::time();
  my $turn = $t->chat_turn_f( messages => $USER )->get;
  my $s = Time::HiRes::time() - $t0;
  is $turn->{retries}, 2, 'two repeats';
  is $turn->{error_class}, undef, 'answered on the third attempt';
  cmp_ok $s, '>=', 0.55, 'waited 0.2 + 0.4 s';
};

subtest 'variant setting retries' => sub {
  my $T = 'Langertha::Holmgang::Target';
  is_deeply $T->check_variant( { retries => '0' } ), { retries => 0 }, '0 is a value';
  is_deeply $T->check_variant( { retries => 5 } ),   { retries => 5 }, 'five is a value';
  ok exception { $T->check_variant( { retries => 11 } ) }, 'at most 10';
  ok exception { $T->check_variant( { retries => 'x' } ) }, 'a number';
  my $engine = Langertha::Engine::Virtual->new( rules => [ qr/./ => answer('ok') ] );
  is $T->for_variant( engine => $engine, settings => { retries => 0 } )->retries, 0, 'for_variant passes it on';
  is $T->for_variant( engine => $engine, settings => {} )->retries, 2, 'default 2';
  ok exception { $T->new( engine => $engine, retries => -1 ) }, 'constructor refuses -1';
};

done_testing;
