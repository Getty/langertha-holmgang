package Langertha::Holmgang::Sim::Linux::RedisService;
# ABSTRACT: Redis from the service alone (services.redis-server.running) — redis-cli connection, auth, PING, CONFIG GET and redis-server -v

use strict;
use warnings;
use utf8;

our $VERSION = '0.001';

=head1 SYNOPSIS

  # aus dem Linux-Simulator
  my ( $out, $ok, $gap ) = Langertha::Holmgang::Sim::Linux::RedisService::cli( $dev, \@argv, $host );
  my ( $out, $ok, $gap ) = Langertha::Holmgang::Sim::Linux::RedisService::server( $dev, \@argv );

=head1 DESCRIPTION

Für Geräte ohne den Redis-Zustand C<redis> (den bildet L<Langertha::Holmgang::Sim::Linux::Redis>
nach); dann steht alles, was Redis gerade benutzt, im Dienst selbst.

Redis eines Debian-12-Geräts vom Typ C<linux> (cai-platform F<docs/entwurf-evals.md> §3.3.1):
der Dienst C<redis-server> mit C<config> (F</etc/redis/redis.conf>); was er
gerade benutzt, steht in seinem C<running> (eingelesen bei Start/Neustart).

  services:
    redis-server: { active: true, config: /etc/redis/redis.conf, running: "bind 127.0.0.1 -::1\nrequirepass …\n" }

B<redis-cli> C<[-h host] [-p port] [-a passwort|--pass passwort] [--user u]
[--no-auth-warning] [--raw] befehl …>: Die Verbindung gelingt nur, wenn Redis
läuft und auf der Adresse lauscht (letzte C<bind>-Zeile des laufenden Zustands;
ohne C<bind> alle Adressen; C<-> vor einer Adresse heißt „falls vorhanden“; die
eigenen Adressen des Geräts und 127.0.0.1/::1). Mit C<requirepass> braucht jeder
Befehl das richtige Passwort (sonst C<NOAUTH>, ein falsches gibt C<WRONGPASS>);
ohne Passwort weist C<protected-mode yes> Verbindungen von außen ab. Ausgabe wie
ohne Terminal (über SSH): roh, Fehler ohne „(error)“. Nachgebildet sind
C<PING>, C<CONFIG GET muster> und C<AUTH>; andere Befehle sind eine Lücke der
Simulation. B<redis-server> C<-v|--version>; Optionen, die keine Direktive sind
(z. B. C<--test-config>), enden wie bei Redis mit C<FATAL CONFIG FILE ERROR>.

=cut

sub _svc { my ($dev) = @_; return ( $dev->{services} || {} )->{'redis-server'} }

=func installed

Wahr, wenn das Gerät einen Dienst C<redis-server> hat.

=cut

sub installed { return _svc( $_[0] ) ? 1 : 0 }

sub _conf {
    my ($dev) = @_;
    my $t = ( _svc($dev) || {} )->{running} // '';
    my %c;
    for my $l ( split /\n/, $t ) {
        $l =~ s/\A\s+//;
        next if $l eq '' || $l =~ /\A#/;
        my ( $k, $v ) = $l =~ /\A(\S+)\s*(.*?)\s*\z/ or next;
        $c{ lc $k } = $v;    # die letzte Zeile gewinnt (wie Redis)
    }
    return \%c;
}

sub _addrs {
    my ($dev) = @_;
    my @a = ( '127.0.0.1', '::1' );
    for my $i ( values %{ $dev->{interfaces} || {} } ) { push @a, map { s{/\d+\z}{}r } @{ $i->{addr} || [] } }
    return @a;
}

# Lauscht Redis auf $host?
sub _listens {
    my ( $dev, $host ) = @_;
    my $c = _conf($dev);
    my $v6 = $host =~ /:/;
    return 1 unless defined $c->{bind};
    for my $b ( split ' ', $c->{bind} ) {
        $b =~ s/\A-//;
        return 1 if $b eq '*' && !$v6 || $b eq '0.0.0.0' && !$v6 || ( $b eq '::*' || $b eq '::' ) && $v6;
        return 1 if $b eq $host;
    }
    return 0;
}

=func cli

C<redis-cli …>; Rückgabe C<( $ausgabe, $ok, $luecke )>.

=cut

sub cli {
    my ( $dev, $av, $host_name ) = @_;
    my @a = @$av;
    my ( $h, $port, $pw, $nowarn, @cmd ) = ( '127.0.0.1', 6379 );
    while (@a) {
        my $x = shift @a;
        if    ( $x eq '-h' ) { $h = shift(@a) // '' }
        elsif ( $x eq '-p' ) { $port = shift(@a) // '' }
        elsif ( $x eq '-a' || $x eq '--pass' ) { $pw = shift(@a) // '' }
        elsif ( $x eq '--user' || $x eq '-n' || $x eq '-u' ) { shift @a }
        elsif ( $x eq '--no-auth-warning' ) { $nowarn = 1 }
        elsif ( $x eq '--raw' || $x eq '--no-raw' || $x eq '-c' ) { }
        elsif ( $x eq '-v' || $x eq '--version' ) { return ( 'redis-cli 7.0.15', 1 ) }
        elsif ( $x =~ /\A-/ && !@cmd ) { return ( '', 0, join( ' ', 'redis-cli', @$av ) ) }
        else { push @cmd, $x, @a; last }
    }
    my @out;
    push @out, "Warning: Using a password with '-a' or '-u' option on the command line interface may not be safe." if defined $pw && !$nowarn;
    $h = '127.0.0.1' if $h eq 'localhost';
    $h = '::1' if $h eq 'ip6-localhost';
    my $svc = _svc($dev) || {};
    my $mine = grep { $_ eq $h } _addrs($dev);
    if ( !$svc->{active} || "$port" ne ( _conf($dev)->{port} // '6379' ) || !$mine || !_listens( $dev, $h ) ) {
        my $hp = $h =~ /:/ ? "$h:$port" : "$h:$port";
        return ( join( "\n", @out, "Could not connect to Redis at $hp: Connection refused" ), 0 );
    }
    return ( join( "\n", @out ), 0, join( ' ', 'redis-cli', @$av ) ) unless @cmd;    # interaktiv
    my $c = _conf($dev);
    my $need = defined $c->{requirepass} && length $c->{requirepass};
    ( my $want = $c->{requirepass} // '' ) =~ s/\A"(.*)"\z/$1/;
    my $authed = !$need;
    if ( $need && defined $pw ) {
        if   ( $pw eq $want ) { $authed = 1 }
        else                  { push @out, 'AUTH failed: WRONGPASS invalid username-password pair or user is disabled.' }
    }
    my $loop = $h eq '127.0.0.1' || $h eq '::1';
    if ( !$need && !$loop && ( $c->{'protected-mode'} // 'yes' ) eq 'yes' ) {
        return ( join( "\n", @out, 'DENIED Redis is running in protected mode because protected mode is enabled and no password is set for the default user.' ), 0 );
    }
    my $verb = uc $cmd[0];
    if ( $verb eq 'AUTH' ) {
        my $p = $cmd[-1] // '';
        return ( join( "\n", @out, $need && $p eq $want ? 'OK' : $need ? 'WRONGPASS invalid username-password pair or user is disabled.'
            : 'ERR AUTH <password> called without any password configured for the default user. Are you sure your configuration is correct?' ), $p eq $want ? 1 : 0 );
    }
    return ( join( "\n", @out, 'NOAUTH Authentication required.' ), 0 ) unless $authed;
    return ( join( "\n", @out, @cmd > 1 ? $cmd[1] : 'PONG' ), 1 ) if $verb eq 'PING';
    if ( $verb eq 'CONFIG' && uc( $cmd[1] // '' ) eq 'GET' && defined $cmd[2] ) {
        ( my $re = quotemeta lc $cmd[2] ) =~ s/\\\*/.*/g;
        my %all = ( bind => '* -::*', port => '6379', 'protected-mode' => 'yes', requirepass => '', %$c );
        for my $k ( sort grep {/\A$re\z/} keys %all ) {
            ( my $v = $all{$k} ) =~ s/\A"(.*)"\z/$1/;
            push @out, $k, $v;
        }
        return ( join( "\n", @out ), 1 );
    }
    return ( join( "\n", @out ), 0, join( ' ', 'redis-cli', @$av ) );
}

=func server

C<redis-server -v|--version>; andere Optionen ohne Direktive: Fehler wie Redis.

=cut

sub server {
    my ( $dev, $av ) = @_;
    my @a = @$av;
    return ( 'Redis server v=7.0.15 sha=00000000:0 malloc=jemalloc-5.3.0 bits=64 build=c4d1f6a1d3b5a9e2', 1 )
        if @a && ( $a[0] eq '-v' || $a[0] eq '--version' );
    my @opt = grep {/\A--/} @a;
    my %directive = map { $_ => 1 } qw( bind port protected-mode requirepass daemonize supervised loglevel logfile dir save
        dbfilename maxmemory maxmemory-policy maxclients databases timeout tcp-keepalive tcp-backlog pidfile appendonly );
    for my $o (@opt) {
        ( my $d = $o ) =~ s/\A--//;
        next if $directive{$d} || $d eq 'test-memory';
        return ( join( "\n", '', '*** FATAL CONFIG FILE ERROR (Redis 7.0.15) ***', 'Reading the configuration file, at line 2', ">>> '$d'",
            'Bad directive or wrong number of arguments' ), 0 );
    }
    return ( '', 0, join( ' ', 'redis-server', @$av ) );
}

1;
