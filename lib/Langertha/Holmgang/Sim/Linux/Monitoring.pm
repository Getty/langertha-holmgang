package Langertha::Holmgang::Sim::Linux::Monitoring;
# ABSTRACT: Monitoring on a simulated Linux server — checks Prometheus/Alertmanager, promtool, amtool

use strict;
use warnings;
use utf8;

use Encode ();
use JSON::MaybeXS ();
use YAML::XS ();

our $VERSION = '0.001';

=head1 SYNOPSIS

  # aus dem Linux-Simulator
  my ( $fehler, $nachgeladen ) = Langertha::Holmgang::Sim::Linux::Monitoring::service_check( $dev, $svc, 'prometheus' );
  my ( $out, $ok ) = Langertha::Holmgang::Sim::Linux::Monitoring::promtool( $dev, \@argv );
  my ( $out, $ok ) = Langertha::Holmgang::Sim::Linux::Monitoring::amtool( $dev, \@argv );
  my ( $body, $status ) = Langertha::Holmgang::Sim::Linux::Monitoring::http( $dev, 'GET', 9090, '/api/v1/rules', $run );

=head1 DESCRIPTION

Prometheus und Alertmanager auf einem Gerät vom Typ C<linux>
(cai-platform F<docs/entwurf-evals.md> §3.3.1). Die Dienste stehen unter C<services> mit
mehreren Dateien in C<config> (C<running> ist dann C<{ pfad => text }>) und
C<config_check: prometheus|alertmanager>; C<config_main> nennt die Hauptdatei.

B<Prometheus>: Die Hauptdatei muss gültiges YAML sein; C<scrape_configs> mit
C<job_name> (eindeutig) und C<static_configs.targets> (C<host:port>);
C<rule_files> (Muster) laden Regeldateien: C<groups> mit C<name> und C<rules>,
jede Regel C<alert> oder C<record>, C<expr>, sonst nur C<for>, C<labels>,
C<annotations>, C<keep_firing_for>. Ein Fehler verhindert den Start; beim
C<reload> bleibt die alte Konfiguration und das Journal zeigt
C<Error reloading config>. Geladene Regeldateien stehen mit in C<running>.

B<Alertmanager>: C<route> mit C<receiver>, jeder in C<route> (auch in
C<routes>) genannte Empfänger muss unter C<receivers> stehen.

B<promtool> C<check config|rules DATEI…>, B<amtool> C<check-config DATEI> —
Ausgabe wie die echten Werkzeuge. Was Alertmanager geladen hat, steht je
Empfänger unter C<_routes> des Dienstes (wirksame C<repeat_interval>,
C<group_wait>, C<group_interval>, C<group_by>; Unterrouten erben).
B<amtool silence add|query|expire> und C<amtool alert query> (mit
C<--alertmanager.url> oder F</etc/amtool/config.yml>; Kommentar Pflicht; Zeiten
RFC 3339, C<--duration> als Go-Dauer, Uhr des Geräts in C<tz>, Vorgabe
C<+02:00>): Stummschaltungen stehen unter C<silences> des Dienstes, je Eintrag mit
C<starts>/C<ends> (UTC), C<state> (pending|active|expired) und C<covers> — welche
der benannten Label-Sätze aus C<alert_targets> sie treffen; C<alerts> nennt die
feuernden Alarme (C<alertname>, C<target>).

logrotate bildet L<Langertha::Holmgang::Sim::Linux::Logrotate> nach.

Reine Funktionen auf dem Zustand, neutral.

=cut

our @GAPS;

sub _file_text {
    my ( $dev, $p ) = @_;
    require Langertha::Holmgang::Sim::Linux;
    return Langertha::Holmgang::Sim::Linux::_file_text( $dev, $p );
}

sub _glob_files {
    my ( $dev, $pat ) = @_;
    ( my $re = quotemeta $pat ) =~ s/\\\*/[^\/]*/g;
    $re =~ s/\\\?/[^\/]/g;
    return sort grep { /\A$re\z/ && defined _file_text( $dev, $_ ) } keys %{ $dev->{files} || {} };
}

# YAML laden: ( daten ) oder ( undef, "yaml: line N: …" )
sub _yaml {
    my ($text) = @_;
    my $d = eval { YAML::XS::Load( utf8::is_utf8($text) ? Encode::encode( q{UTF-8}, $text ) : $text ) };
    return ($d) unless $@;
    my $e = "$@";
    my ($line) = $e =~ /line:\s*(\d+)/;
    my ($what) = $e =~ /YAML::XS::Load Error: The problem:\s*\n?\s*(.+?)(?:\n|$)/;
    $what //= 'did not find expected key';
    $what =~ s/\s+\z//;
    return ( undef, 'yaml: line ' . ( $line // 1 ) . ": $what" );
}

# Prometheus-Dauer ("90s", "1m30s", "2h") in Sekunden, undef wenn ungueltig
sub _dur {
    my ($s) = @_;
    return undef unless defined $s && $s =~ /\A(?:\d+(?:ms|s|m|h|d|w|y))+\z/;
    my %f = ( ms => 0.001, s => 1, m => 60, h => 3600, d => 86400, w => 604800, y => 31536000 );
    my $t = 0;
    $t += $1 * $f{$2} while $s =~ /(\d+)(ms|s|m|h|d|w|y)/g;
    return $t;
}

our %RULE_KEYS =map { $_ => 1 } qw( alert record expr for labels annotations keep_firing_for );

# Regeldatei pruefen: ( zahl der regeln ) oder ( undef, [ fehler ] )
sub _check_rules {
    my ( $path, $text ) = @_;
    my ( $d, $ye ) = _yaml($text);
    return ( undef, ["$path: $ye"] ) if $ye;
    return ( undef, ["$path: yaml: unmarshal errors: groups missing"] ) unless ref $d eq 'HASH' && ref $d->{groups} eq 'ARRAY';
    my ( $n, @e, %gn ) = (0);
    for my $g ( @{ $d->{groups} } ) {
        push @e, "$path: group name must not be empty" unless ref $g eq 'HASH' && defined $g->{name} && length $g->{name};
        next unless ref $g eq 'HASH';
        push @e, "$path: $g->{name}: repeated in the same file" if defined $g->{name} && $gn{ $g->{name} }++;
        for my $r ( @{ $g->{rules} || [] } ) {
            if ( ref $r ne 'HASH' ) { push @e, "$path: rule is not a map"; next }
            for my $k ( sort keys %$r ) { push @e, "$path: field $k not found in type rulefmt.RuleNode" unless $RULE_KEYS{$k} }
            push @e, "$path: group \"$g->{name}\", rule $n: one of 'record' or 'alert' must be set" unless defined $r->{alert} || defined $r->{record};
            push @e, "$path: group \"$g->{name}\", rule $n: field 'expr' must be set in rule" unless defined $r->{expr} && length $r->{expr};
            if ( defined $r->{expr} ) {
                my $x = $r->{expr};
                my $open = () = $x =~ /\(/g;
                my $close = () = $x =~ /\)/g;
                push @e, "$path: group \"$g->{name}\", rule $n, \"" . ( $r->{alert} // $r->{record} // '' ) . "\": could not parse expression: 1:1: parse error: unclosed left parenthesis"
                    if $open != $close;
            }
            if ( defined $r->{for} && $r->{for} !~ /\A\d+(?:ms|s|m|h|d|w|y)\z/ ) {
                push @e, "$path: group \"$g->{name}\", rule $n: not a valid duration string: \"$r->{for}\"";
            }
            $n++;
        }
    }
    return ( undef, \@e ) if @e;
    return ($n);
}

=func check_prometheus

  my ( $fehler, $regeldateien, $zahl_regeln ) = check_prometheus( $dev, $pfad );

=cut

sub check_prometheus {
    my ( $dev, $path ) = @_;
    my $text = _file_text( $dev, $path );
    return ( ["open $path: no such file or directory"], {} ) unless defined $text;
    my ( $d, $ye ) = _yaml($text);
    return ( ["parsing YAML file $path: $ye"], {} ) if $ye;
    return ( ["parsing YAML file $path: yaml: unmarshal errors: config is not a map"], {} ) unless ref $d eq 'HASH';
    my @e;
    my %known = map { $_ => 1 } qw( global scrape_configs rule_files alerting remote_write remote_read storage tracing scrape_config_files );
    push @e, "parsing YAML file $path: yaml: unmarshal errors: field $_ not found in type config.plain" for grep { !$known{$_} } sort keys %$d;
    my %jobs;
    my $g = ref $d->{global} eq 'HASH' ? $d->{global} : {};
    my $gi = _dur( $g->{scrape_interval} // '1m' );
    my $gt = _dur( $g->{scrape_timeout} // '10s' );
    for my $sc ( @{ $d->{scrape_configs} || [] } ) {
        my $j = ref $sc eq 'HASH' ? $sc->{job_name} : undef;
        if ( !defined $j || !length $j ) { push @e, "parsing YAML file $path: job_name is empty"; next }
        push @e, "parsing YAML file $path: found multiple scrape configs with job name \"$j\"" if $jobs{$j}++;
        my $iv = defined $sc->{scrape_interval} ? _dur( $sc->{scrape_interval} ) : $gi;
        my $to = defined $sc->{scrape_timeout} ? _dur( $sc->{scrape_timeout} ) : ( $gt > $iv ? $iv : $gt );
        for my $k (qw( scrape_interval scrape_timeout )) {
            push @e, "parsing YAML file $path: not a valid duration string: \"$sc->{$k}\"" if defined $sc->{$k} && !defined _dur( $sc->{$k} );
        }
        push @e, "parsing YAML file $path: scrape timeout greater than scrape interval for scrape config with job name \"$j\""
            if defined $iv && defined $to && $to > $iv;
        for my $s ( @{ $sc->{static_configs} || [] } ) {
            for my $t ( @{ ( ref $s eq 'HASH' ? $s->{targets} : undef ) || [] } ) {
                push @e, "parsing YAML file $path: \"$t\" is not a valid hostname" unless defined $t && $t =~ /\A[\w.\-\[\]:]+:\d+\z/;
            }
        }
    }
    my ( %rules, $nr );
    for my $pat ( @{ $d->{rule_files} || [] } ) {
        ( my $p = $pat ) =~ s{\A(?!/)}{ ( $path =~ m{\A(.*)/} )[0] . '/' }e;
        for my $f ( _glob_files( $dev, $p ) ) {
            my $t = _file_text( $dev, $f );
            my ( $n, $re ) = _check_rules( $f, $t );
            if ($re) { push @e, map {"loading groups failed: $_"} @$re; next }
            $rules{$f} = $t;
            $nr += $n;
        }
    }
    return ( \@e, \%rules, $nr // 0 );
}

=func check_alertmanager

  my $fehler = check_alertmanager( $dev, $pfad );

=cut

sub check_alertmanager {
    my ( $dev, $path ) = @_;
    my $text = _file_text( $dev, $path );
    return ["open $path: no such file or directory"] unless defined $text;
    my ( $d, $ye ) = _yaml($text);
    return [$ye] if $ye;
    return ['no route provided in config'] unless ref $d eq 'HASH' && ref $d->{route} eq 'HASH';
    my %recv = map { ( ref $_ eq 'HASH' ? $_->{name} // '' : '' ) => 1 } @{ $d->{receivers} || [] };
    my @e;
    my $walk;
    $walk = sub {
        my ( $r, $top ) = @_;
        if ( defined $r->{receiver} ) { push @e, "undefined receiver \"$r->{receiver}\" used in route" unless $recv{ $r->{receiver} } }
        elsif ($top) { push @e, 'root route must specify a default receiver' }
        $walk->( $_, 0 ) for grep { ref $_ eq 'HASH' } @{ $r->{routes} || [] };
    };
    $walk->( $d->{route}, 1 );
    return \@e;
}

=func service_check

  my ( $journalzeilen, $nachgeladen ) = service_check( $dev, $svc, 'prometheus'|'alertmanager' );

=cut

sub service_check {
    my ( $dev, $svc, $kind ) = @_;
    my $main = $svc->{config_main} // ( ref $svc->{config} ? $svc->{config}[0] : $svc->{config} );
    my $ts   = 'ts=2026-10-24T09:12:03.000Z';
    if ( $kind eq 'prometheus' ) {
        my ( $e, $rules ) = check_prometheus( $dev, $main );
        return ( [ map {qq{$ts caller=main.go:1150 level=error msg="Error reloading config" err="couldn't load configuration (--config.file=\\"$main\\"): $_"}} @$e ], {} ) if @$e;
        return ( [], $rules );
    }
    if ( $kind eq 'alertmanager' ) {
        my $e = check_alertmanager( $dev, $main );
        return ( [ map {qq{$ts caller=coordinator.go:118 level=error component=configuration msg="Loading configuration file failed" file=$main err="$_"}} @$e ], {} ) if @$e;
        $svc->{_routes} = _am_routes( _file_text( $dev, $main ) );
        return ( [], {} );
    }
    return ( [], {} );
}

=func http

  my ( $body, $status ) = http( $dev, 'GET'|'POST', $port, $pfad, $run );

Die HTTP-Schnittstelle von Prometheus (9090) und Alertmanager (9093) auf dem
Gerät, aus der laufenden Konfiguration: C</-/healthy>, C</-/ready>,
C</api/v1/status/config>, C</api/v1/rules>, C<POST /-/reload> (nur mit
C<--web.enable-lifecycle>, sonst 403), Alertmanager C</api/v2/status> und
C<POST /-/reload>. Ohne
laufenden Dienst C<$status> 0 (Verbindung abgelehnt); anderes ist eine Lücke
(C<undef>).

=cut

sub http {
    my ( $dev, $method, $port, $path, $run ) = @_;
    my $kind = $port == 9090 ? 'prometheus' : $port == 9093 ? 'alertmanager' : return;
    my ( $name, $svc ) = map { ( $_, $dev->{services}{$_} ) }
        grep { ( $dev->{services}{$_}{config_check} // '' ) eq $kind } sort keys %{ $dev->{services} || {} };
    return ( '', 0 ) unless $svc && $svc->{active};
    my $run_cfg = ref $svc->{running} eq 'HASH' ? $svc->{running} : {};
    my $main    = $svc->{config_main} // ( ref $svc->{config} ? $svc->{config}[0] : $svc->{config} );
    $path =~ s/\?.*//;
    my $js = sub { JSON::MaybeXS->new( canonical => 1 )->encode( { status => 'success', data => $_[0] } ) };
    if ( $kind eq 'prometheus' ) {
        return ( 'Prometheus Server is Healthy.', 200 ) if $path eq '/-/healthy';
        return ( 'Prometheus Server is Ready.',   200 ) if $path eq '/-/ready';
        if ( $path eq '/-/reload' ) {
            return ( 'Only POST or PUT requests allowed', 405 ) if $method ne 'POST';
            my $args = join ' ', map { $run_cfg->{$_} // '' } grep { m{\A/etc/default/} } keys %$run_cfg;
            return ( 'Lifecycle API is not enabled.', 403 ) unless $args =~ /--web\.enable-lifecycle/;
            my ( $o, $ok ) = $run->("systemctl reload $name");
            return ( $ok ? '' : "failed to reload config: $o", $ok ? 200 : 500 );
        }
        return ( $js->( { yaml => $run_cfg->{$main} // '' } ), 200 ) if $path eq '/api/v1/status/config';
        if ( $path eq '/api/v1/rules' ) {
            my @groups;
            for my $f ( sort grep { $_ ne $main && !m{\A/etc/default/} } keys %$run_cfg ) {
                my ($d) = _yaml( $run_cfg->{$f} );
                for my $g ( @{ ( ref $d eq 'HASH' ? $d->{groups} : undef ) || [] } ) {
                    my @r;
                    for my $x ( grep { ref $_ eq 'HASH' } @{ $g->{rules} || [] } ) {
                        my %r = ( name => $x->{alert} // $x->{record}, query => $x->{expr}, health => 'ok',
                            type => defined $x->{alert} ? 'alerting' : 'recording' );
                        %r = ( %r, duration => _dur( $x->{for} // '0s' ) // 0, labels => $x->{labels} // {},
                            annotations => $x->{annotations} // {}, state => 'inactive', alerts => [] ) if defined $x->{alert};
                        push @r, \%r;
                    }
                    push @groups, { name => $g->{name}, file => $f, interval => 15, rules => \@r };
                }
            }
            return ( $js->( { groups => \@groups } ), 200 );
        }
        return;
    }
    return ( 'OK', 200 ) if $path eq '/-/healthy' || $path eq '/-/ready';
    if ( $path eq '/-/reload' ) {    # bei Alertmanager immer offen
        return ( 'Only POST requests allowed', 405 ) if $method ne 'POST';
        my ( $o, $ok ) = $run->("systemctl reload $name");
        return ( $ok ? '' : "failed to reload config: $o", $ok ? 200 : 500 );
    }
    if ( $path eq '/api/v2/status' ) {
        return ( JSON::MaybeXS->new( canonical => 1 )->encode( { config => { original => $run_cfg->{$main} // '' }, cluster => { status => 'disabled' } } ), 200 );
    }
    return;
}

=func promtool

  my ( $out, $ok ) = promtool( $dev, \@argv );

=cut

sub promtool {
    my ( $dev, $av ) = @_;
    my @a = grep { !/\A--/ } @$av;
    my ( $cmd, $what, @files ) = @a;
    if ( ( $cmd // '' ) ne 'check' || ( $what // '' ) !~ /\A(?:config|rules)\z/ ) { push @GAPS, join( ' ', 'promtool', @$av ); return ( '', 0 ) }
    my ( @out, $ok );
    $ok = 1;
    for my $f (@files) {
        push @out, "Checking $f";
        if ( $what eq 'config' ) {
            my ( $e, $rules, $n ) = check_prometheus( $dev, $f );
            if (@$e) { push @out, map {"  FAILED: $_"} @$e; $ok = 0; push @out, ''; next }
            push @out, '  SUCCESS: ' . scalar( keys %$rules ) . ' rule files found', " SUCCESS: $f is valid prometheus config file syntax", '';
            for my $r ( sort keys %$rules ) { push @out, "Checking $r", "  SUCCESS: " . ( _check_rules( $r, $rules->{$r} ) )[0] . ' rules found', '' }
        }
        else {
            my $t = _file_text( $dev, $f );
            if ( !defined $t ) { push @out, "  FAILED:", "open $f: no such file or directory", ''; $ok = 0; next }
            my ( $n, $e ) = _check_rules( $f, $t );
            if ($e) { push @out, '  FAILED:', @$e, ''; $ok = 0; next }
            push @out, "  SUCCESS: $n rules found", '';
        }
    }
    pop @out while @out && $out[-1] eq '';
    return ( join( "\n", @out ), $ok );
}

=func amtool

  my ( $out, $ok ) = amtool( $dev, \@argv );

=cut

# Wirksame Einstellungen je Empfaenger: { empfaenger => { repeat_interval, group_wait,
# group_interval, group_by } } — Unterrouten erben, was sie nicht selbst setzen (erste Route je Empfaenger)
our %AM_ROUTE_DEFAULT = ( group_wait => '30s', group_interval => '5m', repeat_interval => '4h' );

sub _am_routes {
    my ($text) = @_;
    my ($d) = _yaml($text);
    my %out;
    my $walk;
    $walk = sub {
        my ( $r, $parent ) = @_;
        return unless ref $r eq 'HASH';
        my %eff = %$parent;
        for my $k (qw( receiver repeat_interval group_wait group_interval )) { $eff{$k} = $r->{$k} if defined $r->{$k} }
        $eff{group_by} = join( ',', @{ $r->{group_by} } ) if ref $r->{group_by} eq 'ARRAY';
        my %copy = %eff;
        $out{ $eff{receiver} } //= \%copy if defined $eff{receiver};
        $walk->( $_, \%eff ) for @{ $r->{routes} || [] };
    };
    $walk->( ref $d eq 'HASH' ? $d->{route} : undef, {%AM_ROUTE_DEFAULT} );
    return \%out;
}

# Zeit: Uhr des Geraets (clock "Oct 24 09:12", Jahr 2026, Zone tz, Vorgabe +02:00) als Epoche
our %MON = ( Jan => 0, Feb => 1, Mar => 2, Apr => 3, May => 4, Jun => 5, Jul => 6, Aug => 7, Sep => 8, Oct => 9, Nov => 10, Dec => 11 );

=func now_epoch

  my $t = now_epoch($dev);

Die Uhr des Geräts (C<clock>, Jahr 2026, Zone C<tz>) als Unix-Zeit.

=cut

sub now_epoch {
    my ($dev) = @_;
    require Time::Local;
    my ( $mon, $day, $h, $mi ) = ( $dev->{clock} // 'Oct 20 09:12' ) =~ /\A(\w{3})\s+(\d+)\s+(\d+):(\d+)/;
    return Time::Local::timegm( 0, $mi, $h, $day, $MON{$mon} // 9, 2026 ) - _tz_secs($dev);
}

sub _tz_secs {
    my ($dev) = @_;
    my ( $sg, $h, $m ) = ( $dev->{tz} // '+02:00' ) =~ /\A([+-])(\d\d):?(\d\d)\z/ or return 0;
    return ( $sg eq '-' ? -1 : 1 ) * ( $h * 3600 + $m * 60 );
}

# RFC 3339 -> Epoche; undef wenn nicht lesbar
sub _rfc3339 {
    my ($t) = @_;
    require Time::Local;
    my ( $Y, $M, $D, $h, $m, $s, $z ) = ( $t // '' ) =~ /\A(\d{4})-(\d\d)-(\d\d)T(\d\d):(\d\d):(\d\d)(?:\.\d+)?(Z|[+-]\d\d:\d\d)\z/ or return undef;
    my $e = Time::Local::timegm( $s, $m, $h, $D, $M - 1, $Y );
    if ( $z ne 'Z' ) { my ( $sg, $zh, $zm ) = $z =~ /([+-])(\d\d):(\d\d)/; $e -= ( $sg eq '-' ? -1 : 1 ) * ( $zh * 3600 + $zm * 60 ) }
    return $e;
}

sub _iso { my @t = gmtime $_[0]; return sprintf '%04d-%02d-%02dT%02d:%02d:%02dZ', $t[5] + 1900, $t[4] + 1, @t[ 3, 2, 1, 0 ] }

# Go-Dauer: 2h, 90m, 1h30m, 45s
sub _godur {
    my ($d) = @_;
    return undef unless defined $d && $d =~ /\A(?:\d+(?:\.\d+)?(?:h|m|s|ms))+\z/;
    my $t = 0;
    while ( $d =~ /(\d+(?:\.\d+)?)(ms|h|m|s)/g ) { $t += $1 * { h => 3600, m => 60, s => 1, ms => 0.001 }->{$2} }
    return int $t;
}

# Matcher: name=wert, name!=wert, name=~re, name!~re (Wert ggf. in Anfuehrungszeichen)
sub _am_matcher {
    my ($x) = @_;
    my ( $n, $op, $v ) = $x =~ /\A\s*([A-Za-z_]\w*)\s*(=~|!~|!=|=)\s*(.*?)\s*\z/ or return undef;
    $v =~ s/\A"(.*)"\z/$1/s;
    $v =~ s/\A'(.*)'\z/$1/s;
    return { name => $n, op => $op, value => $v };
}

sub _am_matches {
    my ( $ms, $labels ) = @_;
    for my $m (@$ms) {
        my $have = $labels->{ $m->{name} } // '';
        my $hit = $m->{op} =~ /~/ ? ( eval { $have =~ /\A(?:$m->{value})\z/ } // 0 ) : $have eq $m->{value};
        $hit = !$hit if $m->{op} =~ /\A!/;
        return 0 unless $hit;
    }
    return 1;
}

# Silence mit abgeleiteten Feldern: starts/ends (UTC), state, covers (Namen aus alert_targets)
sub _am_silence_view {
    my ( $svc, $sil, $now ) = @_;
    my $t = $svc->{alert_targets} || {};
    $sil->{starts} = _iso( $sil->{_start} );
    $sil->{ends}   = _iso( $sil->{_end} );
    $sil->{state}  = $sil->{_expired} || $sil->{_end} <= $now ? 'expired' : $sil->{_start} > $now ? 'pending' : 'active';
    $sil->{covers} = [ sort grep { _am_matches( $sil->{_matchers}, $t->{$_} ) } keys %$t ];
    return $sil;
}

sub _am_svc {
    my ($dev) = @_;
    my ($n) = grep { ( $dev->{services}{$_}{config_check} // '' ) eq 'alertmanager' } sort keys %{ $dev->{services} || {} };
    return defined $n ? $dev->{services}{$n} : undef;
}

sub _amtool_silence {
    my ( $dev, $sub, $av ) = @_;
    my ( %opt, @pos );
    my @a = @$av;
    while (@a) {
        my $x = shift @a;
        if    ( $x =~ /\A--([\w.-]+)=(.*)\z/s ) { $opt{$1} = $2 }
        elsif ( $x =~ /\A--([\w.-]+)\z/ && $1 !~ /\A(?:quiet|expired|extended)\z/ ) { $opt{$1} = shift @a }
        elsif ( $x =~ /\A-([acdq])\z/ ) { $opt{ { a => 'author', c => 'comment', d => 'duration', q => 'quiet' }->{$1} } = $1 eq 'q' ? 1 : shift @a }
        elsif ( $x =~ /\A--(quiet|expired|extended)\z/ ) { $opt{$1} = 1 }
        else  { push @pos, $x }
    }
    my $url = $opt{'alertmanager.url'};
    if ( !defined $url ) {
        my $cf = _file_text( $dev, '/etc/amtool/config.yml' ) // _file_text( $dev, '/root/.config/amtool/config.yml' ) // '';
        ($url) = $cf =~ /^\s*alertmanager\.url:\s*"?([^"\s]+)/m;
    }
    return ( 'amtool: error: required flag --alertmanager.url not provided', 0 ) unless defined $url;
    my $svc = _am_svc($dev);
    return ( qq{Post "$url/api/v2/silences": dial tcp: connect: connection refused}, 0 )
        unless $svc && $svc->{active} && $url =~ m{\Ahttps?://(?:localhost|127\.0\.0\.1|\[::1\])?(?::9093)?/?\z};
    my $now = now_epoch($dev);
    my $sil = $svc->{silences} //= [];
    $_ = _am_silence_view( $svc, $_, $now ) for @$sil;
    if ( $sub eq 'add' ) {
        my @m;
        for my $p (@pos) {
            my $m = _am_matcher($p) // ( $p =~ /\A[\w:.-]+\z/ ? { name => 'alertname', op => '=', value => $p } : undef );
            return ( qq{amtool: error: bad matcher format: $p}, 0 ) unless $m;
            push @m, $m;
        }
        return ( 'amtool: error: no matchers specified', 0 ) unless @m;
        return ( 'amtool: error: comment required by config', 0 ) unless defined $opt{comment} && length $opt{comment};
        my $start = defined $opt{start} ? _rfc3339( $opt{start} ) : $now;
        return ( qq{amtool: error: parsing time "$opt{start}" as "2006-01-02T15:04:05Z07:00": cannot parse}, 0 ) unless defined $start;
        my $end;
        if ( defined $opt{end} ) {
            $end = _rfc3339( $opt{end} ) // return ( qq{amtool: error: parsing time "$opt{end}" as "2006-01-02T15:04:05Z07:00": cannot parse}, 0 );
        }
        else {
            my $d = _godur( $opt{duration} // '1h' ) // return ( qq{amtool: error: time: invalid duration "$opt{duration}"}, 0 );
            $end = $start + $d;
        }
        return ( 'amtool: error: silence cannot end before it starts', 0 ) if $end <= $start;
        return ( 'amtool: error: silence cannot end in the past', 0 ) if $end <= $now;
        my $id = sprintf '%08x-%04x-4%03x-a%03x-%012x', 0x5e1e0000 + @$sil, 0x2026, scalar @$sil, 0x124, $start;
        push @$sil, _am_silence_view( $svc, { id => $id, matchers => [ map {"$_->{name}$_->{op}$_->{value}"} @m ], comment => $opt{comment},
            author => $opt{author} // 'root', _matchers => \@m, _start => $start, _end => $end }, $now );
        return ( $id, 1 );
    }
    if ( $sub eq 'query' || $sub eq '' ) {
        my @l = grep { $opt{expired} ? $_->{state} eq 'expired' : $_->{state} ne 'expired' } @$sil;
        return ( join( "\n", map { $_->{id} } @l ), 1 ) if $opt{quiet};
        my $f = '%-37s %-40s %-24s %-10s %s';
        return ( join( "\n", sprintf( $f, 'ID', 'Matchers', 'Ends At', 'Created By', 'Comment' ),
            map { sprintf( $f, $_->{id}, join( ' ', @{ $_->{matchers} } ), $_->{ends} =~ s/T/ /r =~ s/Z\z/ UTC/r, $_->{author}, $_->{comment} ) } @l ), 1 );
    }
    if ( $sub eq 'expire' ) {
        return ( 'amtool: error: no silence IDs specified', 0 ) unless @pos;
        for my $id (@pos) {
            my ($s) = grep { $_->{id} eq $id } @$sil or return ( qq{silence $id not found}, 0 );
            $s->{_expired} = 1;
            _am_silence_view( $svc, $s, $now );
        }
        return ( '', 1 );
    }
    push @GAPS, join( ' ', 'amtool silence', $sub, @$av );
    return ( '', 0 );
}

sub amtool {
    my ( $dev, $av ) = @_;
    my @all = @$av;
    if ( ( $all[0] // '' ) eq 'silence' ) {
        my $sub = defined $all[1] && $all[1] !~ /\A-/ ? $all[1] : '';
        return _amtool_silence( $dev, $sub, [ @all[ ( $sub eq '' ? 1 : 2 ) .. $#all ] ] );
    }
    if ( ( $all[0] // '' ) eq 'alert' && ( ( $all[1] // 'query' ) eq 'query' || $all[1] =~ /\A-/ ) ) {
        my $svc = _am_svc($dev) or return ( 'amtool: error: required flag --alertmanager.url not provided', 0 );
        my $now = now_epoch($dev);
        my $sil = $svc->{silences} || [];
        $_ = _am_silence_view( $svc, $_, $now ) for @$sil;
        my $t = $svc->{alert_targets} || {};
        my @rows;
        for my $a ( @{ $svc->{alerts} || [] } ) {
            my $lab = { %{ $t->{ $a->{target} // '' } || {} }, alertname => $a->{alertname} };
            next if grep { $_->{state} eq 'active' && _am_matches( $_->{_matchers}, $lab ) } @$sil;
            push @rows, sprintf( '%-22s %-26s %s', $a->{alertname}, $a->{since} // '2026-10-24 06:58:12 UTC', $a->{summary} // '' );
        }
        return ( join( "\n", sprintf( '%-22s %-26s %s', 'Alertname', 'Starts At', 'Summary' ), @rows ), 1 );
    }
    my @a = grep { !/\A--/ } @$av;
    my ( $cmd, @files ) = @a;
    if ( ( $cmd // '' ) ne 'check-config' ) { push @GAPS, join( ' ', 'amtool', @$av ); return ( '', 0 ) }
    my ( @out, $ok );
    $ok = 1;
    for my $f (@files) {
        push @out, "Checking '$f'";
        my $e = check_alertmanager( $dev, $f );
        if (@$e) { push @out, "  FAILED: $_" for @$e; $ok = 0; next }
        my ($d) = _yaml( _file_text( $dev, $f ) );
        push @out, '  SUCCESS', 'Found:', ' - global config', ' - route', ' - ' . scalar( @{ $d->{inhibit_rules} || [] } ) . ' inhibit rules',
            ' - ' . scalar( @{ $d->{receivers} || [] } ) . ' receivers', ' - 0 templates', '';
    }
    pop @out while @out && $out[-1] eq '';
    return ( join( "\n", @out ), $ok );
}

1;
