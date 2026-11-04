package Langertha::Holmgang::Sim::Linux::Calendar;
# ABSTRACT: systemd calendar expressions (OnCalendar) for the Linux simulator — check, normalise, next elapse

use strict;
use warnings;
use utf8;

use Time::Local ();

our $VERSION = '0.001';

=head1 SYNOPSIS

  use Langertha::Holmgang::Sim::Linux::Calendar ();
  my $c = Langertha::Holmgang::Sim::Linux::Calendar::parse('Mon-Fri 06:00');
  # { normalized => 'Mon..Fri *-*-* 06:00:00', tz => undef, … } oder undef
  my $t = Langertha::Holmgang::Sim::Linux::Calendar::next_elapse( $c, $jetzt );   # Epoche
  my $s = Langertha::Holmgang::Sim::Linux::Calendar::format_local($t);           # "Wed 2026-10-21 06:00:00 CEST"

=head1 DESCRIPTION

Bildet die Kalenderausdrücke von systemd (C<systemd.time(7)>) für
C<OnCalendar=> und C<systemd-analyze calendar> nach, abgeglichen mit dem echten
C<systemd-analyze calendar> (systemd 257; die Tabelle steht in
F<t/sim/linux_timer.t>):

=over

=item * Kurzformen C<minutely>, C<hourly>, C<daily>, C<weekly>, C<monthly>,
C<quarterly>, C<semiannually>, C<yearly>/C<annually> (Groß/klein egal, auch mit
Zeitzone dahinter).

=item * Wochentage am Anfang: C<Mon> oder C<Monday> (Groß/klein egal), Listen mit
C<,>, Bereiche mit C<..> oder C<->; ein umgekehrter Bereich (C<Fri..Mon>) ist
ungültig. Normalform wie systemd: Läufe ab drei Tagen als C<a..b>, zwei Tage als
C<a,b>, alle sieben Tage entfallen.

=item * Datum C<J-M-T> bzw. C<M-T>, letzter Tag mit C<~> (C<*-02~01>); zweistellige
Jahre sind 20xx. Uhrzeit C<H:M[:S]>, Sekunden auch mit Nachkommastellen. Jedes
Feld: C<*>, Zahl, Liste, Bereich C<a..b>, Schritt C<a/n> bzw. C<a..b/n>
(C</1> nach einem Bereich entfällt in der Normalform).

=item * Zeitzone am Ende: C<UTC> (Groß/klein egal), C<GMT>, C<Etc/UTC>,
C<Etc/GMT>, die Abkürzungen der Ortszeit (C<CET>, C<CEST>) und die Namen in
C<%ZONE> (Europa, USA, einige in Asien).
Unbekannte Namen sind ungültig.

=back

Ungültig ist alles andere, z. B. C<daily 02:00>, C<02:00 daily>, C<Mo..Fr>,
C<Mon..Fri 06:00,Sat 08:00>, C<24:00>, C<30 2 * * *>, C<now>.

Die Ortszeit der simulierten Server ist Europe/Berlin (MEZ/MESZ nach der
EU-Regel). Zeitzonen mit Sommerzeit rechnen nach der EU- bzw. US-Regel.

=cut

my @WD = qw( Mon Tue Wed Thu Fri Sat Sun );
my %WD;
for my $i ( 0 .. 6 ) {
    $WD{ lc $WD[$i] } = $i;
    $WD{ (qw( monday tuesday wednesday thursday friday saturday sunday ))[$i] } = $i;
}

my %SHORT = (
    minutely     => '*-*-* *:*:00',
    hourly       => '*-*-* *:00:00',
    daily        => '*-*-* 00:00:00',
    weekly       => 'Mon *-*-* 00:00:00',
    monthly      => '*-*-01 00:00:00',
    quarterly    => '*-01,04,07,10-01 00:00:00',
    semiannually => '*-01,07-01 00:00:00',
    yearly       => '*-01-01 00:00:00',
    annually     => '*-01-01 00:00:00',
);

# Zeitzone -> [ Normalzeit-Versatz in s, Regel (eu|us|undef), Abkuerzung normal, Sommer ]
our %ZONE = (
    # Abkuerzungen der Ortszeit nimmt systemd an (fester Versatz)
    CET => [ 3600, undef, 'CET' ], CEST => [ 7200, undef, 'CEST' ],
    UTC => [ 0, undef, 'UTC' ], GMT => [ 0, undef, 'GMT' ], 'Etc/UTC' => [ 0, undef, 'UTC' ], 'Etc/GMT' => [ 0, undef, 'GMT' ],
    ( map { ( "Europe/$_" => [ 3600, 'eu', 'CET', 'CEST' ] ) }
        qw( Berlin Vienna Zurich Paris Amsterdam Brussels Luxembourg Rome Madrid Copenhagen Oslo Stockholm Warsaw Prague Budapest ) ),
    ( map { ( "Europe/$_" => [ 0, 'eu', $_ eq 'Lisbon' ? 'WET' : $_ eq 'Dublin' ? 'GMT' : 'GMT', $_ eq 'Lisbon' ? 'WEST' : $_ eq 'Dublin' ? 'IST' : 'BST' ] ) }
        qw( London Dublin Lisbon ) ),
    ( map { ( "Europe/$_" => [ 7200, 'eu', 'EET', 'EEST' ] ) } qw( Helsinki Athens Bucharest Sofia Riga Tallinn Vilnius ) ),
    'America/New_York'    => [ -18000, 'us', 'EST', 'EDT' ],
    'America/Chicago'     => [ -21600, 'us', 'CST', 'CDT' ],
    'America/Denver'      => [ -25200, 'us', 'MST', 'MDT' ],
    'America/Los_Angeles' => [ -28800, 'us', 'PST', 'PDT' ],
    'Asia/Tokyo'          => [ 32400,  undef, 'JST' ],
    'Asia/Singapore'      => [ 28800,  undef, '+08' ],
    'Asia/Kolkata'        => [ 19800,  undef, 'IST' ],
);

our $LOCAL = 'Europe/Berlin';

# Ein Feld -> ( [ Werte ] oder undef fuer *, Text der Normalform ); () = ungueltig
sub _field {
    my ( $s, $min, $max, $width, $frac ) = @_;
    return ( undef, '*' ) if $s eq '*';
    if ( $frac && $s =~ /\A(\d+)\.(\d{1,6})\z/ ) {
        return () if $1 > $max;
        return ( [ 0 + $1 ], sprintf( "%0${width}d.%06d", $1, substr( $2 . '000000', 0, 6 ) ) );
    }
    my ( @v, @txt );
    for my $part ( split /,/, $s, -1 ) {
        my ( $a, $b, $step ) = $part =~ /\A(\*|\d+)(?:\.\.(\d+))?(?:\/(\d+))?\z/ or return ();
        return () if $a eq '*' && ( defined $b || !defined $step );
        my $lo = $a eq '*' ? $min : $a;
        my $hi = defined $b ? $b : defined $step ? $max : $lo;
        return () if $lo < $min || $hi > $max || $lo > $hi || ( defined $step && $step == 0 );
        undef $step if defined $b && defined $step && $step == 1;
        for ( my $i = $lo; $i <= $hi; $i += $step // 1 ) { push @v, 0 + $i }
        my $f = sub { $_[0] eq '*' ? '*' : sprintf( "%0${width}d", $_[0] ) };
        push @txt, $f->($a) . ( defined $b ? '..' . $f->($b) : '' ) . ( defined $step ? '/' . $step : '' );
    }
    my %u = map { $_ => 1 } @v;
    return ( [ sort { $a <=> $b } keys %u ], join( ',', @txt ) );
}

# Wochentage "Mon-Wed,Fri" -> ( [ 0..6 ] oder undef fuer alle, Normalform )
sub _weekdays {
    my ($s) = @_;
    my %on;
    for my $part ( split /,/, $s, -1 ) {
        my ( $a, $b ) = $part =~ /\A([A-Za-z]+)(?:(?:\.\.|-)([A-Za-z]+))?\z/ or return ();
        return () unless exists $WD{ lc $a } && ( !defined $b || exists $WD{ lc $b } );
        my ( $x, $y ) = ( $WD{ lc $a }, defined $b ? $WD{ lc $b } : $WD{ lc $a } );
        return () if $y < $x;
        $on{$_} = 1 for $x .. $y;
    }
    my @d = sort { $a <=> $b } keys %on;
    return ( undef, undef ) if @d == 7;
    my @txt;
    my $i = 0;
    while ( $i < @d ) {
        my $j = $i;
        $j++ while $j + 1 < @d && $d[ $j + 1 ] == $d[$j] + 1;
        if    ( $j - $i >= 2 ) { push @txt, "$WD[$d[$i]]..$WD[$d[$j]]" }
        elsif ( $j == $i )     { push @txt, $WD[ $d[$i] ] }
        else                   { push @txt, $WD[ $d[$i] ], $WD[ $d[$j] ] }
        $i = $j + 1;
    }
    return ( \@d, join( ',', @txt ) );
}

=func parse

  my $c = parse($ausdruck);

Prüft einen Kalenderausdruck. Rückgabe C<undef> (systemd nimmt ihn nicht an)
oder ein Hash mit C<normalized> (Normalform wie C<systemd-analyze calendar>),
C<tz> (Name der Zeitzone oder C<undef> für die Ortszeit), C<utc> (1 bei einer
UTC-Zone) und den Wertemengen der Felder.

=cut

sub parse {
    my ($expr) = @_;
    return undef unless defined $expr && $expr =~ /\A\S/;
    ( my $s = $expr ) =~ s/\s+\z//;
    my @w = split /\s+/, $s;
    my $tz;
    if ( @w > 1 ) {
        my $z = lc( $w[-1] ) eq 'utc' ? 'UTC' : $w[-1];
        if ( $ZONE{$z} ) { $tz = $z; pop @w }
    }
    if ( @w == 1 && exists $SHORT{ lc $w[0] } ) { @w = split / /, $SHORT{ lc $w[0] } }
    my %c = ( tz => $tz, utc => defined $tz && !$ZONE{$tz}[0] && !$ZONE{$tz}[1] ? 1 : 0 );
    my @norm;
    if ( @w && $w[0] =~ /\A[A-Za-z]/ ) {
        my ( $d, $t ) = _weekdays( shift @w ) or return undef;
        $c{wd} = $d;
        push @norm, $t if defined $t;
    }
    my ( $date, $time );
    for my $x (@w) {
        if    ( !defined $date && !defined $time && $x !~ /:/ && $x =~ /[-~]/ ) { $date = $x }
        elsif ( !defined $time && $x =~ /:/ ) { $time = $x }
        else { return undef }
    }
    return undef if !defined $date && !defined $time && !exists $c{wd};
    $date //= '*-*-*';
    $time //= '00:00:00';
    my ( $ym, $sep, $day ) = $date =~ /\A(.*)([-~])([^-~]*)\z/ or return undef;
    $c{last} = $sep eq '~' ? 1 : 0;
    my @ymv = split /-/, $ym, -1;
    unshift @ymv, '*' if @ymv == 1;
    return undef unless @ymv == 2;
    $ymv[0] = $ymv[0] + ( $ymv[0] < 70 ? 2000 : 1900 ) if $ymv[0] =~ /\A\d{2}\z/;
    my @t = split /:/, $time, -1;
    push @t, '00' if @t == 2;
    return undef unless @t == 3;
    my @f = ( @ymv, $day, @t );
    my @lim = ( [ 1970, 2199, 4 ], [ 1, 12, 2 ], [ 1, 31, 2 ], [ 0, 23, 2 ], [ 0, 59, 2 ], [ 0, 59, 2, 1 ] );
    my @txt;
    for my $i ( 0 .. 5 ) {
        my ( $v, $tx ) = _field( $f[$i], @{ $lim[$i] } ) or return undef;
        $c{ (qw( year mon day hour min sec ))[$i] } = $v;
        push @txt, $tx;
    }
    # ~T/n zaehlt vom Monatsende aus weiter zum Ende hin: ~07/1 = die letzten sieben Tage
    if ( $c{last} && $f[2] =~ /\A(\d+)\/(\d+)\z/ ) {
        my @d;
        for ( my $i = $1; $i >= 1; $i -= $2 ) { push @d, 0 + $i }
        $c{day} = [ sort { $a <=> $b } @d ];
    }
    push @norm, "$txt[0]-$txt[1]" . ( $c{last} ? '~' : '-' ) . $txt[2], join( ':', @txt[ 3 .. 5 ] );
    push @norm, $tz if defined $tz;
    $c{normalized} = join ' ', @norm;
    return \%c;
}

sub _last_sunday {
    my ( $y, $m ) = @_;    # $m 0-basiert; Mitternacht UTC des letzten Sonntags
    my $t = Time::Local::timegm( 0, 0, 0, _dim( $y, $m ), $m, $y );
    return $t - ( gmtime $t )[6] * 86400;
}

sub _nth_sunday {
    my ( $y, $m, $n ) = @_;
    my $t = Time::Local::timegm( 0, 0, 0, 1, $m, $y );
    my $wd = ( gmtime $t )[6];
    return $t + ( ( 7 - $wd ) % 7 ) * 86400 + ( $n - 1 ) * 7 * 86400;
}

sub _dim {
    my ( $y, $m ) = @_;
    return ( 31, ( $y % 4 == 0 && ( $y % 100 != 0 || $y % 400 == 0 ) ) ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 )[$m];
}

=func offset

  my $sek = offset( $epoche [, $zone] );   # Europe/Berlin: 7200 (MESZ) oder 3600 (MEZ)

Versatz einer Zeitzone (Vorgabe Europe/Berlin) zur UTC-Epoche.

=cut

sub offset {
    my ( $t, $tz ) = @_;
    my ( $std, $rule ) = @{ $ZONE{ $tz // $LOCAL } || $ZONE{$LOCAL} };
    return $std unless $rule;
    my $y = ( gmtime $t )[5] + 1900;
    if ( $rule eq 'eu' ) {
        return $t >= _last_sunday( $y, 2 ) + 3600 && $t < _last_sunday( $y, 9 ) + 3600 ? $std + 3600 : $std;
    }
    my $from = _nth_sunday( $y, 2, 2 ) + 7200 - $std;
    my $to   = _nth_sunday( $y, 10, 1 ) + 7200 - ( $std + 3600 );
    return $t >= $from && $t < $to ? $std + 3600 : $std;
}

=func next_elapse

  my $t = next_elapse( $c, $nach );

Der erste Zeitpunkt (Epoche) nach C<$nach>, auf den der Ausdruck passt;
C<undef>, wenn es in den nächsten fünf Jahren keinen gibt.

=cut

sub next_elapse {
    my ( $c, $after ) = @_;
    my $tz = $c->{tz};
    my ( undef, undef, undef, $d0, $m0, $y0 ) = gmtime( $after + offset( $after, $tz ) );
    my $day = Time::Local::timegm( 0, 0, 0, $d0, $m0, $y0 );
    my %in = map { my $k = $_; ( $k => $c->{$k} ? { map { $_ => 1 } @{ $c->{$k} } } : undef ) } qw( year mon day );
    my $wd = $c->{wd} ? { map { $_ => 1 } @{ $c->{wd} } } : undef;
    my @hours = $c->{hour} ? @{ $c->{hour} } : 0 .. 23;
    my @mins  = $c->{min}  ? @{ $c->{min} }  : 0 .. 59;
    my @secs  = $c->{sec}  ? @{ $c->{sec} }  : 0 .. 59;
    for my $n ( 0 .. 366 * 5 ) {
        my $d = $day + $n * 86400;
        my ( undef, undef, undef, $dd, $mm, $yy, $w ) = gmtime $d;
        next if $in{year} && !$in{year}{ $yy + 1900 };
        next if $in{mon}  && !$in{mon}{ $mm + 1 };
        next if $in{day}  && !$in{day}{ $c->{last} ? _dim( $yy + 1900, $mm ) - $dd + 1 : $dd };
        next if $wd && !$wd->{ ( $w + 6 ) % 7 };
        for my $h (@hours) {
            for my $mi (@mins) {
                for my $s (@secs) {
                    my $lt = $d + $h * 3600 + $mi * 60 + $s;
                    my $t = $lt - offset( $lt - offset( $lt, $tz ), $tz );
                    return $t if $t > $after;
                }
            }
        }
    }
    return undef;
}

=func format_local

  format_local( $t );                # "Wed 2026-10-21 06:00:00 CEST" (Ortszeit)
  format_local( $t, 1 );             # "Wed 2026-10-21 04:00:00 UTC"
  format_local( $t, 'Asia/Tokyo' );  # in einer anderen Zone

=cut

sub format_local {
    my ( $t, $zone ) = @_;
    $zone = !defined $zone || $zone eq '0' || $zone eq '' ? $LOCAL : $zone eq '1' ? 'UTC' : $zone;
    my $z = $ZONE{$zone} || $ZONE{$LOCAL};
    my $off = offset( $t, $zone );
    my @g = gmtime( $t + $off );
    my $abbr = $off != $z->[0] && defined $z->[3] ? $z->[3] : $z->[2];
    return sprintf '%s %04d-%02d-%02d %02d:%02d:%02d %s', $WD[ ( $g[6] + 6 ) % 7 ], $g[5] + 1900, $g[4] + 1, $g[3], $g[2], $g[1], $g[0], $abbr;
}

=func left

  left( $sekunden );   # "13h", "1 day 2h", "45min" — wie systemd ("… left")

=cut

sub left {
    my ($s) = @_;
    return '0s' if $s <= 0;
    my @p;
    my $d = int( $s / 86400 ); $s -= $d * 86400;
    my $h = int( $s / 3600 );  $s -= $h * 3600;
    my $m = int( $s / 60 );
    push @p, $d == 1 ? '1 day' : "$d days" if $d;
    push @p, "${h}h" if $h;
    push @p, "${m}min" if $m && !$d;
    return @p ? join( ' ', @p ) : int($s) . 's';
}

1;
