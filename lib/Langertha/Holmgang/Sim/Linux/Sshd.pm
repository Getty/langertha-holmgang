package Langertha::Holmgang::Sim::Linux::Sshd;
# ABSTRACT: OpenSSH server on a simulated Linux server — sshd -t/-T, Include, effect of reload/restart, login

use strict;
use warnings;
use utf8;

use JSON::MaybeXS ();

our $VERSION = '0.001';

=head1 SYNOPSIS

  # aus dem Linux-Simulator
  my ( $out, $ok ) = Langertha::Holmgang::Sim::Linux::Sshd::sshd( $dev, [ '-t' ] );
  Langertha::Holmgang::Sim::Linux::Sshd::load( $dev, 'ssh', 'reload' );   # die bei Fehler
  my $why = Langertha::Holmgang::Sim::Linux::Sshd::login_denied( $dev, $host );

=head1 DESCRIPTION

Der OpenSSH-Server eines Debian-12-Geräts vom Typ C<linux>
(cai-platform F<docs/entwurf-evals.md> §3.3.1). Aktiv nur, wenn F</etc/ssh/sshd_config> im
Zustand steht; sonst bleibt der Dienst C<ssh> ein gewöhnlicher Dienst.

  files:
    /etc/ssh/sshd_config: "Include /etc/ssh/sshd_config.d/*.conf\n…"
    /etc/ssh/sshd_config.d/50-cloud.conf: "PasswordAuthentication yes\n"
    /etc/ssh/ssh_host_ed25519_key: { mode: "0600", content: "" }   # optional
  services:
    ssh: { active: true, effective: { passwordauthentication: "yes", allowgroups: [ admins ] } }
  ssh_login: { user: ops, from: 10.10.99.15 }   # optional: so ist das Modell angemeldet

B<Lesen der Konfiguration> wie sshd: F</etc/ssh/sshd_config>, C<Include>
(Glob, sortiert; relative Pfade unter F</etc/ssh>) an Ort und Stelle; der
B<erste> Wert eines Schlüsselworts gilt, Listen (C<AllowUsers>,
C<AllowGroups>, C<DenyUsers>, C<DenyGroups>, C<ListenAddress>, C<Port>,
C<HostKey>, C<AcceptEnv>) sammeln sich an. Zeilen nach C<Match> gelten nur
bedingt und gehen nicht in die globale Konfiguration ein (bis zum Ende der
Datei). Unbekannte Schlüsselwörter, fehlende und ungültige Werte sind
Fehler wie bei sshd.

B<Effektive Konfiguration> (C<services.ssh.effective>): die ausdrücklich
gesetzten globalen Werte (Schlüssel klein geschrieben, Listen als Liste). Sie
ändert sich nur, wenn sshd die Dateien liest: C<start>, C<restart>,
C<reload>. Ist die Konfiguration fehlerhaft oder kein Host-Schlüssel ladbar
(privater Schlüssel für Gruppe/andere lesbar), scheitert C<reload> und sshd
läuft mit der alten weiter; C<start>/C<restart> lassen den Dienst C<failed>
zurück (Journal nennt die Ursache).

B<Befehle:> C<sshd -t>, C<sshd -T> (effektive Konfiguration der Dateien,
mit Vorgaben), C<sshd -f datei>.

B<Anmeldung> (C<ssh_login>): Ist der Dienst nicht aktiv, verweigert der Server
die Verbindung; schließt die laufende Konfiguration den Benutzer aus
(C<DenyUsers>, C<AllowUsers>, C<DenyGroups>, C<AllowGroups>, C<PermitRootLogin
no> für root, C<PubkeyAuthentication no>) oder ist sein Konto abgelaufen bzw.
ohne Shell, ist der Zugang verloren — wie auf einem echten Server, bei dem man
sich aussperrt.

=cut

my %YESNO = map { $_ => 1 } qw( passwordauthentication pubkeyauthentication kbdinteractiveauthentication
    challengeresponseauthentication usepam x11forwarding permitemptypasswords allowagentforwarding printmotd
    printlastlog tcpkeepalive usedns strictmodes hostbasedauthentication ignorerhosts gssapiauthentication
    kerberosauthentication disableforwarding x11uselocalhost permittty exposeauthinfo );
my %ENUM = (
    permitrootlogin    => [qw( yes no prohibit-password without-password forced-commands-only )],
    allowtcpforwarding => [qw( yes no all local remote )],
    allowstreamlocalforwarding => [qw( yes no all local remote )],
    gatewayports       => [qw( yes no clientspecified )],
    compression        => [qw( yes no delayed )],
    permittunnel       => [qw( yes no point-to-point ethernet )],
    permituserenvironment => [qw( yes no )],
    addressfamily      => [qw( any inet inet6 )],
    loglevel           => [qw( quiet fatal error info verbose debug debug1 debug2 debug3 )],
    fingerprinthash    => [qw( md5 sha256 )],
);
my %INT = map { $_ => 1 } qw( port maxauthtries maxsessions clientaliveinterval clientalivecountmax x11displayoffset );
my %LIST = map { $_ => 1 } qw( allowusers allowgroups denyusers denygroups listenaddress port hostkey acceptenv );
my %TEXT = map { $_ => 1 } qw( logingracetime syslogfacility ciphers macs kexalgorithms hostkeyalgorithms
    pubkeyacceptedalgorithms pubkeyacceptedkeytypes casignaturealgorithms banner authorizedkeysfile chrootdirectory
    forcecommand authenticationmethods pidfile permitlisten permitopen versionaddendum trustedusercakeys revokedkeys
    authorizedprincipalsfile ipqos rekeylimit maxstartups persourcemaxstartups subsystem authorizedkeyscommand
    authorizedkeyscommanduser hostcertificate moduli securitykeyprovider setenv streamlocalbindmask
    streamlocalbindunlink unusedconnectiontimeout channeltimeout xauthlocation );

# Vorgaben fuer sshd -T (Auszug, Debian 12 / OpenSSH 9.2)
my @DEFAULTS = (
    [ port => '22' ], [ addressfamily => 'any' ], [ listenaddress => '[::]:22' ], [ listenaddress => '0.0.0.0:22' ],
    [ usepam => 'no' ], [ logingracetime => '120' ], [ x11displayoffset => '10' ], [ maxauthtries => '6' ],
    [ maxsessions => '10' ], [ clientaliveinterval => '0' ], [ clientalivecountmax => '3' ], [ permitrootlogin => 'without-password' ],
    [ ignorerhosts => 'yes' ], [ hostbasedauthentication => 'no' ], [ pubkeyauthentication => 'yes' ],
    [ kerberosauthentication => 'no' ], [ gssapiauthentication => 'no' ], [ passwordauthentication => 'yes' ],
    [ kbdinteractiveauthentication => 'yes' ], [ printmotd => 'yes' ], [ printlastlog => 'yes' ], [ x11forwarding => 'no' ],
    [ x11uselocalhost => 'yes' ], [ permittty => 'yes' ], [ permituserenvironment => 'no' ], [ compression => 'yes' ],
    [ tcpkeepalive => 'yes' ], [ usedns => 'no' ], [ strictmodes => 'yes' ], [ permitemptypasswords => 'no' ],
    [ allowtcpforwarding => 'yes' ], [ allowagentforwarding => 'yes' ], [ gatewayports => 'no' ], [ permittunnel => 'no' ],
    [ loglevel => 'INFO' ], [ syslogfacility => 'AUTH' ], [ authorizedkeysfile => '.ssh/authorized_keys .ssh/authorized_keys2' ],
    [ maxstartups => '10:30:100' ], [ pidfile => '/run/sshd.pid' ],
);

my $MAIN = '/etc/ssh/sshd_config';

sub _files { my ($dev) = @_; return ref $dev->{files} eq 'HASH' ? $dev->{files} : {} }

=func active

Wahr, wenn das Gerät eine F</etc/ssh/sshd_config> hat (nur dann simuliert
dieses Modul sshd).

=cut

sub active { my ($dev) = @_; return exists _files($dev)->{$MAIN} ? 1 : 0 }

sub _text {
    my ( $dev, $p ) = @_;
    my $e = _files($dev)->{$p};
    return undef unless defined $e;
    return ref $e eq 'HASH' ? ( $e->{content} // '' ) : $e;
}

sub _glob {
    my ( $dev, $pat ) = @_;
    $pat = "/etc/ssh/$pat" unless $pat =~ m{\A/};
    return ($pat) unless $pat =~ /[*?]/;
    ( my $re = quotemeta $pat ) =~ s/\\\*/[^\/]*/g;
    $re =~ s/\\\?/[^\/]/g;
    return sort grep {/\A$re\z/} keys %{ _files($dev) };
}

=func parse

  my ( $settings, $errors ) = parse( $dev [, $datei] );

Liest die Konfiguration wie sshd. C<$settings>: globale, ausdrücklich gesetzte
Werte (erster gewinnt, Listen gesammelt); C<$errors>: Fehlermeldungen wie sshd.

=cut

sub parse {
    my ( $dev, $file ) = @_;
    $file //= $MAIN;
    my ( %set, @err );
    my $bad = 0;
    my $read;
    $read = sub {
        my ( $f, $depth ) = @_;
        my $t = _text( $dev, $f );
        if ( !defined $t ) { push @err, "$f: No such file or directory" if $depth == 0; return }
        my $n = 0;
        my $in_match = 0;
        for my $line ( split /\n/, $t ) {
            $n++;
            $line =~ s/\A\s+//;
            next if $line eq '' || $line =~ /\A#/;
            my ( $kw, $rest ) = $line =~ /\A([^\s=]+)(?:\s*=\s*|\s+)?(.*?)\s*\z/;
            next unless defined $kw;
            my $k = lc $kw;
            if ( $k eq 'include' ) {
                if ( $rest eq '' ) { push @err, "$f line $n: missing argument."; $bad++; next }
                $read->( $_, $depth + 1 ) for map { _glob( $dev, $_ ) } split /\s+/, $rest;
                next;
            }
            if ( $k eq 'match' ) {
                if ( $rest eq '' ) { push @err, "$f line $n: missing argument."; $bad++; next }
                $in_match = 1;
                next;
            }
            if ( !$YESNO{$k} && !$ENUM{$k} && !$INT{$k} && !$LIST{$k} && !$TEXT{$k} ) {
                push @err, "$f: line $n: Bad configuration option: $kw";
                $bad++;
                next;
            }
            if ( $rest eq '' ) { push @err, "$f line $n: missing argument."; $bad++; next }
            my $v = $rest;
            $v =~ s/\A"(.*)"\z/$1/;
            if ( ( $YESNO{$k} || $ENUM{$k} || $INT{$k} ) && $v =~ /\A\S+\s+\S/ ) {
                push @err, "$f line $n: keyword $kw extra arguments at end of line";
                $bad++;
                next;
            }
            if ( $YESNO{$k} || $ENUM{$k} ) {
                my @ok = $YESNO{$k} ? qw( yes no ) : @{ $ENUM{$k} };
                if ( !grep { $_ eq lc $v } @ok ) { push @err, "$f line $n: unsupported option \"$v\"."; $bad++; next }
                $v = lc $v;
            }
            if ( $INT{$k} && $v !~ /\A\d+\z/ ) { push @err, "$f line $n: invalid integer value \"$v\"."; $bad++; next }
            next if $in_match;
            if ( $LIST{$k} ) { push @{ $set{$k} }, split /\s+/, $v; next }
            $set{$k} = $v unless exists $set{$k};
        }
    };
    $read->( $file, 0 );
    push @err, "$file: terminating, $bad bad configuration options" if $bad;
    return ( \%set, \@err );
}

sub _hostkey_errors {
    my ( $dev, $set ) = @_;
    my @keys = $set->{hostkey} ? @{ $set->{hostkey} } : map {"/etc/ssh/ssh_host_${_}_key"} qw( rsa ecdsa ed25519 );
    my @present = grep { exists _files($dev)->{$_} } @keys;
    return () unless grep { m{/ssh_host_} } keys %{ _files($dev) };    # Fall ohne Host-Schluessel: nicht pruefen
    my ( @err, $good );
    for my $k (@present) {
        my $e = _files($dev)->{$k};
        my $m = ref $e eq 'HASH' ? oct( $e->{mode} // '0600' ) : 0600;
        if ( $m & 077 ) {
            push @err, '@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@',
                '@         WARNING: UNPROTECTED PRIVATE KEY FILE!          @',
                '@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@',
                sprintf( "Permissions 0%o for '%s' are too open.", $m & 07777, $k ),
                'It is required that your private key files are NOT accessible by others.',
                'This private key will be ignored.',
                "Unable to load host key \"$k\": bad permissions",
                "Unable to load host key: $k";
            next;
        }
        $good++;
    }
    return ( @err, $good ? () : 'sshd: no hostkeys available -- exiting.' ) if @err || !$good;
    return ();
}

# Fehler, die sshd am Start hindern (Konfiguration, kein ladbarer Host-Schluessel)
sub _fatal {
    my ($dev) = @_;
    my ( $set, $err ) = parse($dev);
    return ( $set, @$err ) if @$err;
    my @hk = _hostkey_errors( $dev, $set );
    return ( $set, ( grep {/no hostkeys/} @hk ) ? @hk : () );
}

=func sshd

  my ( $out, $ok ) = sshd( $dev, \@argv );

C<sshd -t> (prüfen: still bei Erfolg), C<sshd -T> (effektive Konfiguration),
C<-f datei>. Ohne C<-t>/C<-T> lehnt sshd ab (läuft schon als Dienst).

=cut

sub sshd {
    my ( $dev, $av ) = @_;
    my @a = @$av;
    my ( $test, $dump, $file ) = ( 0, 0, $MAIN );
    while (@a) {
        my $x = shift @a;
        if    ( $x eq '-t' ) { $test = 1 }
        elsif ( $x eq '-T' ) { $dump = 1 }
        elsif ( $x eq '-f' ) { $file = shift(@a) // return ( 'option requires an argument -- f', 0 ) }
        elsif ( $x =~ /\A-[tT]+\z/ ) { $test = 1; $dump = 1 if $x =~ /T/ }
        elsif ( $x eq '-C' ) { shift @a }
        else { return ( "unknown option -- " . substr( $x, 1 ), 0 ) }
    }
    my ( $set, $err ) = parse( $dev, $file );
    return ( join( "\n", @$err ), 0 ) if @$err;
    my @hk = _hostkey_errors( $dev, $set );
    return ( join( "\n", @hk ), 0 ) if grep {/no hostkeys/} @hk;
    if ($dump) {
        my ( @order, %def );
        for (@DEFAULTS) { push @order, $_->[0] unless $def{ $_->[0] }; push @{ $def{ $_->[0] } }, $_->[1] }
        my @l;
        for my $k ( @order, grep { !$def{$_} } sort keys %$set ) {
            my @v = exists $set->{$k} ? ( ref $set->{$k} ? @{ $set->{$k} } : $set->{$k} ) : @{ $def{$k} };
            push @l, map {"$k $_"} @v;
        }
        return ( join( "\n", @hk, @l ), 1 );
    }
    return ( join( "\n", @hk ), 1 ) if $test;
    return ( 'sshd re-exec requires execution with an absolute path', 0 );
}

=func load

  load( $dev, $dienst, $verb [, $host] );   # start | restart | reload

Wirkung auf den Dienst: liest die Konfiguration in C<effective>; bei Fehlern
C<die> mit der Meldung von systemctl — C<reload> lässt den laufenden sshd mit der
alten Konfiguration, C<start>/C<restart> hinterlassen ihn C<failed>.

=cut

sub load {
    my ( $dev, $name, $verb, $host ) = @_;
    my $svc = $dev->{services}{$name} or return;
    my ( $set, @fatal ) = _fatal($dev);
    if (@fatal) {
        $host //= $dev->{hostname} // 'localhost';
        if ( $verb ne 'reload' ) {
            $svc->{active} = JSON::MaybeXS::false() if $svc->{active};
            $svc->{failed} = JSON::MaybeXS::true() unless $svc->{failed};
        }
        push @{ $svc->{journal} }, map {"Oct 20 09:14:07 $host sshd[2207]: $_"} grep { !/\A@/ } @fatal;
        die "Job for $name.service failed because the control process exited with error code.\n"
            . "See \"systemctl status $name.service\" and \"journalctl -xeu $name.service\" for details.\n";
    }
    my $old = JSON::MaybeXS->new( canonical => 1 )->encode( $svc->{effective} // {} );
    $svc->{effective} = $set unless JSON::MaybeXS->new( canonical => 1 )->encode($set) eq $old;
    # wie im echten Journal: sshd lauscht wieder, systemd meldet den Start bzw. das Neuladen
    $host //= $dev->{hostname} // 'localhost';
    my @ports = @{ $set->{port} || [22] };
    push @{ $svc->{journal} },
        ( $verb eq 'reload' ? "Oct 20 09:14:07 $host sshd[701]: Received SIGHUP; restarting." : "Oct 20 09:14:07 $host systemd[1]: Starting $name.service - OpenBSD Secure Shell server..." ),
        ( map { ( "Oct 20 09:14:07 $host sshd[2207]: Server listening on 0.0.0.0 port $_.", "Oct 20 09:14:07 $host sshd[2207]: Server listening on :: port $_." ) } @ports ),
        "Oct 20 09:14:07 $host systemd[1]: " . ( $verb eq 'reload' ? 'Reloaded' : 'Started' ) . " $name.service - OpenBSD Secure Shell server.";
    return;
}

=func ssh_keygen

  my ( $out, $ok ) = ssh_keygen( $dev, \@argv, $host );

C<ssh-keygen -A> (fehlende Host-Schlüssel unter F</etc/ssh> neu erzeugen, privat
0600, öffentlich 0644) und C<ssh-keygen -l -f datei> (Fingerabdruck). Anderes
ist eine Lücke der Simulation (C<undef>).

=cut

sub ssh_keygen {
    my ( $dev, $av, $host ) = @_;
    my %o;
    my @a = @$av;
    my $file;
    while (@a) {
        my $x = shift @a;
        if ( $x eq '-f' ) { $file = shift @a; next }
        if ( $x =~ /\A-([A-Za-z]+)\z/ ) { $o{$_} = 1 for split //, $1; $file = shift @a if $x =~ /f\z/; next }
        return undef;
    }
    my $files = $dev->{files} //= {};
    if ( $o{A} ) {
        my @made;
        for my $t (qw( rsa ecdsa ed25519 )) {
            my $k = "/etc/ssh/ssh_host_${t}_key";
            next if exists $files->{$k};
            $files->{$k} = { content => "-----BEGIN OPENSSH PRIVATE KEY-----\n(neu erzeugt)\n-----END OPENSSH PRIVATE KEY-----\n", mode => '0600' };
            $files->{"$k.pub"} = { content => 'ssh-' . ( $t eq 'ecdsa' ? 'ecdsa-sha2-nistp256' : $t ) . " AAAA(neu) root\@$host\n", mode => '0644' };
            push @made, uc $t;
        }
        return ( @made ? 'ssh-keygen: generating new host keys: ' . join( ' ', @made ) . ' ' : '', 1 );
    }
    if ( $o{l} && defined $file ) {
        ( my $pub = $file ) =~ s/(?<!\.pub)\z/.pub/;
        my $e = $files->{$pub} // $files->{$file};
        return ( "ssh-keygen: $file: No such file or directory", 0 ) unless defined $e;
        my ($t) = $file =~ /ssh_host_(\w+)_key/;
        my $bits = { rsa => 3072, ecdsa => 256, ed25519 => 256 }->{ $t // '' } // 256;
        my $c = ref $e eq 'HASH' ? ( $e->{content} // '' ) : $e;
        my $fp = substr( join( '', map { sprintf '%02x', ord } split //, $c ) . ( '0' x 50 ), 7, 43 );
        return ( "$bits SHA256:$fp root\@$host (" . uc( $t // 'ED25519' ) . ')', 1 );
    }
    return undef;
}

sub _match_pat {
    my ( $pat, $v ) = @_;
    ( my $re = quotemeta $pat ) =~ s/\\\*/.*/g;
    $re =~ s/\\\?/./g;
    return $v =~ /\A$re\z/ ? 1 : 0;
}

sub _match_user {
    my ( $pat, $user, $from ) = @_;
    my ( $u, $h ) = split /@/, $pat, 2;
    return 0 unless _match_pat( $u, $user );
    return 1 unless defined $h;
    return 0 unless defined $from;
    if ( $h =~ m{\A(\d+\.\d+\.\d+\.\d+)/(\d+)\z} ) {
        my ( $net, $len ) = ( $1, $2 );
        my $n = sub { my $x = 0; $x = $x * 256 + $_ for split /\./, $_[0]; $x };
        my $mask = $len == 0 ? 0 : ( 0xFFFFFFFF << ( 32 - $len ) ) & 0xFFFFFFFF;
        return ( ( $n->($net) & $mask ) == ( $n->($from) & $mask ) ) ? 1 : 0;
    }
    return _match_pat( $h, $from );
}

=func login_denied

  my $msg = login_denied( $dev, $host );   # undef = Anmeldung geht

Kann sich C<ssh_login> (Benutzer, Herkunft) mit der laufenden Konfiguration
anmelden? Sonst die Meldung des Clients.

=cut

sub login_denied {
    my ( $dev, $host ) = @_;
    my $l = $dev->{ssh_login};
    return undef unless ref $l eq 'HASH' && active($dev);
    my $svc = ( $dev->{services} || {} )->{ $l->{service} // 'ssh' } || {};
    return "ssh: connect to host $host port 22: Connection refused" unless $svc->{active};
    my $user = $l->{user} // 'root';
    my $from = $l->{from};
    my $eff = $svc->{effective} || {};
    my $no = "$user\@$host: Permission denied (publickey).";
    return $no if ( $eff->{pubkeyauthentication} // 'yes' ) eq 'no';
    if ( $user eq 'root' ) {
        return $no if ( $eff->{permitrootlogin} // 'prohibit-password' ) eq 'no';
    }
    else {
        my $u = ( $dev->{users} || {} )->{$user} or return $no;
        return $no if $u->{expired};
        return $no if ( $u->{shell} // '/bin/bash' ) =~ m{/(?:nologin|false)\z};
    }
    my @groups = $user eq 'root' ? ('root') : @{ ( ( $dev->{users} || {} )->{$user} || {} )->{groups} || [] };
    return $no if grep { _match_user( $_, $user, $from ) } @{ $eff->{denyusers} || [] };
    return $no if $eff->{allowusers} && !grep { _match_user( $_, $user, $from ) } @{ $eff->{allowusers} };
    my $gm = sub { my $p = shift; grep { _match_pat( $p, $_ ) } @groups };
    return $no if grep { $gm->($_) } @{ $eff->{denygroups} || [] };
    return $no if $eff->{allowgroups} && !grep { $gm->($_) } @{ $eff->{allowgroups} };
    return undef;
}

1;
