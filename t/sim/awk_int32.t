#!/usr/bin/env perl
use strict;
use warnings;
use utf8;
use Test::More;

# awk gibt eine ganze Zahl unter 1e16 als ihre Ziffern aus, auch auf einer Perl mit
# 32-Bit-IV. Dort kippte sprintf '%d' jenseits von 2**31-1: ein CPAN-Testers-Bericht
# (i686-linux, ivsize=4) zeigte fuer die Summe 3758096384 "-0.5 GB in 3 Dateien" statt
# "3.5 GB", die Summe war zu 3758096384 - 2**32 geworden.
#
# Behauptet wird das ohne die Plattform: vor dem Laden von Filter.pm rechnet ein globales
# sprintf '%d'/'%i' wie eine Perl mit 32-Bit-IV, die den Wert per Perl_cast_iv in eine IV
# zwingt: (2**31-1, 2**32) laeuft um auf Wert - 2**32, ab 2**32 saettigt die UV auf
# UV_MAX und ergibt -1, unter -2**31 saettigt die IV auf -2**31. Das ist der Weg, der im
# Bericht -536870912 ergab; die ersten beiden Tests halten fest, dass die Emulation genau
# das tut. Alles andere geht unveraendert an CORE::sprintf.

BEGIN {
    die "Filter.pm ist schon geladen, die Emulation griffe dort nicht\n" if $INC{'Langertha/Holmgang/Shell/Filter.pm'};
    *CORE::GLOBAL::sprintf = sub ($@) {
        my ( $f, @a ) = @_;
        my $n = 0;
        while ( $f =~ /%([^a-zA-Z%]*)([a-zA-Z%])/g ) {
            my ( $mod, $c ) = ( $1, $2 );
            next if $c eq '%';
            die "sprintf-Emulation: %$mod$c ist nicht vorgesehen\n" if $mod =~ /[*\$]/ || $c eq 'v';
            my $i = $n++;
            next unless $c eq 'd' || $c eq 'i';
            no warnings 'numeric';
            my $v = int( $a[$i] // 0 );
            $a[$i] = $v >= 2**32 ? -1 : $v > 2**31 - 1 ? $v - 2**32 : $v < -2**31 ? -2**31 : $a[$i];
        }
        return CORE::sprintf( $f, @a );
    };
}

use Langertha::Holmgang::Shell::Filter ();

is( sprintf( '%d', 3758096384 ), '-536870912', 'Emulation: zwischen 2**31 und 2**32 laeuft %d um wie im Bericht' );
is( sprintf( '%d', 2**32 ), '-1', 'Emulation: ab 2**32 ergibt %d -1' );

my $awk = sub { my $in = shift; ( Langertha::Holmgang::Shell::Filter::filter_output( $in, [ 'awk', @_ ] ) )[0] };
my $du = "1073741824 a.log\n536870912 b.log\n2147483648 c.log";
is( $awk->( $du, '{s+=$1} END {printf "%.1f GB in %d Dateien\n", s/1024/1024/1024, NR}' ), '3.5 GB in 3 Dateien', 'Summe ueber 2**31 wie im Bericht: 3.5 GB' );
is( $awk->( $du, '{s+=$1} END {print s}' ), '3758096384', 'print: Summe zwischen 2**31 und 2**32' );
is( $awk->( "4294967296 d.img\n1 e.txt", '{s+=$1} END {print s}' ), '4294967297', 'print: Summe ab 2**32' );
is( $awk->( '', 'BEGIN { x = 2147483647; x++; print x }' ), '2147483648', '++ ueber 2**31-1' );
is( $awk->( '3000000000', '{ print -$1 }' ), '-3000000000', 'Vorzeichen: unter -2**31' );
is( $awk->( '', 'BEGIN { print 9007199254740992 + 0 }' ), '9007199254740992', '2**53: alle Ziffern' );
is( $awk->( '', 'BEGIN { x = -0.5 * 0; print x }' ), '0', '-0 kommt als 0 heraus wie bisher' );

done_testing;
