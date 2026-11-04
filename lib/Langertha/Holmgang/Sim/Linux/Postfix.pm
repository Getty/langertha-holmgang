package Langertha::Holmgang::Sim::Linux::Postfix;
# ABSTRACT: Postfix auf einem simulierten Linux-Server — postconf, postmap, newaliases, Warteschlange

use strict;
use warnings;
use utf8;

our $VERSION = '0.001';

=head1 SYNOPSIS

  # aus dem Linux-Simulator: postconf, postfix, postmap, postalias, newaliases, postqueue, mailq, postsuper, postcat
  Langertha::Holmgang::Sim::Linux::Postfix::prepare( $dev );       # beim Laden des Falls

=head1 DESCRIPTION

Postfix 3.7 (Debian 12, Dienst C<postfix>) auf einem Gerät vom Typ C<linux>
(cai-platform F<docs/entwurf-evals.md> §3.3.1). F</etc/postfix/main.cf> und die Tabellen
sind Dateien unter C<files>; der Zustand steht unter C<postfix>:

  postfix:
    running: { relayhost: "[smtp.example.net]:587", … }   # geladene Parameter; fehlt es, liest prepare() main.cf
    queue:
      - { id: 4F2A11C0D3, from: a@example.com, to: [ b@example.org ], size: 2311,
          time: "Tue Oct 20 08:12:01", queue: deferred,                 # deferred | hold | active
          reason: "connect to …: Connection timed out",
          deliver_when: [ { path: [ postfix, running, relayhost ], equals: "[smtp.example.net]:587" } ] }
    delivered: [ … ]                                         # vom Simulator: zugestellte IDs
    deleted:   [ … ]                                         # vom Simulator: gelöschte IDs

B<Befehle>: C<postconf [-n|-d|-h] [name …]>, C<postconf -e 'name = wert' …>,
C<postconf -X name …>, C<postfix check|reload|status|flush|start|stop>,
C<postmap [-q schlüssel] [typ:]datei> (baut F<datei.db> aus der Datei; Rechte
und Eigentümer wie die Quelle), C<postalias>/C<newaliases> (F</etc/aliases.db>),
C<postqueue -p|-f|-i id>, C<mailq>, C<postsuper -d|-h|-H|-r id|ALL [queue]>
(C<-> liest IDs von der Eingabe), C<postcat -q id>; C<systemctl reload|restart
postfix> wie C<postfix reload>.

B<Wie Postfix>: C<postconf> liest und schreibt die Datei; was läuft, ändert
erst C<postfix reload> (bzw. Neustart). Zahlen-Parameter ohne Einheit
(C<message_size_limit = 50M> ist ein Fehler, reload scheitert:
C<bad numerical configuration>). Ein Nachschlagen (C<postmap -q>) und die
Zustellung lesen die gebaute F<.db>, nicht die Textdatei. C<postqueue -f>
stellt jede zurückgestellte Nachricht zu, deren C<deliver_when> (Erwartungen
am Zustand des Geräts wie in Regeln) hält; die übrigen (und jede ohne
C<deliver_when>) bleiben.

=cut

sub _lx { 'Langertha::Holmgang::Sim::Linux' }
sub _text { _lx()->can('_file_text')->(@_) }

my $MAIN = '/etc/postfix/main.cf';

our %DEFAULT = (
    myhostname => 'mail.example.com', mydomain => 'example.com', myorigin => '$myhostname', mydestination => '$myhostname, localhost.$mydomain, localhost',
    relayhost => '', mynetworks => '127.0.0.0/8 [::ffff:127.0.0.0]/104 [::1]/128', mynetworks_style => 'host', inet_interfaces => 'all',
    inet_protocols => 'all', message_size_limit => '10240000', mailbox_size_limit => '51200000', smtpd_relay_restrictions =>
    'permit_mynetworks, permit_sasl_authenticated, defer_unauth_destination', smtpd_recipient_restrictions => '',
    smtp_sasl_auth_enable => 'no', smtp_sasl_password_maps => '', smtp_sasl_security_options => 'noplaintext, noanonymous',
    smtp_tls_security_level => '', smtpd_tls_security_level => '', transport_maps => '', relay_domains => '', virtual_alias_maps => '',
    virtual_alias_domains => '$virtual_alias_maps', alias_maps => 'hash:/etc/aliases', alias_database => 'hash:/etc/aliases',
    sender_canonical_maps => '', recipient_delimiter => '', compatibility_level => '0', maximal_queue_lifetime => '5d',
    bounce_queue_lifetime => '5d', smtpd_banner => '$myhostname ESMTP $mail_name', smtp_tls_CAfile => '', smtpd_sasl_auth_enable => 'no',
    header_size_limit => '102400', default_destination_concurrency_limit => '20', smtp_tls_wrappermode => 'no',
);
my %NUMERIC = map { $_ => 1 } qw( message_size_limit mailbox_size_limit header_size_limit default_destination_concurrency_limit );

=func parse_main

  my $p = parse_main($text);   # { name => wert } — nur gesetzte Parameter, Leerraum vereinfacht

=cut

sub parse_main {
    my ($text) = @_;
    my ( %p, $cur );
    for my $l ( split /\n/, $text // '' ) {
        next if $l =~ /\A\s*(?:#|\z)/;
        if ( $l =~ /\A\s/ && defined $cur ) { $p{$cur} .= ' ' . ( $l =~ s/\A\s+|\s+\z//gr ); next }
        if ( $l =~ /\A([A-Za-z0-9_]+)\s*=\s*(.*?)\s*\z/ ) { ( $cur, $p{$1} ) = ( $1, $2 ) }
    }
    s/\s+/ /g for values %p;
    return \%p;
}

sub _check {
    my ($p) = @_;
    for my $k ( sort grep { $NUMERIC{$_} } keys %$p ) {
        return "/usr/sbin/postconf: fatal: bad numerical configuration: $k = $p->{$k}" unless $p->{$k} =~ /\A\d+\z/;
    }
    return undef;
}

=func prepare

Beim Laden des Falls: C<postfix.running> aus main.cf, wenn es fehlt.

=cut

sub prepare {
    my ( $dev, $ctx ) = @_;
    my $pf = $dev->{postfix} or return;
    $pf->{running} //= parse_main( _text( $dev, $MAIN ) );
    return;
}

sub _reload {
    my ($dev) = @_;
    my $p = parse_main( _text( $dev, $MAIN ) );
    if ( my $e = _check($p) ) { return ( $e, 0 ) }
    $dev->{postfix}{running} = $p;
    return ( '', 1 );
}

=func service_event

Vom Linux-Simulator bei C<systemctl start|restart|reload> des Dienstes
C<postfix>: main.cf laden; ein Fehler lässt den Befehl scheitern (C<die>).

=cut

sub service_event {
    my ( $dev, $verb ) = @_;
    return if $verb eq 'stop';
    my ( $e, $ok ) = _reload($dev);
    die "Job for postfix.service failed because the control process exited with error code.\n$e\n" unless $ok;
    return;
}

sub _running { my $s = ( $_[0]{services} || {} )->{postfix}; return $s && $s->{active} ? 1 : 0 }

=func postconf

C<postconf> (s. oben).

=cut

sub postconf {
    my ( $dev, $av ) = @_;
    my @a = @$av;
    my %f;
    my @n;
    while (@a) {
        my $x = shift @a;
        if    ( $x =~ /\A-([ndhexX]+)\z/ ) { $f{$_} = 1 for split //, $1 }
        elsif ( $x =~ /\A-[cM F P]/ ) { return ( '', 0 ) }
        else  { push @n, $x }
    }
    my $text = _text( $dev, $MAIN ) // '';
    if ( $f{e} ) {
        my @lines = split /\n/, $text, -1;
        pop @lines if @lines && $lines[-1] eq '';
        for my $kv (@n) {
            my ( $k, $v ) = $kv =~ /\A\s*([A-Za-z0-9_]+)\s*=\s*(.*?)\s*\z/ or return ( "postconf: fatal: invalid parameter assignment: $kv", 0 );
            my $done;
            for ( my $i = 0; $i < @lines; $i++ ) {
                next unless $lines[$i] =~ /\A\Q$k\E\s*=/;
                my $j = $i + 1;
                $j++ while $j < @lines && $lines[$j] =~ /\A\s+\S/;
                splice @lines, $i, $j - $i, "$k = $v";
                $done = 1;
                last;
            }
            push @lines, "$k = $v" unless $done;
        }
        _lx()->can('_file_set')->( $dev, $MAIN, join( "\n", @lines ) . "\n" );
        return ( '', 1 );
    }
    if ( $f{X} ) {
        my @lines = split /\n/, $text;
        my @out;
        for ( my $i = 0; $i < @lines; $i++ ) {
            if ( grep { $lines[$i] =~ /\A\Q$_\E\s*=/ } @n ) { $i++ while $i + 1 < @lines && $lines[ $i + 1 ] =~ /\A\s+\S/; next }
            push @out, $lines[$i];
        }
        _lx()->can('_file_set')->( $dev, $MAIN, join( "\n", @out ) . "\n" );
        return ( '', 1 );
    }
    my $p = parse_main($text);
    my %all = $f{d} ? %DEFAULT : $f{n} ? %$p : ( %DEFAULT, %$p );
    my @show = @n ? @n : sort keys %all;
    my ( @l, $ok );
    $ok = 1;
    for my $k (@show) {
        if ( !exists $all{$k} && !exists $DEFAULT{$k} ) { push @l, "postconf: warning: $k: unknown parameter"; $ok = 0; next }
        my $v = exists $all{$k} ? $all{$k} : $DEFAULT{$k};
        next if $f{n} && !exists $p->{$k};
        push @l, $f{h} ? $v : "$k = $v";
    }
    return ( join( "\n", @l ), $ok );
}

sub _flush {
    my ( $dev, $only ) = @_;
    my $pf = $dev->{postfix};
    my @keep;
    for my $m ( @{ $pf->{queue} || [] } ) {
        my $go = ( $m->{queue} // q{deferred} ) ne q{hold} && ( !defined $only || $m->{id} eq $only ) && $m->{deliver_when};
        if ($go) {
            for my $c ( @{ $m->{deliver_when} || [] } ) {
                my ($ok) = _lx()->can('_condition')->( $dev, $c );
                $go = 0, last unless $ok;
            }
        }
        if ($go) { push @{ $pf->{delivered} }, $m->{id} }
        else     { push @keep, $m }
    }
    $pf->{queue} = \@keep;
    return;
}

=func postfix

C<postfix check|reload|status|flush|start|stop>.

=cut

sub postfix {
    my ( $dev, $av ) = @_;
    my $verb = $av->[0] // '';
    if ( $verb eq 'check' ) {
        my $e = _check( parse_main( _text( $dev, $MAIN ) ) );
        return defined $e ? ( $e, 0 ) : ( '', 1 );
    }
    if ( $verb eq 'reload' ) {
        return ( 'postfix/postfix-script: fatal: the Postfix mail system is not running', 0 ) unless _running($dev);
        my ( $e, $ok ) = _reload($dev);
        return ( $e, 0 ) unless $ok;
        return ( 'postfix/postfix-script: refreshing the Postfix mail system', 1 );
    }
    if ( $verb eq 'status' ) {
        return _running($dev) ? ( 'postfix/postfix-script: the Postfix mail system is running: PID: 1342', 1 )
            : ( 'postfix/postfix-script: the Postfix mail system is not running', 1 );
    }
    if ( $verb eq 'flush' ) { _flush($dev) if _running($dev); return ( '', 1 ) }
    if ( $verb eq 'start' || $verb eq 'stop' || $verb eq 'restart' ) {
        return _lx()->can('_systemctl')->( $dev, [ $verb, 'postfix' ], {} );
    }
    return ( "postfix: fatal: unknown command: '$verb'. Usage: postfix start (or stop, reload, abort, flush, check, status, set-permissions, upgrade-configuration)", 0 );
}

sub _build_db {
    my ( $dev, $src, $prog ) = @_;
    my $e = _lx()->can('_file_entry')->( $dev, $src );
    return ( "$prog: fatal: open $src: No such file or directory", 0 ) unless $e;
    my $text = _text( $dev, $src ) // '';
    my @w;
    my $n = 0;
    for my $l ( split /\n/, $text ) {
        $n++;
        next if $l =~ /\A\s*(?:#|\z)/;
        next if $l =~ /\A\s/;
        my $ok = $prog eq 'postalias' ? $l =~ /\A\S+?:\s*\S/ : $l =~ /\A\S+\s+\S/;
        push @w, $prog eq 'postalias'
            ? "postalias: warning: $src, line $n: need name:value pair"
            : "postmap: warning: $src, line $n: expected format: key whitespace value" unless $ok;
    }
    my %db = ( content => $text, owner => $e->{owner} // 'root', group => $e->{group} // 'root', mode => $e->{mode} // '0644' );
    $dev->{files}{"$src.db"} = \%db;
    return ( join( "\n", @w ), 1 );
}

sub _map_arg {
    my ($a) = @_;
    my ( $type, $f ) = $a =~ /\A(?:(\w+):)?(.+)\z/;
    return ( $type // 'hash', $f );
}

=func postmap

C<postmap>, C<postalias>, C<newaliases> (der vierte Wert nennt das Programm).

=cut

sub postmap {
    my ( $dev, $av, $ctx, $prog ) = @_;
    $prog //= 'postmap';
    my @a = @$av;
    my ( $q, @files );
    while (@a) {
        my $x = shift @a;
        if    ( $x eq '-q' ) { $q = shift @a }
        elsif ( $x =~ /\A-/ ) { }
        else  { push @files, $x }
    }
    if ( $prog eq 'newaliases' ) { @files = ('/etc/aliases'); $prog = 'postalias' }
    return ( "$prog: fatal: usage: $prog [-Nfinoprsuvw] [-c config_dir] [-d key] [-q key] [map_type:]file...", 0 ) unless @files;
    if ( defined $q ) {
        my ( $type, $f ) = _map_arg( $files[0] );
        my $db = _lx()->can('_file_entry')->( $dev, "$f.db" );
        return ( "$prog: fatal: open database $f.db: No such file or directory", 0 ) unless $db;
        # eine mit postalias gebaute Tabelle (Aliase) hat Schlüssel ohne Doppelpunkt — gleich, wer nachschlägt
        my $alias = $prog eq 'postalias' || $f =~ m{(?:\A|/)aliases\z};
        for my $l ( split /\n/, $db->{content} // '' ) {
            next if $l =~ /\A\s*(?:#|\z)/;
            my ( $k, $v ) = $alias ? $l =~ /\A(\S+?):\s*(.*?)\s*\z/ : $l =~ /\A(\S+)\s+(.*?)\s*\z/;
            return ( $v, 1 ) if defined $k && lc $k eq lc $q;
        }
        return ( '', 0 );
    }
    my @out;
    for my $fa (@files) {
        my ( $type, $f ) = _map_arg($fa);
        my ( $o, $ok ) = _build_db( $dev, $f, $prog );
        push @out, $o if length $o;
        return ( join( "\n", @out ), 0 ) unless $ok;
    }
    return ( join( "\n", @out ), 1 );
}

sub _queue_text {
    my ($dev) = @_;
    my @q = @{ $dev->{postfix}{queue} || [] };
    return 'Mail queue is empty' unless @q;
    my @l = ('-Queue ID-  --Size-- ----Arrival Time---- -Sender/Recipient-------');
    my $sum = 0;
    for my $m (@q) {
        my $mark = ( $m->{queue} // '' ) eq 'hold' ? '!' : ( $m->{queue} // '' ) eq 'active' ? '*' : '';
        push @l, sprintf( '%-11s %8d %s  %s', $m->{id} . $mark, $m->{size} // 1024, $m->{time} // 'Tue Oct 20 08:00:00', length( $m->{from} // '' ) ? $m->{from} : 'MAILER-DAEMON' );
        push @l, "                                         ($m->{reason})" if defined $m->{reason} && ( $m->{queue} // 'deferred' ) eq 'deferred';
        push @l, map {"                                         $_"} @{ $m->{to} || [] };
        push @l, '';
        $sum += $m->{size} // 1024;
    }
    push @l, sprintf( '-- %d Kbytes in %d Request%s.', int( $sum / 1024 + 0.999 ), scalar @q, @q == 1 ? '' : 's' );
    return join "\n", @l;
}

=func postqueue

C<postqueue -p|-f|-i id>, C<mailq>.

=cut

sub postqueue {
    my ( $dev, $av ) = @_;
    my @a = @$av;
    return ( "postqueue: fatal: Queue report unavailable - mail system is down", 0 ) unless _running($dev);
    my $o = shift(@a) // '';
    return ( _queue_text($dev), 1 ) if $o eq '-p' || $o eq '';
    if ( $o eq '-f' ) { _flush($dev); return ( '', 1 ) }
    if ( $o eq '-i' ) { _flush( $dev, shift @a ); return ( '', 1 ) }
    if ( $o eq '-j' ) { return ( '', 1 ) }
    return ( 'postqueue: fatal: usage: postqueue -f | postqueue -i queueid | postqueue -j | postqueue -p | postqueue -s site', 0 );
}

=func postsuper

C<postsuper -d|-h|-H|-r id|ALL|- [queue]>.

=cut

sub postsuper {
    my ( $dev, $av, $ctx, $stdin ) = @_;
    my @a = @$av;
    my $pf = $dev->{postfix};
    my ( %act, $n );
    while (@a) {
        my $x = shift @a;
        if ( $x =~ /\A-([dhHr])\z/ ) {
            my $id = shift @a // return ( "postsuper: fatal: usage: postsuper [-c config_dir] [-d queue_id (delete)] [-h queue_id (hold)] [-H queue_id (un-hold)] [-p (purge temporary files)] [-r queue_id (requeue)] [-s (structure fix)] [-S (structure fix)] [-v (verbose)] [queue...]", 0 );
            push @{ $act{$1} }, $id eq '-' ? ( split ' ', $stdin // '' ) : $id;
        }
        elsif ( $x =~ /\A(?:deferred|hold|active|incoming|maildrop)\z/ ) { $act{queue} = $x }
    }
    my @l;
    for my $op (qw( d h H r )) {
        my @ids = @{ $act{$op} || [] } or next;
        my $all = grep { $_ eq 'ALL' } @ids;
        my %want = map { $_ => 1 } @ids;
        my $c = 0;
        my @keep;
        for my $m ( @{ $pf->{queue} || [] } ) {
            my $hit = ( $all || $want{ $m->{id} } ) && ( !$act{queue} || ( $m->{queue} // 'deferred' ) eq $act{queue} );
            if ( !$hit ) { push @keep, $m; next }
            $c++;
            if    ( $op eq 'd' ) { push @{ $pf->{deleted} }, $m->{id}; next }
            elsif ( $op eq 'h' ) { $m->{queue} = 'hold' }
            elsif ( $op eq 'H' ) { $m->{queue} = 'deferred' if ( $m->{queue} // '' ) eq 'hold' }
            push @keep, $m;
        }
        $pf->{queue} = \@keep;
        my %verb = ( d => 'Deleted', h => 'Placed on hold', H => 'Released from hold', r => 'Requeued' );
        push @l, "postsuper: $verb{$op}: $c message" . ( $c == 1 ? '' : 's' ) if $c;
    }
    return ( join( "\n", @l ), 1 );
}

=func postcat

C<postcat -q id>.

=cut

sub postcat {
    my ( $dev, $av ) = @_;
    my ($id) = grep { !/\A-/ } @$av;
    my ($m) = grep { $_->{id} eq ( $id // '' ) } @{ $dev->{postfix}{queue} || [] };
    return ( "postcat: fatal: open queue file $id: No such file or directory", 0 ) unless $m;
    return ( join( "\n", '*** ENVELOPE RECORDS deferred/' . $m->{id} . ' ***', "message_size: $m->{size}", "sender: $m->{from}",
        ( map {"recipient: $_"} @{ $m->{to} || [] } ), '*** MESSAGE CONTENTS deferred/' . $m->{id} . ' ***', ( $m->{headers} // '' ) =~ s/\n\z//r,
        '*** HEADER EXTRACTED deferred/' . $m->{id} . ' ***', '*** MESSAGE FILE END deferred/' . $m->{id} . ' ***' ), 1 );
}

1;
