package Langertha::Holmgang::Role::Simulator;
# ABSTRACT: The plugin role of a device simulator

use Moose::Role;

our $VERSION = '0.001';

requires qw( device_type run_command );

=synopsis

  package My::Sim::Switch;
  use Moose;
  use namespace::autoclean;

  with 'Langertha::Holmgang::Role::Simulator';

  sub device_type { 'switch' }

  sub run_command {
    my ( $self, $dev, $command, $ctx ) = @_;
    return ( "% Invalid input detected at '^' marker.", 0 ) unless $command eq 'show vlan';
    return ( join( "\n", map { $_->{id}.' '.$_->{name} } @{ $dev->{vlans} || [] } ), 1 );
  }

  __PACKAGE__->meta->make_immutable;

=description

A device simulator answers the general tools of a suite (C<run_command>,
C<write_file>) for every device of its C<type> in a case's state. It executes
the command B<on the state>: what it changes is visible to every later read.
L<Langertha::Holmgang::Simulators> picks the simulator by the device's C<type>
and calls the methods below; a simulator is constructed once per registry with
no arguments and must not keep anything between calls in its own attributes —
everything a call leaves behind belongs in the device state.

=head1 ARGUMENTS

Every method gets the same three things:

=over 4

=item C<$dev>

The device's state: the hash under its host name in the case's state (C<type>
plus whatever keys this simulator documents in its POD). The simulator B<may
change it> — the caller hands in a copy and keeps it afterwards. This hash is
the only thing a simulator changes.

=item C<$ctx>

The read-only call context, a hash:

  { host => 'gw-a', state => $whole_state }

C<host> is the device's host name, C<state> the whole state the device sits
in (read other devices from it, never change them).

=back

=head1 RESULT

Every call returns a list:

  return ( $output, $ok );
  return ( $output, $ok, $sim_gap );
  return ( $output, $ok, $sim_gap, $exit );

=over 4

=item C<$output>

What the real system prints, as text. No trailing newline; empty output is
C<''>.

=item C<$ok>

True when the call succeeded (exit status 0), false otherwise. A reference
solution may not contain a failed call.

=item C<$sim_gap>

Optional. C<undef> or a text naming a B<gap of the simulation>: a real command
of the device that this simulator does not model. Several gaps in one call are
joined with C<'; '>. The output of such a call is neutral — empty, or what the
real system prints without the feature (C<Error opening terminal: unknown.>) —
and never hints at a solution. What the simulated system really does not have
is not a gap: it gets the real error (C<bash: ifconfig: command not found>).

=item C<$exit>

Optional, C<run_command> only. The exit status when it is neither C<0> nor
C<1> (C<exit 3> in a script). Without it the caller takes C<0> for a success
and C<1> for a failure.

=back

=head1 RULES

=over 4

=item * Only the state. No shell-out, socket, host file or clock: the
simulator executes model output, and delegating to the host would run it for
real.

=item * Three answers, never a fourth: the modelled behaviour; the device's
real error for what it does not have; a neutral answer plus C<$sim_gap> for a
real command that is not modelled.

=item * The keys of the device state are documented in the simulator's POD; a
new key lands there in the same change.

=item * A Perl error is a bug of the simulator, never an answer. The world
guards every call anyway (L<Langertha::Holmgang::World/DESCRIPTION>): when a
simulator dies, the model gets C<Fehler: interner Fehler beim Ausführen des
Aufrufs.>, the call fails and the state stays as it was before the call; a Perl
error line in the output that names a source file of the running process is
replaced by that same text. Either way the original text goes into the call's
gap as C<simulator error: …>, for the report only — so a die shows up as a
gap, but it must still be fixed in the simulator.

=back

=head1 METHODS

=method device_type

  sub device_type { 'linux' }

Required. The value of C<type> in the device state that selects this
simulator.

=method run_command

  my ( $output, $ok, $gap, $exit ) = $sim->run_command( $dev, $command, $ctx );

Required. Runs one command line (whatever the model sent as C<command>) on the
device.

=method write_file

  my ( $output, $ok, $gap ) = $sim->write_file( $dev, $path, $content, $ctx );

Optional. Replaces the file C<$path> on the device with C<$content>. A
simulator without it refuses C<write_file> for its devices (see
L<Langertha::Holmgang::Simulators/write_file>).

=method prepare

  $sim->prepare( $dev, $ctx );

Optional. Called once on the initial state, before the first call: fills in
what the device reads from its files at boot (the running values of a
service), so that a later change of the file does not look as if it were
already in effect. Adds only what is missing; returns nothing. It may C<die>
with a message naming the broken state — the loader refuses the case then.

=method packet_verdict

  my ( $verdict, $why ) = $sim->packet_verdict( $dev, \%packet, $boot );

Optional; answers the rule kind C<packet>. What the device's packet filter does
with C<%packet> (the rule's C<packet> without C<host>): C<$verdict> is
C<accept> or C<drop>, C<$why> names the place that decided. With C<$boot> (the
rule's C<boot>: true or a file path) the verdict is the one after a reboot,
from the boot configuration. When a rule on the way cannot be evaluated,
C<$verdict> is C<undef> and C<$why> says why. For C<linux> it is
L<Langertha::Holmgang::Sim::Linux::Nft>.

=method login_check

  my ( $allowed, $client, @log ) = $sim->login_check( $dev, \%attempt, $host );

Optional; answers the rule kind C<login>. Can C<%attempt> (the rule's C<login>
without C<host>: C<user>, C<from>, C<key> …) log in to the device C<$host>?
C<$allowed> is C<1> or C<0>, C<$client> the client's message, C<@log> the
lines the daemon logs (without timestamps).

=cut

1;

=pod

=head1 REGISTRATION

A simulator outside this distribution is a class on C<@INC>, registered by
name:

  my $sims = Langertha::Holmgang::Simulators->new( register_classes => ['My::Sim::Switch'] );

L<Langertha::Holmgang::Simulators/register> loads the class, checks that it
composes this role or L<Langertha::Holmgang::Role::AnswerWorld>, and makes it
the simulator of its L</device_type>, replacing a built-in of the same type.
There is no namespace scanning. The default loader of the command line knows
only the built-in types.

=cut
