package Langertha::Holmgang::Sim::Linux::Accounts;
# ABSTRACT: Accounts and sudo on a simulated Linux server — passwd, chage, deluser, userdel, visudo, sudo -l

use strict;
use warnings;
use utf8;

use JSON::MaybeXS ();
use Time::Local ();

our $VERSION = '0.001';

=head1 SYNOPSIS

  # aus dem Linux-Simulator
  my ( $out, $ok ) = Langertha::Holmgang::Sim::Linux::Accounts::passwd( $dev, [ '-l', 'mmeier' ] );
  Langertha::Holmgang::Sim::Linux::Accounts::set_expire( $dev, $user_entry, '1' );

=head1 DESCRIPTION

Konten eines Debian-12-Geräts vom Typ C<linux> (cai-platform F<docs/entwurf-evals.md>
§3.3.1) und die sudo-Regeln aus F</etc/sudoers> samt F</etc/sudoers.d/>.

  users:
    mmeier: { uid: 1004, groups: [ mmeier, sudo, docker ], shell: /bin/bash,
              locked: false,       # Passwort gesperrt (usermod -L, passwd -l)
              expire: 20381,       # Ablauf in Tagen seit 1970 (usermod -e, chage -E)
              expired: true }      # vom Simulator: Ablauf am Simulationstag (20.10.2026) erreicht

B<Befehle:> C<passwd -l|-u|-S|-d benutzer>, C<chage -E datum|-1|0 benutzer>,
C<chage -l benutzer>, C<deluser benutzer gruppe> (aus der Gruppe),
C<deluser [--remove-home] benutzer>, C<userdel [-r] benutzer> (Konto weg,
mit C<-r> auch F</home/benutzer>), C<getent shadow>, C<visudo -c [-f datei]>
(Syntax, Rechte 0440 und Eigentümer root jeder Quelle; Dateien in
F</etc/sudoers.d> mit Punkt oder C<~> im Namen liest sudo nicht),
C<sudo -l [-U benutzer]> (die Regeln, die für den Benutzer gelten). Ein
gesperrtes Passwort hindert eine Anmeldung mit Schlüssel nicht; ein
abgelaufenes Konto oder eine Shell C<nologin>/C<false> schon
(L<Langertha::Holmgang::Sim::Linux::Sshd/login_denied>).

=cut

sub _today { return int( Time::Local::timegm( 0, 0, 12, 20, 9, 2026 ) / 86400 ) }

sub _days {
    my ($v) = @_;
    return undef if !defined $v || $v eq '' || $v eq '-1';
    return 0 + $v if $v =~ /\A\d+\z/;
    my ( $y, $m, $d ) = $v =~ /\A(\d{4})-(\d{2})-(\d{2})\z/ or return 'bad';
    return int( Time::Local::timegm( 0, 0, 12, $d, $m - 1, $y ) / 86400 );
}

sub _date {
    my ($days) = @_;
    my @t = gmtime( $days * 86400 );
    return sprintf '%s %02d, %04d', (qw( Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec ))[ $t[4] ], $t[3], $t[5] + 1900;    # wie chage -l
}

=func set_expire

  my $err = set_expire( $dev, $user_entry, $wert );   # Datum JJJJ-MM-TT, Tage, '' oder -1 = kein Ablauf

=cut

sub set_expire {
    my ( $dev, $e, $v ) = @_;
    my $d = _days($v);
    return "invalid date '$v'" if defined $d && $d eq 'bad';
    if ( defined $d ) {
        $e->{expire} = $d unless defined $e->{expire} && $e->{expire} == $d;
        if   ( $d <= _today() ) { $e->{expired} = JSON::MaybeXS::true() unless $e->{expired} }
        else                    { delete $e->{expired} }
    }
    else {
        delete $e->{expire};
        delete $e->{expired};
    }
    return undef;
}

sub _user { my ( $dev, $u ) = @_; return ( $dev->{users} || {} )->{ $u // '' } }

=func passwd

  my ( $out, $ok ) = passwd( $dev, \@argv );

C<passwd -l|-u|-S|-d|-e benutzer>; ein interaktives Setzen gibt es nicht.

=cut

sub passwd {
    my ( $dev, $av ) = @_;
    my @a = @$av;
    my %o;
    while ( @a && $a[0] =~ /\A-/ ) { my $x = shift @a; $o{$_} = 1 for split //, substr( $x, 1 ) }
    my $u = shift @a;
    return ( 'passwd: You may not view or modify password information for root.', 0 ) if !defined $u && !%o;
    my $e = _user( $dev, $u ) or return ( "passwd: user '" . ( $u // '' ) . "' does not exist", 0 );
    if ( $o{S} ) { return ( sprintf( '%s %s 10/20/2026 0 99999 7 -1', $u, $e->{locked} ? 'L' : 'P' ), 1 ) }
    if ( $o{l} ) { $e->{locked} = JSON::MaybeXS::true() unless $e->{locked}; return ( 'passwd: password changed.', 1 ) }
    if ( $o{u} ) { $e->{locked} = JSON::MaybeXS::false() if $e->{locked}; return ( 'passwd: password changed.', 1 ) }
    if ( $o{e} ) { return ( 'passwd: password changed.', 1 ) }
    if ( $o{d} ) { $e->{locked} = JSON::MaybeXS::false() if $e->{locked}; $e->{no_password} = JSON::MaybeXS::true(); return ( 'passwd: password changed.', 1 ) }
    return ( 'passwd: Authentication token manipulation error', 0 );
}

=func chage

  my ( $out, $ok ) = chage( $dev, \@argv );

C<chage -E datum|tage|-1 benutzer> setzt den Ablauf, C<chage -l benutzer> zeigt ihn.

=cut

sub chage {
    my ( $dev, $av ) = @_;
    my @a = @$av;
    my ( $exp, $list );
    while ( @a > 1 ) {
        my $x = shift @a;
        if    ( $x eq '-E' || $x eq '--expiredate' ) { $exp = shift @a }
        elsif ( $x =~ /\A--expiredate=(.*)\z/ )      { $exp = $1 }
        elsif ( $x eq '-l' || $x eq '--list' )       { $list = 1 }
        elsif ( $x =~ /\A-[mMWId]\z/ )               { shift @a }
        else { return ( "chage: invalid option -- '" . substr( $x, 1 ) . "'", 0 ) }
    }
    my $u = shift @a;
    $list = 1 if !defined $exp && !$list;
    my $e = _user( $dev, $u ) or return ( "chage: user '" . ( $u // '' ) . "' does not exist in /etc/passwd", 0 );
    if ($list) {
        return ( join( "\n", 'Last password change					: Sep 01, 2026', 'Password expires					: never',
            'Password inactive					: never',
            'Account expires						: ' . ( defined $e->{expire} ? _date( $e->{expire} ) : 'never' ),
            'Minimum number of days between password change		: 0', 'Maximum number of days between password change		: 99999',
            'Number of days of warning before password expires	: 7' ), 1 );
    }
    my $err = set_expire( $dev, $e, $exp );
    return ( "chage: $err", 0 ) if $err;
    return ( '', 1 );
}

sub _delete_user {
    my ( $dev, $u, $home ) = @_;
    delete $dev->{users}{$u};
    if ($home) { delete $dev->{files}{$_} for grep { index( $_, "/home/$u/" ) == 0 || $_ eq "/var/mail/$u" } keys %{ $dev->{files} || {} } }
    return;
}

sub _remove_group {
    my ( $e, $g ) = @_;
    my @g = @{ $e->{groups} || [] };
    my @new = grep { $_ ne $g } @g;
    return 0 if @new == @g;
    $e->{groups} = \@new;
    return 1;
}

=func remove_group

  my ( $out, $ok ) = remove_group( $dev, $benutzer, $gruppe, $stil );   # gpasswd | deluser

=cut

sub remove_group {
    my ( $dev, $u, $g, $style ) = @_;
    my $e = _user( $dev, $u ) or return ( $style eq 'gpasswd' ? "gpasswd: user '$u' does not exist" : "fatal: The user `$u' does not exist.", 0 );
    if ( !_remove_group( $e, $g ) ) {
        return ( $style eq 'gpasswd' ? "gpasswd: user '$u' is not a member of '$g'" : "fatal: The user `$u' is not a member of group `$g'.", 0 );
    }
    return ( $style eq 'gpasswd' ? "Removing user $u from group $g" : "Removing user `$u' from group `$g' ...\nDone.", 1 );
}

=func deluser

  my ( $out, $ok ) = deluser( $dev, \@argv );

C<deluser benutzer gruppe> nimmt aus der Gruppe; C<deluser [--remove-home] benutzer> löscht das Konto.

=cut

sub deluser {
    my ( $dev, $av ) = @_;
    my @opt = grep {/\A--/} @$av;
    my @a = grep { !/\A--/ } @$av;
    return ( 'deluser: Only one or two names allowed.', 0 ) unless @a == 1 || @a == 2;
    return remove_group( $dev, @a, 'deluser' ) if @a == 2;
    my $u = $a[0];
    _user( $dev, $u ) or return ( "fatal: The user `$u' does not exist.", 0 );
    _delete_user( $dev, $u, scalar grep { $_ eq '--remove-home' || $_ eq '--remove-all-files' } @opt );
    return ( "Removing user `$u' ...\nDone.", 1 );
}

=func userdel

  my ( $out, $ok ) = userdel( $dev, \@argv );

C<userdel [-r] benutzer>: Konto weg, mit C<-r> auch F</home/benutzer> und F</var/mail/benutzer>.

=cut

sub userdel {
    my ( $dev, $av ) = @_;
    my $home = grep { $_ eq '-r' || $_ eq '--remove' } @$av;
    my ($u) = grep { !/\A-/ } @$av;
    _user( $dev, $u ) or return ( "userdel: user '" . ( $u // '' ) . "' does not exist", 0 );
    _delete_user( $dev, $u, $home );
    return ( '', 1 );
}

=func shadow_line

Eine Zeile wie F</etc/shadow> (Hash erfunden, C<!> davor bei gesperrtem Passwort).

=cut

sub shadow_line {
    my ( $u, $e ) = @_;
    my $pw = $e->{no_password} ? '' : ( $e->{locked} ? '!' : '' ) . '$y$j9T$Qe2eYkB0exampleSALT$examplehashnotreal0000000000000000000000';
    return "$u:$pw:20332:0:99999:7::" . ( defined $e->{expire} ? $e->{expire} : '' ) . ':';
}

# --- sudo -----------------------------------------------------------------------------

sub _ftext {
    my ( $dev, $p ) = @_;
    my $e = ( $dev->{files} || {} )->{$p};
    return undef unless defined $e;
    return ref $e eq 'HASH' ? ( $e->{content} // '' ) : $e;
}

# Quellen in Lesereihenfolge: /etc/sudoers, darin @includedir/#includedir
sub _sources {
    my ($dev) = @_;
    my @s = ('/etc/sudoers');
    my $t = _ftext( $dev, '/etc/sudoers' ) // '';
    for my $l ( split /\n/, $t ) {
        next unless $l =~ /\A\s*[@#]includedir\s+(\S+)/;
        my $d = $1;
        push @s, sort grep { m{\A\Q$d\E/([^/]+)\z} && $1 !~ /[.~]/ } keys %{ $dev->{files} || {} };
    }
    return @s;
}

# Regeln einer Datei; Syntaxfehler -> ( undef, zeile )
sub _parse_sudoers {
    my ($t) = @_;
    my @rules;
    my $n = 0;
    my $tag = qr/(?:NOPASSWD|PASSWD|NOEXEC|EXEC|SETENV|NOSETENV|LOG_INPUT|NOLOG_INPUT|LOG_OUTPUT|NOLOG_OUTPUT)/;
    for my $l ( split /\n/, $t ) {
        $n++;
        next if $l =~ /\A\s*(?:#(?!include)|\z)/ || $l =~ /\A\s*[@#]include(?:dir)?\s+\S/;
        next if $l =~ /\A\s*Defaults\b/;
        next if $l =~ /\A\s*(?:User|Runas|Host|Cmnd)_Alias\s+[A-Z][A-Z0-9_]*\s*=\s*\S/;
        my ( $who, $host, $runas, $rest ) = $l =~ /\A\s*(%?[\w.\-]+|[A-Z][A-Z0-9_]*)\s+([\w.\-]+|ALL)\s*=\s*(\([^)]*\))?\s*(.*?)\s*\z/
            or return ( undef, $n );
        my @tags;
        push @tags, $1 while $rest =~ s/\A($tag):\s*//;
        return ( undef, $n ) unless length $rest;
        my @cmds = map { s/\A\s+|\s+\z//gr } split /,/, $rest;
        for (@cmds) { return ( undef, $n ) unless $_ eq 'ALL' || m{\A!?/\S} || /\A!?[A-Z][A-Z0-9_]*\z/ }
        push @rules, { who => $who, runas => $runas // '(root)', tags => \@tags, cmds => \@cmds };
    }
    return ( \@rules );
}

=func visudo

  my ( $out, $ok ) = visudo( $dev, \@argv );

C<visudo -c [-q] [-f datei]>: Syntax, Eigentümer root und Rechte 0440/0400 jeder Quelle.

=cut

sub visudo {
    my ( $dev, $av ) = @_;
    my @a = @$av;
    my ( $check, $file, $quiet ) = ( 0, undef, 0 );
    while (@a) {
        my $x = shift @a;
        if    ( $x eq '-c' || $x eq '--check' ) { $check = 1 }
        elsif ( $x eq '-q' || $x eq '--quiet' ) { $quiet = 1 }
        elsif ( $x eq '-f' || $x eq '--file' )  { $file = shift @a }
        elsif ( $x =~ /\A-[cqsf]+\z/ )          { $check = 1 if $x =~ /c/; $quiet = 1 if $x =~ /q/; $file = shift @a if $x =~ /f/ }
        elsif ( $x !~ /\A-/ )                   { $file = $x }
    }
    if ( !$check ) { no warnings 'once'; push @Langertha::Holmgang::Sim::Linux::GAPS, join( ' ', 'visudo', @$av ); return ( 'Error opening terminal: unknown.', 0 ) }
    my @src = defined $file ? ($file) : _sources($dev);
    my ( @out, $ok );
    $ok = 1;
    for my $f (@src) {
        my $t = _ftext( $dev, $f );
        if ( !defined $t ) { push @out, "visudo: unable to open $f: No such file or directory"; $ok = 0; next }
        my ( $r, $line ) = _parse_sudoers($t);
        if ( !$r ) { push @out, ">>> $f: syntax error near line $line <<<", "parse error in $f near line $line"; $ok = 0; next }
        my $e = ( $dev->{files} || {} )->{$f};
        my $m = ref $e eq 'HASH' ? oct( $e->{mode} // '0644' ) : 0644;
        my $own = ref $e eq 'HASH' ? ( $e->{owner} // 'root' ) : 'root';
        if ( $own ne 'root' ) { push @out, "$f: wrong owner (uid, gid) should be (0, 0)"; $ok = 0; next }
        if ( ( $m & 07777 ) != 0440 && ( $m & 07777 ) != 0400 ) { push @out, "$f: bad permissions, should be mode 0440"; $ok = 0; next }
        push @out, "$f: parsed OK" unless $quiet;
    }
    return ( join( "\n", @out ), $ok );
}

=func sudo_list

  my ( $out, $ok ) = sudo_list( $dev, $benutzer, $host );

C<sudo -l [-U benutzer]>: die Regeln aller Quellen, die für den Benutzer (oder eine seiner Gruppen) gelten.

=cut

sub sudo_list {
    my ( $dev, $u, $host ) = @_;
    $u //= 'root';
    my @groups = $u eq 'root' ? ('root') : @{ ( _user( $dev, $u ) || {} )->{groups} || [] };
    return ( "sudo: unknown user $u", 0 ) unless $u eq 'root' || _user( $dev, $u );
    my @mine;
    for my $f ( _sources($dev) ) {
        my $t = _ftext( $dev, $f ) // next;
        my ($r, $line) = _parse_sudoers($t);
        return ( "sudo: parse error in $f near line $line\nsudo: no valid sudoers sources found, quitting", 0 ) unless $r;
        for my $x (@$r) {
            my $w = $x->{who};
            next unless $w eq $u || ( $w =~ /\A%(.+)\z/ && grep { $_ eq $1 } @groups ) || $w eq 'ALL';
            push @mine, '    ' . $x->{runas} . ' ' . join( '', map {"$_: "} @{ $x->{tags} } ) . join( ', ', @{ $x->{cmds} } );
        }
    }
    return ( "User $u is not allowed to run sudo on $host.", 1 ) unless @mine;
    return ( join( "\n", "Matching Defaults entries for $u on $host:", '    env_reset, mail_badpass, secure_path=/usr/local/sbin\:/usr/local/bin\:/usr/sbin\:/usr/bin\:/sbin\:/bin, use_pty',
        '', "User $u may run the following commands on $host:", @mine ), 1 );
}

=func sudo_check

  my $why = sudo_check( $dev, $benutzer, $ziel, $pfad, $gefunden, \@args, $nicht_interaktiv, $host );

Darf ein Benutzer ohne Root-Rechte C<sudo [-u ziel] befehl> ohne Passwort? C<undef>
heißt ja (die letzte passende Regel trägt C<NOPASSWD>); sonst die Meldung von sudo
— ohne Terminal kann sudo kein Passwort lesen.

=cut

sub sudo_check {
    my ( $dev, $u, $target, $path, $found, $args, $nonint, $host ) = @_;
    my @groups = @{ ( _user( $dev, $u ) || {} )->{groups} || [] };
    my $line = join ' ', $path, @$args;
    my $last;
    for my $f ( _sources($dev) ) {
        my $t = _ftext( $dev, $f ) // next;
        my ( $r, $n ) = _parse_sudoers($t);
        return "sudo: parse error in $f near line $n\nsudo: no valid sudoers sources found, quitting" unless $r;
        for my $x (@$r) {
            my $w = $x->{who};
            next unless $w eq $u || $w eq 'ALL' || ( $w =~ /\A%(.+)\z/ && grep { $_ eq $1 } @groups );
            my ($ru) = $x->{runas} =~ /\A\(([^:)]*)/;
            $ru = 'root' if !defined $ru || $ru eq '';
            next unless grep { $_ eq 'ALL' || $_ eq $target } map { s/\A\s+|\s+\z//gr } split /,/, $ru;
            for my $c ( @{ $x->{cmds} } ) {
                next if $c =~ /\A!/;
                my $hit;
                if ( $c eq 'ALL' ) { $hit = 1 }
                elsif ( $c =~ m{\A(/\S+)(?:\s+(.*))?\z} ) {
                    my ( $cp, $ca ) = ( $1, $2 );
                    next unless $cp eq $path;
                    if ( !defined $ca ) { $hit = 1 }
                    elsif ( $ca eq '""' ) { $hit = !@$args }
                    else {
                        ( my $re = quotemeta $ca ) =~ s/\\\*/.*/g;
                        $hit = join( ' ', @$args ) =~ /\A$re\z/;
                    }
                }
                $last = $x if $hit;
            }
        }
    }
    return undef if $last && grep { $_ eq 'NOPASSWD' } @{ $last->{tags} };
    return "sudo: $path: command not found" if !$found && $last;
    return $nonint ? 'sudo: a password is required'
        : "sudo: a terminal is required to read the password; either use the -S option to read from standard input or configure an askpass helper\nsudo: a password is required";
}

1;
