package Langertha::Holmgang::Sim::Linux::SshAccess;
# ABSTRACT: Whether a user can log in over SSH: port, firewall, Match, account, authorized_keys, StrictModes

use strict;
use warnings;
use utf8;

use Langertha::Holmgang::Sim::Linux::Nft ();

our $VERSION = '0.001';

=head1 SYNOPSIS

  use Langertha::Holmgang::Sim::Linux::SshAccess ();

  my ( $ok, $client, @log ) = Langertha::Holmgang::Sim::Linux::SshAccess::check( $dev, {
      user => 'anna', from => '10.1.0.77', key => 'ssh-ed25519 AAAAC3Nz…',
      iif  => 'eth1', daddr => '10.1.0.20',          # fuer die Firewall (optional)
      port => 22, auth => 'publickey',                 # Vorgaben
  }, 'srv1' );
  # ( 1, 'Welcome …' ) oder ( 0, 'anna@srv1: Permission denied (publickey).', 'Authentication refused: …' )

=head1 DESCRIPTION

Die Anmeldung eines Benutzers am OpenSSH-Server eines simulierten
Linux-Geräts (cai-platform F<docs/entwurf-evals.md> §3.3.1), aufgesetzt auf
L<Langertha::Holmgang::Sim::Linux::Sshd>. Geprüft wird in der Reihenfolge, in der
sshd sie sieht:

=over

=item 1. Dienst C<ssh> läuft, C<Port> der B<geladenen> Konfiguration passt
(sonst „Connection refused"); die nftables-Firewall lässt die Verbindung durch
(L<Langertha::Holmgang::Sim::Linux::Nft>, sonst „Connection timed out").

=item 2. Die Konfiguration B<für diese Verbindung>: global (erster Wert gewinnt)
und darüber die zutreffenden C<Match>-Abschnitte (C<User>, C<Group>,
C<Address>, C<LocalPort>, C<all>; Muster mit C<*>, C<?>, C<!> und CIDR), in
einem zutreffenden Abschnitt wieder der erste Wert.

=item 3. Konto (vorhanden, nicht abgelaufen, Shell gültig), C<PermitRootLogin>
(C<no>; C<prohibit-password> verbietet root das Passwort; C<forced-commands-only>
lässt nur Schlüssel mit C<command=> zu),
C<DenyUsers>/C<AllowUsers>/C<DenyGroups>/C<AllowGroups>.

=item 4. Schlüssel: C<PubkeyAuthentication>, die Dateien aus
C<AuthorizedKeysFile> (C<%h>, C<%u>, C<%%>, relativ zum Heimatverzeichnis),
mit C<StrictModes> (Vorgabe C<yes>) die Rechte: die Datei und jedes
Verzeichnis bis zum Heimatverzeichnis gehört dem Benutzer oder root und ist für
Gruppe und andere nicht schreibbar; Optionen C<from="…"> der Schlüsselzeile.
Passwort (C<auth: password>): C<PasswordAuthentication> und ein Passwort am
Konto, nicht gesperrt.

=back

Was sshd geladen hat, steht in C<services.ssh._loaded> (Texte der
Konfigurationsdateien zum Zeitpunkt von Start, Neustart oder reload); fehlt es,
gelten die Dateien des Anfangszustands (L</remember>). Eine Änderung an
F</etc/ssh/sshd_config> wirkt also erst nach C<reload>/C<restart> — wie bei
sshd. Benutzer im Zustand:

  users:
    anna: { uid: 1001, groups: [anna, devs], home: /home/anna, shell: /bin/bash, password: true }
  dirs:  { /home/anna: { owner: anna, group: anna, mode: "0755" }, /home/anna/.ssh: { owner: anna, mode: "0700" } }
  files: { /home/anna/.ssh/authorized_keys: { owner: anna, mode: "0600", content: "ssh-ed25519 AAAA… anna@laptop\n" } }
  ssh_tries: [ { user: anna, from: 10.1.0.77, key: "ssh-ed25519 AAAA…", iif: eth1, daddr: 10.1.0.20 } ]

C<ssh_tries> sind Anmeldeversuche anderer (z. B. der Kollegin aus der
Störungsmeldung); das Journal von C<ssh> zeigt zu jedem die Zeilen, die sshd
schreiben würde (L</journal>).

=cut

my $MAIN = '/etc/ssh/sshd_config';

sub _files { my ($dev) = @_; return ref $dev->{files} eq 'HASH' ? $dev->{files} : {} }

sub _svc {
    my ($dev) = @_;
    my $s = $dev->{services} || {};
    return $s->{ssh} // $s->{sshd};
}

sub _text {
    my ( $files, $p ) = @_;
    my $e = $files->{$p};
    return undef unless defined $e;
    return ref $e eq 'HASH' ? ( $e->{content} // '' ) : $e;
}

=func remember

  remember($dev);

Hält fest, welche sshd-Konfiguration geladen ist (Texte unter F</etc/ssh>), wenn
das noch nicht geschehen ist — vor dem ersten Befehl eines Falls und nach jedem
erfolgreichen Laden des Dienstes (L</loaded>).

=cut

sub remember {
    my ($dev) = @_;
    my $svc = _svc($dev) or return;
    return if exists $svc->{_loaded};
    loaded($dev);
    return;
}

=func loaded

  loaded($dev);   # nach start/restart/reload von ssh

=cut

sub loaded {
    my ($dev) = @_;
    my $svc = _svc($dev) or return;
    my $f = _files($dev);
    $svc->{_loaded} = { map { $_ => _text( $f, $_ ) } grep { m{\A/etc/ssh/} && !m{/ssh_host_} } keys %$f };
    return;
}

sub _snapshot {
    my ($dev) = @_;
    my $svc = _svc($dev) || {};
    return $svc->{_loaded} if ref $svc->{_loaded} eq 'HASH';
    my $f = _files($dev);
    return { map { $_ => _text( $f, $_ ) } grep { m{\A/etc/ssh/} } keys %$f };
}

# Zeilen der Konfiguration mit aufgeloesten Include (wie sshd, an Ort und Stelle)
sub _lines {
    my ( $snap, $file, $depth ) = @_;
    return () if $depth > 8;
    my $t = $snap->{$file} // return ();
    my @out;
    for my $line ( split /\n/, $t ) {
        ( my $l = $line ) =~ s/\A\s+|\s+\z//g;
        next if $l eq '' || $l =~ /\A#/;
        if ( $l =~ /\AInclude\s+(.+)\z/i ) {
            for my $pat ( split /\s+/, $1 ) {
                $pat = "/etc/ssh/$pat" unless $pat =~ m{\A/};
                ( my $re = quotemeta $pat ) =~ s/\\\*/[^\/]*/g;
                push @out, _lines( $snap, $_, $depth + 1 ) for sort grep {/\A$re\z/} keys %$snap;
            }
            next;
        }
        push @out, $l;
    }
    return @out;
}

sub _kv {
    my ($l) = @_;
    my ( $k, $v ) = $l =~ /\A(\S+?)(?:\s*=\s*|\s+)(.*)\z/ or return;
    $v =~ s/\A"(.*)"\z/$1/;
    return ( lc $k, $v );
}

my %LIST = map { $_ => 1 } qw( allowusers allowgroups denyusers denygroups port listenaddress authorizedkeysfile );

sub _ip_in {
    my ( $ip, $pat ) = @_;
    return 0 unless defined $ip;
    if ( $pat =~ m{/} ) {
        my $r = Langertha::Holmgang::Sim::Linux::Nft::_range($pat) or return 0;
        my ( $f, $b ) = Langertha::Holmgang::Sim::Linux::Nft::_addr_bin($ip) or return 0;
        return 0 unless $f == $r->[0];
        my $bits = unpack( 'B*', $b );
        return $bits ge $r->[1] && $bits le $r->[2] ? 1 : 0;
    }
    ( my $re = quotemeta $pat ) =~ s/\\\*/.*/g;
    $re =~ s/\\\?/./g;
    return $ip =~ /\A$re\z/ ? 1 : 0;
}

sub _pat { my ( $p, $v ) = @_; ( my $re = quotemeta $p ) =~ s/\\\*/.*/g; $re =~ s/\\\?/./g; return defined $v && $v =~ /\A$re\z/ ? 1 : 0 }

# Musterliste wie sshd (Komma, ! verneint: passt ein verneintes, passt die Liste nicht)
sub _list_match {
    my ( $list, $test ) = @_;
    my $hit = 0;
    for my $p ( split /\s*,\s*/, $list ) {
        if ( $p =~ s/\A!// ) { return 0 if $test->($p) }
        elsif ( $test->($p) ) { $hit = 1 }
    }
    return $hit;
}

sub _criteria_match {
    my ( $crit, $c ) = @_;
    my @w = split /\s+/, $crit;
    return 1 if @w == 1 && lc $w[0] eq 'all';
    while (@w) {
        my $k = lc shift @w;
        my $v = shift @w // return 0;
        if    ( $k eq 'user' )      { return 0 unless _list_match( $v, sub { _pat( $_[0], $c->{user} ) } ) }
        elsif ( $k eq 'group' )     { return 0 unless _list_match( $v, sub { my $p = $_[0]; grep { _pat( $p, $_ ) } @{ $c->{groups} } } ) }
        elsif ( $k eq 'address' )   { return 0 unless _list_match( $v, sub { _ip_in( $c->{from}, $_[0] ) } ) }
        elsif ( $k eq 'localport' ) { return 0 unless _list_match( $v, sub { $_[0] eq $c->{port} } ) }
        else { return 0 }    # Host, LocalAddress, RDomain: hier nicht nachgebildet -> trifft nicht zu
    }
    return 1;
}

=func config_for

  my $eff = config_for( $dev, { user, from, groups => [...], port } );

Die Einstellungen der geladenen Konfiguration für diese Verbindung (Schlüssel
klein, Listen als Liste).

=cut

sub config_for {
    my ( $dev, $c, $files ) = @_;
    my ( $eff, $over ) = _config( $dev, $c, $files );
    return $eff;
}

=func match_overrides

  my $set = match_overrides( $dev, { user, from, groups, port }, 1 );

Nur die Werte, die zutreffende C<Match>-Abschnitte setzen; mit wahrem dritten
Argument aus den Dateien (wie C<sshd -T -C>), sonst aus der geladenen
Konfiguration.

=cut

sub match_overrides {
    my ( $dev, $c, $files ) = @_;
    my ( $eff, $over ) = _config( $dev, $c, $files );
    return $over;
}

sub _config {
    my ( $dev, $c, $files ) = @_;
    my $snap = $files ? { map { $_ => _text( _files($dev), $_ ) } grep { m{\A/etc/ssh/} } keys %{ _files($dev) } } : _snapshot($dev);
    my ( %glob, @blocks );
    my $cur;
    for my $l ( _lines( $snap, $MAIN, 0 ) ) {
        my ( $k, $v ) = _kv($l) or next;
        if ( $k eq 'match' ) { push @blocks, $cur = { crit => $v, set => {} }; next }
        my $h = $cur ? $cur->{set} : \%glob;
        if ( $LIST{$k} ) { push @{ $h->{$k} }, split /\s+/, $v; next }
        $h->{$k} = $v unless exists $h->{$k};
    }
    my %eff = %glob;
    my %over;
    for my $b ( grep { _criteria_match( $_->{crit}, $c ) } @blocks ) {
        for my $k ( grep { !/\A_/ } keys %{ $b->{set} } ) {
            next if exists $over{$k};
            $eff{$k} = $over{$k} = $b->{set}{$k};
        }
    }
    return ( \%eff, \%over );
}

sub _yes { my ( $v, $def ) = @_; return lc( $v // $def ) eq 'yes' ? 1 : 0 }

sub _entry {
    my ( $dev, $p ) = @_;
    my $f = _files($dev);
    return ( ref $f->{$p} eq 'HASH' ? $f->{$p} : { content => $f->{$p} } ) if exists $f->{$p};
    return ( { mode => '0755', %{ $dev->{dirs}{$p} } }, 'dir' ) if ( $dev->{dirs} || {} )->{$p};
    return;
}

# StrictModes: Datei und Verzeichnisse bis zum Heimatverzeichnis
sub _strict_bad {
    my ( $dev, $user, $home, $file ) = @_;
    my ( $e ) = _entry( $dev, $file );
    my $chk = sub {
        my ( $x, $p, $what ) = @_;
        my $o = $x->{owner} // 'root';
        my $m = oct( $x->{mode} // ( $what eq 'file' ? '0644' : '0755' ) );
        return "bad ownership or modes for $what $p" if ( $o ne $user && $o ne 'root' ) || ( $m & 022 );
        return undef;
    };
    my $bad = $chk->( $e, $file, 'file' );
    return $bad if $bad;
    ( my $d = $file ) =~ s{/[^/]+\z}{};
    while ( length $d >= length $home ) {
        my ($de) = _entry( $dev, $d );
        $de //= { mode => '0755', owner => $d eq $home ? $user : 'root' };
        $bad = $chk->( $de, $d, 'directory' );
        return $bad if $bad;
        last if $d eq $home;
        $d =~ s{/[^/]+\z}{} or last;
    }
    return undef;
}

sub _key_parts {
    my ($line) = @_;
    my @t;
    my $s = $line;
    while ( length $s ) {
        $s =~ s/\A\s+//;
        last unless length $s;
        if ( $s =~ s/\A((?:[^\s"]|"[^"]*")+)// ) { push @t, $1 } else { last }
    }
    my $i = 0;
    $i++ while $i < @t && $t[$i] !~ /\A(?:ssh-|ecdsa-|sk-)/;
    return if $i >= @t;
    my $opts = $i ? $t[0] : '';
    return ( $opts, $t[$i], $t[ $i + 1 ] // '' );
}

sub _from_ok {
    my ( $opts, $from ) = @_;
    return 1 unless $opts =~ /(?:\A|,)from="([^"]*)"/;
    return _list_match( $1, sub { _ip_in( $from, $_[0] ) } );
}

=func check

  my ( $ok, $client, @log ) = check( $dev, \%versuch, $host );

C<$ok> 1/0, C<$client> die Meldung des ssh-Clients, C<@log> die Zeilen von sshd
(ohne Zeitstempel).

=cut

sub check {
    my ( $dev, $t, $host ) = @_;
    $host //= 'host';
    my $user = $t->{user} // 'root';
    my $from = $t->{from} // '0.0.0.0';
    my $port = $t->{port} // 22;
    my $sport = 50000 + ( unpack( '%16C*', "$user$from" ) % 10000 );
    my $deny = sub { my ( $methods, @log ) = @_; return ( 0, "$user\@$host: Permission denied ($methods).", @log ) };
    my $svc = _svc($dev);
    return ( 0, "ssh: connect to host $host port $port: Connection refused" ) unless $svc && $svc->{active};
    my $glob = config_for( $dev, { user => "\0", from => "\0", groups => [], port => $port } );
    my @ports = @{ $glob->{port} || [22] };
    return ( 0, "ssh: connect to host $host port $port: Connection refused" ) unless grep { $_ == $port } @ports;
    if ( ref $dev->{nft} eq 'HASH' && %{ $dev->{nft} } && defined $t->{daddr} ) {
        my ($v) = Langertha::Holmgang::Sim::Linux::Nft::verdict( $dev, { hook => 'input', proto => 'tcp', dport => $port, sport => $sport,
            saddr => $from, daddr => $t->{daddr}, ( defined $t->{iif} ? ( iif => $t->{iif} ) : () ) } );
        return ( 0, "ssh: connect to host $host port $port: Connection timed out" ) if defined $v && $v eq 'drop';
    }
    my $u = $user eq 'root' ? { home => '/root', groups => ['root'], %{ ( $dev->{users} || {} )->{root} || {} } } : ( $dev->{users} || {} )->{$user};
    my $conn = "from $from port $sport";
    return $deny->( 'publickey', "Invalid user $user $conn", "Connection closed by invalid user $user $from port $sport [preauth]" ) unless $u;
    my @groups = @{ $u->{groups} || [$user] };
    my $eff = config_for( $dev, { user => $user, from => $from, groups => \@groups, port => $port } );
    my $methods = join ',', ( _yes( $eff->{pubkeyauthentication}, 'yes' ) ? 'publickey' : () ),
        ( _yes( $eff->{passwordauthentication}, 'yes' ) ? 'password' : () );
    $methods ||= 'none';
    my $closed = "Connection closed by authenticating user $user $from port $sport [preauth]";
    my $shell = $u->{shell} // '/bin/bash';
    return $deny->( $methods, "User $user not allowed because account has expired", $closed ) if $u->{expired};
    return $deny->( $methods, "User $user not allowed because shell $shell does not exist", $closed ) if $shell =~ m{/(?:nologin|false)\z};
    if ( $user eq 'root' && lc( $eff->{permitrootlogin} // 'prohibit-password' ) eq 'no' ) {
        return $deny->( $methods, "ROOT LOGIN REFUSED $conn", $closed );
    }
    my $um = sub { my $p = shift; my ( $pu, $ph ) = split /@/, $p, 2; _pat( $pu, $user ) && ( !defined $ph || _ip_in( $from, $ph ) ) };
    my $gm = sub { my $p = shift; grep { _pat( $p, $_ ) } @groups };
    return $deny->( $methods, "User $user from $from not allowed because listed in DenyUsers", $closed ) if grep { $um->($_) } @{ $eff->{denyusers} || [] };
    return $deny->( $methods, "User $user from $from not allowed because not listed in AllowUsers", $closed )
        if $eff->{allowusers} && !grep { $um->($_) } @{ $eff->{allowusers} };
    return $deny->( $methods, "User $user from $from not allowed because a group is listed in DenyGroups", $closed ) if grep { $gm->($_) } @{ $eff->{denygroups} || [] };
    return $deny->( $methods, "User $user from $from not allowed because none of user's groups are listed in AllowGroups", $closed )
        if $eff->{allowgroups} && !grep { $gm->($_) } @{ $eff->{allowgroups} };

    my $auth = $t->{auth} // 'publickey';
    if ( $auth eq 'password' ) {
        return $deny->( $methods, $closed ) unless _yes( $eff->{passwordauthentication}, 'yes' ) && $u->{password} && !$u->{locked};
        return $deny->( $methods, "Failed password for root $conn ssh2", $closed )
            if $user eq 'root' && lc( $eff->{permitrootlogin} // 'prohibit-password' ) ne 'yes';
        return ( 1, "Linux $host 6.1.0-26-amd64 #1 SMP PREEMPT_DYNAMIC Debian 6.1.112-1 x86_64", "Accepted password for $user $conn ssh2" );
    }
    return $deny->( $methods, $closed ) unless _yes( $eff->{pubkeyauthentication}, 'yes' );
    my $home = $u->{home} // ( $user eq 'root' ? '/root' : "/home/$user" );
    my @akf = @{ $eff->{authorizedkeysfile} || [qw( .ssh/authorized_keys .ssh/authorized_keys2 )] };
    my $strict = _yes( $eff->{strictmodes}, 'yes' );
    my ( $ktype, $kblob ) = split /\s+/, $t->{key} // '';
    my @log;
    for my $raw (@akf) {
        next if lc $raw eq 'none';
        ( my $p = $raw ) =~ s/%h/$home/g;
        $p =~ s/%u/$user/g;
        $p =~ s/%%/%/g;
        $p = "$home/$p" unless $p =~ m{\A/};
        my ($e) = _entry( $dev, $p );
        next unless $e && defined $e->{content};
        if ($strict) {
            if ( my $bad = _strict_bad( $dev, $user, $home, $p ) ) { push @log, "Authentication refused: $bad"; next }
        }
        my $m = oct( $e->{mode} // '0644' );
        my $readable = ( $e->{owner} // 'root' ) eq $user ? ( $m & 0400 ) : ( $m & 0004 );
        next unless $readable || $user eq 'root';
        my $n = 0;
        for my $line ( split /\n/, $e->{content} ) {
            $n++;
            next if $line =~ /\A\s*(?:#|\z)/;
            my ( $opts, $type, $blob ) = _key_parts($line) or next;
            next unless defined $ktype && $type eq $ktype && $blob eq ( $kblob // '' );
            if ( $user eq 'root' && lc( $eff->{permitrootlogin} // '' ) eq 'forced-commands-only' && $opts !~ /(?:\A|,)command="/ ) {
                push @log, "ROOT LOGIN REFUSED $conn";
                next;
            }
            if ( !_from_ok( $opts, $from ) ) {
                push @log, "Authentication tried for $user with correct key but not from a permitted host (host=$from, ip=$from).";
                next;
            }
            return ( 1, "Linux $host 6.1.0-26-amd64 #1 SMP PREEMPT_DYNAMIC Debian 6.1.112-1 x86_64",
                "Accepted publickey for $user $conn ssh2: " . uc( ( $type =~ /ssh-(\w+)/ )[0] // 'KEY' ) . ' SHA256:' . substr( $blob, 12, 43 ) );
        }
    }
    return $deny->( $methods, @log, $closed );
}

=func journal

  my @zeilen = journal( $dev, $host );

Zeilen von sshd zu den Anmeldeversuchen C<ssh_tries> (mit Zeitstempel), gegen
den jetzigen Stand geprüft.

=cut

sub journal {
    my ( $dev, $host ) = @_;
    $host //= $dev->{hostname} // 'localhost';
    my @l;
    my $min = 10;
    for my $t ( @{ $dev->{ssh_tries} || [] } ) {
        my ( $ok, undef, @log ) = check( $dev, $t, $host );
        push @l, map { sprintf( 'Oct 24 07:%02d:%02d %s sshd[%d]: %s', $min, 11, $host, 3100 + $min, $_ ) } @log;
        $min++;
    }
    return @l;
}

1;
