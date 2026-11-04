package Langertha::Holmgang::Evaluation;
# ABSTRACT: Per-topic evaluation of Holmgang reports: weights, length tiers, verdicts, comparison

use Moose;
use namespace::autoclean;
use Carp qw( croak );
use JSON::MaybeXS ();
use Langertha::Holmgang::Report ();
use Scalar::Util qw( blessed );

our $VERSION = '0.001';

#### Constants

# The format version of the evaluation document (ADR 0008).
sub format_version { 1 }

# The seven status wire names of ADR 0006, in its order.
sub statuses { qw( no_vision context_exceeded error turn_limit passed uncertain failed ) }

# The length tiers of CONTEXT.md, in curve order.
sub tiers { qw( 16k 48k 96k 160k ) }

# The topic of a suite that names none (ADR 0005).
sub default_topic { 'sonstiges' }

# The tags that make a hard case when the report's `hard` is null (ADR 0005).
sub hard_tags { qw( injection verbot ) }

sub report_class { 'Langertha::Holmgang::Report' }

#### Attributes

around BUILDARGS => sub {
  my ( $orig, $class, @args ) = @_;
  my %arg = @args == 1 && ref $args[0] eq 'HASH' ? %{ $args[0] } : @args;
  $arg{reports} = [ delete $arg{report} ] if exists $arg{report};
  return $class->$orig(%arg);
};

has reports => ( is => 'ro', required => 1 );

=attr reports

Required. The L<Langertha::Holmgang::Report> objects to evaluate, as an array
reference; C<< report => $report >> is the same for one. They are joined with
L<Langertha::Holmgang::Report/merge> first, so a repetition found in two files
counts once and a conflict croaks.

=cut

has thresholds => ( is => 'ro', default => sub { {} } );

=attr thresholds

Optional. Per suite id the suite's C<threshold> as the loader reads it from
F<suite.yaml>: C<< { 'suite-id' => { pass_rate => 0.9, pass_k => 0.5 } } >>.
A report does not carry the threshold, so a suite missing here is judged by its
hard cases alone.

=cut

sub BUILD {
  my ( $self ) = @_;
  my $reports = $self->reports;
  croak __PACKAGE__.'->new needs reports (an array of '.$self->report_class.')'
    unless ref $reports eq 'ARRAY' && @$reports;
  for my $r ( @$reports ) {
    croak __PACKAGE__.'->new: '.( defined $r ? $r : 'undef' ).' is not a '.$self->report_class
      unless blessed $r && $r->isa( $self->report_class );
  }
  croak __PACKAGE__.'->new: thresholds must be a hash of suite id to threshold'
    unless ref $self->thresholds eq 'HASH';
  return;
}

has _runs => ( is => 'ro', lazy_build => 1 );

# The merged runs, flattened into what every view needs.
sub _build__runs {
  my ( $self ) = @_;
  my $merged = $self->report_class->merge( @{ $self->reports } );
  my $json   = JSON::MaybeXS->new( canonical => 1 );
  my %hard_tag = map { $_ => 1 } $self->hard_tags;
  my @runs;
  for my $run ( @{ $merged->runs } ) {
    my $target  = $run->{target}  || {};
    my $variant = $run->{variant} || {};
    push @runs, {
      row     => $json->encode( { target => $target, variant => $variant } ),
      target  => $self->_target_label($target),
      variant => $variant->{name},
      suite   => $run->{suite}{id},
      topic   => defined $run->{suite}{topic} && length $run->{suite}{topic} ? $run->{suite}{topic} : $self->default_topic,
      k       => $run->{repeat},
      cases   => [ map {
        my $c = $_;
        {
          case_id     => $c->{case_id},
          weight      => defined $c->{weight} ? $c->{weight} : 1,
          tier        => $c->{tier},
          hard        => defined $c->{hard} ? ( $c->{hard} ? 1 : 0 )
                       : ( grep { $hard_tag{$_} } @{ $c->{tags} || [] } ) ? 1 : 0,
          repetitions => $c->{repetitions},
        }
      } @{ $run->{cases} } ],
    };
  }
  return \@runs;
}

sub _target_label {
  my ( $self, $t ) = @_;
  for my $k (qw( label model engine )) {
    return $t->{$k} if defined $t->{$k} && length $t->{$k};
  }
  return '?';
}

#### Tallies

sub _tally {
  my ( $self ) = @_;
  return { results => 0, _weight => 0, _w => {}, counts => { map { $_ => 0 } $self->statuses } };
}

sub _add {
  my ( $self, $t, $rep, $weight ) = @_;
  $t->{results}++;
  $t->{_weight} += $weight;
  $t->{counts}{ $rep->{status} }++;
  $t->{_w}{ $rep->{status} } += $weight;
  return;
}

sub _round { my ( $self, $n ) = @_; return defined $n ? 0 + sprintf( '%.4f', $n ) : undef }

# Weighted share of one status among all results of a tally.
sub _share {
  my ( $self, $t, $status ) = @_;
  return undef unless $t->{_weight} > 0;
  return $self->_round( ( $t->{_w}{$status} // 0 ) / $t->{_weight} );
}

# The public part of a tally.
sub _counted {
  my ( $self, $t ) = @_;
  return (
    results => $t->{results},
    weight  => $self->_round( $t->{_weight} ),
    counts  => { %{ $t->{counts} } },
    rate    => $self->_share( $t, 'passed' ),
  );
}

#### Topics

has _topics => ( is => 'ro', lazy_build => 1 );

sub topics { my ( $self ) = @_; return $self->_public( $self->_topics ) }

sub _build__topics {
  my ( $self ) = @_;
  my ( %agg, @rows );
  for my $run ( @{ $self->_runs } ) {
    my $a = $agg{ $run->{row} }{ $run->{topic} } //= do {
      push @rows, $run->{row};
      { target => $run->{target}, variant => $run->{variant}, topic => $run->{topic},
        suites => [], tally => $self->_tally, tokens => {} };
    };
    push @{ $a->{suites} }, $run->{suite} unless grep { $_ eq $run->{suite} } @{ $a->{suites} };
    for my $c ( @{ $run->{cases} } ) {
      for my $rep ( @{ $c->{repetitions} } ) {
        $self->_add( $a->{tally}, $rep, $c->{weight} );
        for my $f (qw( input output reasoning )) {
          my $n = $rep->{tokens} && $rep->{tokens}{$f};
          $a->{tokens}{$f} += $n if defined $n;
        }
      }
    }
  }
  my %seen;
  @rows = grep { !$seen{$_}++ } @rows;
  my @out;
  for my $row ( @rows ) {
    for my $topic ( sort keys %{ $agg{$row} } ) {
      my $a = $agg{$row}{$topic};
      push @out, {
        target  => $a->{target},
        variant => $a->{variant},
        topic   => $topic,
        suites  => [ sort @{ $a->{suites} } ],
        $self->_counted( $a->{tally} ),
        tokens  => { map { $_ => $a->{tokens}{$_} } qw( input output reasoning ) },
        _row    => $row,
      };
    }
  }
  return \@out;
}

=method topics

    # [ { target, variant, topic, suites => [ ids ], results, weight,
    #     counts => { <status> => n, … }, rate,
    #     tokens => { input, output, reasoning } }, … ]

Per row (target and variant, in the order they first appear) and topic (by
name): C<results> is the number of repetitions with a result, C<counts> counts
each of the seven statuses under its own name, C<weight> the sum of the case
weights over those results, C<rate> the weighted share of C<passed> among all
results (C<null> without results). Tokens are sums, C<null> when no repetition
had a value.

=cut

has _overall => ( is => 'ro', lazy_build => 1 );

sub overall { my ( $self ) = @_; return $self->_public( $self->_overall ) }

sub _build__overall {
  my ( $self ) = @_;
  my ( %o, @rows );
  for my $t ( @{ $self->_topics } ) {
    my $o = $o{ $t->{_row} } //= do {
      push @rows, $t->{_row};
      { target => $t->{target}, variant => $t->{variant}, topics => 0, results => 0,
        counts => { map { $_ => 0 } $self->statuses }, _rates => [] };
    };
    $o->{topics}++;
    $o->{results} += $t->{results};
    $o->{counts}{$_} += $t->{counts}{$_} for $self->statuses;
    push @{ $o->{_rates} }, $t->{rate} if defined $t->{rate};
  }
  return [ map {
    my $o = $o{$_};
    my $rates = delete $o->{_rates};
    my $sum = 0;
    $sum += $_ for @$rates;
    $o->{rate} = @$rates ? $self->_round( $sum / @$rates ) : undef;
    $o->{_row} = $_;
    $o;
  } @rows ];
}

=method overall

    # [ { target, variant, topics, results, counts => { … }, rate }, … ]

Per row the B<mean of its topic rates> — never one share over all cases, so a
few hard cases do not drown in many easy ones. Topics without a rate do not
enter the mean; C<rate> is C<null> when none has one. C<results> and C<counts>
are plain sums over the topics.

=cut

#### Length tiers

has tier_curves => ( is => 'ro', lazy_build => 1, init_arg => undef );

sub _tier_order {
  my ( $self, $tier ) = @_;
  my @known = $self->tiers;
  my ($i) = grep { $known[$_] eq $tier } 0 .. $#known;
  return defined $i ? ( 0, $i, 0, '' ) : ( 1, 0, ( $tier =~ /\A([0-9]+)/ ? $1 : 0 ), $tier );
}

sub _build_tier_curves {
  my ( $self ) = @_;
  my ( %agg, @rows );
  for my $run ( @{ $self->_runs } ) {
    for my $c ( @{ $run->{cases} } ) {
      next unless defined $c->{tier} && length $c->{tier};
      my $a = $agg{ $run->{row} }{ $run->{topic} }{ $c->{tier} } //= do {
        push @rows, $run->{row};
        { target => $run->{target}, variant => $run->{variant}, topic => $run->{topic},
          tier => $c->{tier}, tally => $self->_tally };
      };
      $self->_add( $a->{tally}, $_, $c->{weight} ) for @{ $c->{repetitions} };
    }
  }
  my %seen;
  my @out;
  for my $row ( grep { !$seen{$_}++ } @rows ) {
    for my $topic ( sort keys %{ $agg{$row} } ) {
      my $by = $agg{$row}{$topic};
      my @tiers = sort {
        my @x = $self->_tier_order($a);
        my @y = $self->_tier_order($b);
        $x[0] <=> $y[0] || $x[1] <=> $y[1] || $x[2] <=> $y[2] || $x[3] cmp $y[3]
      } keys %$by;
      for my $tier ( @tiers ) {
        my $a = $by->{$tier};
        push @out, {
          target  => $a->{target},
          variant => $a->{variant},
          topic   => $topic,
          tier    => $tier,
          $self->_counted( $a->{tally} ),
          context_exceeded_rate => $self->_share( $a->{tally}, 'context_exceeded' ),
          error_rate            => $self->_share( $a->{tally}, 'error' ),
        };
      }
    }
  }
  return \@out;
}

=attr tier_curves

    # [ { target, variant, topic, tier, results, weight, counts => { … },
    #     rate, context_exceeded_rate, error_rate }, … ]

The curve per length tier, per row and topic: tiers in the order C<16k>,
C<48k>, C<96k>, C<160k>, any other tier after them by its number. Hits
(C<rate>), C<context_exceeded> and C<error> are three weighted shares of the
same results, kept apart; C<counts> has all seven statuses. Cases without a
tier are not on a curve.

=cut

#### Verdicts

has verdicts => ( is => 'ro', lazy_build => 1, init_arg => undef );

sub _build_verdicts {
  my ( $self ) = @_;
  my ( %v, @order );
  for my $run ( @{ $self->_runs } ) {
    my $key = $run->{row}."\0".$run->{suite};
    croak __PACKAGE__.': suite '.$run->{suite}.' appears twice for target '.$run->{target}.' after merging'
      if $v{$key};
    push @order, $key;
    my $v = $v{$key} = { target => $run->{target}, variant => $run->{variant}, suite_id => $run->{suite},
      k => $run->{k}, tally => $self->_tally, cases => [], hard => {} };
    for my $c ( @{ $run->{cases} } ) {
      my @reps = @{ $c->{repetitions} };
      next unless @reps;
      my $passed = grep { $_->{status} eq 'passed' } @reps;
      push @{ $v->{cases} }, { case_id => $c->{case_id}, passed => $passed, repetitions => scalar @reps, _w => $c->{weight} };
      for my $rep ( @reps ) {
        $self->_add( $v->{tally}, $rep, $c->{weight} );
        my $n = $rep->{forbidden_calls} // 0;
        next unless $n && $c->{hard};
        my $h = $v->{hard}{ $c->{case_id} } //= { case_id => $c->{case_id}, forbidden_calls => 0, repetitions => 0 };
        $h->{forbidden_calls} += $n;
        $h->{repetitions}++;
      }
    }
  }
  my @out;
  for my $key ( @order ) {
    my $v  = $v{$key};
    my $th = $self->thresholds->{ $v->{suite_id} } || {};
    my $k  = $v->{k};
    my %c  = $self->_counted( $v->{tally} );
    my $wc = 0;
    $wc += $_->{_w} for @{ $v->{cases} };
    my $share = sub {
      my ( $pick ) = @_;
      return undef unless @{ $v->{cases} } && $wc > 0;
      my $w = 0;
      $w += $_->{_w} for grep { $pick->($_) } @{ $v->{cases} };
      return $self->_round( $w / $wc );
    };
    my $out = {
      target       => $v->{target},
      variant      => $v->{variant},
      suite_id     => $v->{suite_id},
      results      => $c{results},
      counts       => $c{counts},
      passed       => $c{counts}{passed},
      rate         => $c{rate},
      pass_rate    => $th->{pass_rate},
      k            => $k,
      pass_k       => $share->( sub { $_[0]{passed} >= $k } ),
      pass_any     => $share->( sub { $_[0]{passed} > 0 } ),
      pass_k_min   => $th->{pass_k},
      case_results => [ map { { case_id => $_->{case_id}, passed => $_->{passed}, repetitions => $_->{repetitions} } } @{ $v->{cases} } ],
      hard_failed  => [ map { $v->{hard}{$_} } sort keys %{ $v->{hard} } ],
    };
    my $below = ( defined $out->{pass_rate} && ( !defined $out->{rate} || $out->{rate} < $out->{pass_rate} ) )
      || ( defined $out->{pass_k_min} && ( !defined $out->{pass_k} || $out->{pass_k} < $out->{pass_k_min} ) );
    $out->{ok} = $below || @{ $out->{hard_failed} } ? JSON::MaybeXS::false() : JSON::MaybeXS::true();
    push @out, $out;
  }
  return \@out;
}

=attr verdicts

    # [ { target, variant, suite_id, results, counts => { … }, passed, rate,
    #     pass_rate, k, pass_k, pass_any, pass_k_min,
    #     case_results => [ { case_id, passed, repetitions } ],
    #     hard_failed  => [ { case_id, forbidden_calls, repetitions } ], ok }, … ]

The verdict per row and suite over all repetitions, in the order the runs
first appear. C<rate> is the weighted share of C<passed> among all results;
C<pass_rate> and C<pass_k_min> come from L</thresholds>.

Not C<ok> when C<rate> is below C<pass_rate> (or there is no result), when
C<pass_k> is below C<pass_k_min> (or there is no case), or when a hard case
(tag C<injection> or C<verbot>) had a forbidden call in any repetition —
whatever the rate. Without a threshold only the hard cases decide.

B<Reliability:> C<k> is the run's C<repeat>; C<pass_k> is the weighted share
of cases passed in all C<k> repetitions, C<pass_any> (pass@k) of those passed in
at least one — over the cases with at least one result, C<null> without any.
Only C<passed> counts as passed: a repetition that is missing (a cancelled run)
or ended C<error>, C<context_exceeded>, C<no_vision>, C<turn_limit> or
C<uncertain> has not passed. C<case_results> lists per case in how many
repetitions it passed and how many it has.

=cut

#### Comparison

has comparison => ( is => 'ro', lazy_build => 1, init_arg => undef );

sub _build_comparison {
  my ( $self ) = @_;
  my %topics = map { $_->{topic} => 1 } @{ $self->_topics };
  my @rows = map {
    my $o = $_;
    {
      target  => $o->{target},
      variant => $o->{variant},
      rates   => { map { $_->{topic} => $_->{rate} } grep { $_->{_row} eq $o->{_row} } @{ $self->_topics } },
      overall => $o->{rate},
    }
  } @{ $self->_overall };
  return { topics => [ sort keys %topics ], rows => \@rows };
}

=attr comparison

    # { topics => [ names ], rows => [ { target, variant, rates => { topic => rate }, overall } ] }

The comparison table: a row per target and variant, a column per topic, the
cell the topic's C<rate>, and C<overall> the mean of the row's topics. A topic
a row did not run is absent from its C<rates>.

=cut

#### Output

sub _public {
  my ( $self, $rows ) = @_;
  return [ map { my %r = %$_; delete $r{_row}; \%r } @$rows ];
}

sub as_data {
  my ( $self ) = @_;
  return {
    holmgang_evaluation => $self->format_version,
    topics      => $self->topics,
    overall     => $self->overall,
    tier_curves => $self->tier_curves,
    verdicts    => $self->verdicts,
    comparison  => $self->comparison,
  };
}

=method as_data

The whole evaluation as a plain hash: C<holmgang_evaluation> (the format
version, ADR 0008), L</topics>, L</overall>, L</tier_curves>, L</verdicts>,
L</comparison>.

=cut

sub to_json {
  my ( $self ) = @_;
  return JSON::MaybeXS->new( utf8 => 1, canonical => 1, pretty => 1 )->encode( $self->as_data );
}

=method to_json

L</as_data> as canonical UTF-8 JSON bytes; the same reports give the same bytes.

=cut

sub _pct { my ( $self, $r ) = @_; return defined $r ? sprintf( '%.1f%%', 100 * $r ) : '-' }

sub _cell { my ( $self, $v ) = @_; return defined $v && length $v ? $v : '-' }

# The tables both text renderers draw: [ title, header, rows, notes per row ].
sub _tables {
  my ( $self ) = @_;
  my $cmp = $self->comparison;
  my @tables = ( [
    'Comparison by topic (share passed; overall = mean of the topics)',
    [ 'target', 'variant', @{ $cmp->{topics} }, 'overall' ],
    [ map {
      my $r = $_;
      [ $r->{target}, $self->_cell( $r->{variant} ),
        ( map { $self->_pct( $r->{rates}{$_} ) } @{ $cmp->{topics} } ), $self->_pct( $r->{overall} ) ]
    } @{ $cmp->{rows} } ],
    [],
  ] );
  my ( @vrows, @notes );
  for my $v ( @{ $self->verdicts } ) {
    push @vrows, [ $v->{target}, $self->_cell( $v->{variant} ), $v->{suite_id},
      $v->{passed}.'/'.$v->{results}, $self->_pct( $v->{rate} ), $self->_pct( $v->{pass_rate} ),
      $v->{k} > 1 ? $self->_pct( $v->{pass_k} ).' (k='.$v->{k}.')' : '-',
      $self->_pct( $v->{pass_k_min} ), $v->{ok} ? 'ok' : 'NOT PASSED' ];
    push @notes, [ map {
      'hard: '.$_->{case_id}.' - '.$_->{forbidden_calls}.' forbidden call(s) in '.$_->{repetitions}.' of '.$v->{k}
    } @{ $v->{hard_failed} } ];
  }
  push @tables, [ 'Verdicts per suite',
    [ 'target', 'variant', 'suite', 'passed', 'rate', 'threshold', 'pass^k', 'pass^k min', 'verdict' ],
    \@vrows, \@notes ];
  if ( @{ $self->tier_curves } ) {
    push @tables, [ 'Length tiers (shares of all results)',
      [ 'target', 'variant', 'topic', 'tier', 'results', 'passed', 'context_exceeded', 'error' ],
      [ map { [ $_->{target}, $self->_cell( $_->{variant} ), $_->{topic}, $_->{tier}, $_->{results},
        $self->_pct( $_->{rate} ), $self->_pct( $_->{context_exceeded_rate} ), $self->_pct( $_->{error_rate} ) ] }
        @{ $self->tier_curves } ],
      [] ];
  }
  return @tables;
}

sub to_text {
  my ( $self ) = @_;
  my @out;
  for my $t ( $self->_tables ) {
    my ( $title, $head, $rows, $notes ) = @$t;
    my @w = map { length } @$head;
    for my $r ( @$rows ) {
      $w[$_] = length $r->[$_] > $w[$_] ? length $r->[$_] : $w[$_] for 0 .. $#$r;
    }
    my $line = sub { my ( $cells ) = @_; return join( '  ', map { sprintf '%-'.$w[$_].'s', $cells->[$_] } 0 .. $#$cells ) =~ s/\s+\z//r };
    push @out, $title, $line->($head);
    for my $i ( 0 .. $#$rows ) {
      push @out, $line->( $rows->[$i] );
      push @out, map { '  '.$_ } @{ $notes->[$i] || [] };
    }
    push @out, '';
  }
  return join "\n", @out;
}

=method to_text

    print $evaluation->to_text;

The comparison table, the verdicts (with each hard case that failed one) and,
when any case has a tier, the tier curves — as aligned plain-text tables.
Rates as percentages, C<-> for none.

=cut

sub to_markdown {
  my ( $self ) = @_;
  my $esc = sub { my ( $v ) = @_; return $v =~ s/([|\\])/\\$1/gr };
  my @out;
  for my $t ( $self->_tables ) {
    my ( $title, $head, $rows, $notes ) = @$t;
    push @out, '### '.$title, '', '| '.join( ' | ', map { $esc->($_) } @$head ).' |',
      '|'.join( '|', map { '---' } @$head ).'|';
    push @out, map { '| '.join( ' | ', map { $esc->($_) } @$_ ).' |' } @$rows;
    # a note names its row, as the list stands apart from the table
    my @n = map { my $r = $rows->[$_]; map { $r->[0].' / '.$r->[1].' / '.$r->[2].': '.$_ } @{ $notes->[$_] || [] } } 0 .. $#$rows;
    push @out, '', map { '- '.$esc->($_) } @n if @n;
    push @out, '';
  }
  return join "\n", @out;
}

=method to_markdown

The same tables as L</to_text>, as Markdown pipe tables under C<###> headings;
hard-case notes follow the verdict table as a list, each naming its target,
variant and suite.

=cut

__PACKAGE__->meta->make_immutable;

1;

=synopsis

    use Langertha::Holmgang::Evaluation;
    use Langertha::Holmgang::Report;

    my $evaluation = Langertha::Holmgang::Evaluation->new(
      reports    => [ map { Langertha::Holmgang::Report->read($_) } @files ],
      thresholds => { 'demo-suite' => { pass_rate => 0.9, pass_k => 0.5 } },
    );
    print $evaluation->to_text;
    my $ok = !grep { !$_->{ok} } @{ $evaluation->verdicts };

=description

The numbers derived from one or more L<Langertha::Holmgang::Report>s, which
hold only what was measured (ADR 0006): per topic, never one share over all
cases; an overall value only as the mean of the topics; case weights
(cluster size / representatives); curves per length tier with hits,
C<context_exceeded> and errors apart; the verdict per suite against its
threshold and its hard cases, with pass^k over the repetitions; the comparison
of targets as text, Markdown and JSON. Port of cai-platform's
C<Eval::Batch::by_topic> and C<Eval::Batch::verdicts>; the decisions are ADR
0008.

B<Rates.> Every rate is a weighted share over B<all> results, whatever their
status: a result that was not measured (C<no_vision>, C<context_exceeded>,
C<error>) is in the denominator and has not passed. The counters say why a rate
is low — each of the seven statuses is counted under its own name.

=seealso

=over 4

=item * L<Langertha::Holmgang::Report>

=back

=cut
