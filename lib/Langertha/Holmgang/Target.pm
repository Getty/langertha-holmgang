package Langertha::Holmgang::Target;
# ABSTRACT: A Langertha engine as a benchmark target: variant settings, one model turn, failed turns classified

use Moose;
use namespace::autoclean;
use Carp qw( croak );
use Future;
use Langertha::Role::HTTP ();
use Scalar::Util qw( blessed );

our $VERSION = '0.001';

=synopsis

  use Langertha::Holmgang::Target;
  use Langertha::Engine::Virtual;
  use Langertha::Virtual::Rules qw( answer error );

  my $target = Langertha::Holmgang::Target->new(
    engine  => Langertha::Engine::Virtual->new( rules => [ qr/./ => answer('done') ] ),
    variant => { max_tokens => 4000 },     # chat_f options, passed through unchecked
  );

  my $turn = $target->chat_turn_f(
    messages    => [ { role => 'user', content => 'Fix the route on gw-a.' } ],
    tools       => \@tool_schemas,
    temperature => 0,
  )->get;

  if ( defined $turn->{error_class} ) {
    # 'no_vision', 'context_exceeded' or 'error' -- the case ends with that status
    warn $turn->{error};
  }
  else {
    my $response = $turn->{response};      # Langertha::Response
  }

=description

A target is what a run measures (C<CONTEXT.md>): one Langertha engine -- any
engine, L<Langertha::Engine::Virtual> in tests -- plus the settings of the
variant under which it runs. The runner asks it for one model turn at a
time and gets a normalised result back: either the engine's
L<Langertha::Response>, or the error text and its class.

The class decides the case status of ADR 0006 when the target did not answer:
C<no_vision> (the target cannot see an image of the case), C<context_exceeded>
(the request does not fit its context window) or C<error> (any other failure).
Langertha has no structured request failure yet, only the text of the croak
(C<< <class> request failed: <status line> - <body> >>), so the class is read
off that text with the signatures of the common servers; see
L</classify_error>.

=cut

has engine => (
  is       => 'ro',
  required => 1,
);

=attr engine

Required. The Langertha engine the turns go to -- any object with C<chat_f>
(L<Langertha::Role::Chat>). Its own attributes (model, url, system prompt,
engine-level controls) stay as they are; the target never changes it.

=cut

has variant => (
  is      => 'ro',
  default => sub { {} },
);

=attr variant

Optional, default C<{}>. The variant's settings as C<chat_f> options
(C<max_tokens>, C<temperature>, C<reasoning_effort>, C<chat_template_kwargs>
...). They are added to every turn and win over the turn's own options of the
same name, as cai-platform's variant C<max_tokens> beats the case's. A plain
HashRef, passed through unchecked.

=cut

sub BUILD {
  my ( $self ) = @_;
  croak __PACKAGE__.'->new: engine must be a Langertha engine with chat_f'
    unless blessed $self->engine && $self->engine->can('chat_f');
  croak __PACKAGE__.'->new: variant must be a HashRef'
    unless ref $self->variant eq 'HASH';
  return;
}

# How much of an error body Langertha keeps in its croak while a turn runs.
# Its default ($Langertha::Role::HTTP::error_body_max_length, 500 characters)
# can cut a signature off a long body (a provider error with a long preamble).
sub error_body_max_length { 65536 }

=method error_body_max_length

  Langertha::Holmgang::Target->error_body_max_length;   # 65536

How many characters of a failed response's body the error text keeps, at
least. Langertha cuts the body in its croak at
C<$Langertha::Role::HTTP::error_body_max_length> (500); L</chat_turn_f>
raises that to this value with C<local> for the duration of the call (a
higher value already set stays). B<Limit:> the C<local> covers the
synchronous transports -- L<Langertha::Engine::Virtual> and the LWP fallback
without C<Net::Async::HTTP>, where the request and its croak happen inside
the call. With a real event loop the croak happens later, outside the
C<local>, and the body is cut at Langertha's limit again; signatures in the
first 500 characters are still found. An uncut body is a Langertha gap.

=cut

#### Signatures

# A target that cannot take an image (k27): llama.cpp without an mmproj
# ("image input is not supported - hint: ... provide the mmproj"), vLLM
# ("... is not a multimodal model").
my $NO_VISION_RE = qr{
    image \s+ input \s+ is \s+ not \s+ supported
  | not \s+ a \s+ multimodal \s+ model
}xi;

# The request exceeds the context window -- cai-platform's $CONTEXT_RE
# (Eval::Runner, af7561a5), unchanged: OpenAI, vLLM, llama.cpp, SGLang, TGI,
# LiteLLM, Ollama, Anthropic, and the generic "context window" phrasing.
my $CONTEXT_RE = qr{
    context_length_exceeded | exceed_context_size | ContextWindowExceeded
  | maximum \s+ context \s+ length | maximum \s+ model \s+ length | max_model_len
  | exceeds? \s+ the \s+ (?:available \s+)? context \s+ (?:size|length|window)
  | longer \s+ than \s+ the \s+ model'?s? \s+ context \s+ length
  | tokens \s* \+ \s* `?max_new_tokens`? \s+ must \s+ be \s+ <=
  | context \s+ window \s+ (?:exceeded|is \s+ too \s+ small)
  | prompt \s+ is \s+ too \s+ long
}xi;

sub classify_error {
  my ( $self, $text ) = @_;
  return 'error' unless defined $text && length $text;
  return $text =~ $NO_VISION_RE ? 'no_vision'
       : $text =~ $CONTEXT_RE   ? 'context_exceeded'
       :                          'error';
}

=method classify_error

  $target->classify_error($error_text);   # 'no_vision' | 'context_exceeded' | 'error'

The class of a failed turn from its error text (also callable on the class).
Only ever asked for a turn that failed: a response that merely mentions one
of the phrases is a response, never one of these classes.

The first that matches wins, in the order of ADR 0006:

=over

=item * C<no_vision> -- llama.cpp without a projector ("image input is not
supported ... mmproj"), vLLM ("is not a multimodal model").

=item * C<context_exceeded> -- OpenAI (C<context_length_exceeded>), vLLM
("maximum context length", "longer than the maximum model length",
C<max_model_len>), llama.cpp (C<exceed_context_size_error>, "exceeds the
available context size"), SGLang ("longer than the model's context length"),
TGI ("C<inputs> tokens + C<max_new_tokens> must be <= N"), LiteLLM
(C<ContextWindowExceededError>), Ollama ("input length exceeds the context
length"), Anthropic ("prompt is too long"), and "context window exceeded" /
"is too small". The expression is cai-platform's C<$CONTEXT_RE> unchanged.

=item * C<error> -- everything else, an empty text included: a 500 without a
hint, a timeout, a refused connection, a croak before the request.

=back

=cut

#### Scrubbing

# Query parameters and header/JSON fields whose value is a credential.
my $SECRET_PARAM = qr{ (?: api[_-]?key | key | access[_-]?token | token | auth | secret | password | passwd | sig | signature ) }xi;
my $AUTH_SCHEME  = qr{ (?: Bearer | Basic | Token | Digest ) \s+ }xi;
# What ends a value in a header, a query or a JSON string.
my $VALUE = qr{ [^\s"',;&#]+ }x;
# A path segment: anything but whitespace, a slash and the usual delimiters.
my $SEG = qr{ [^\s/\\"'<>:,;()\[\]{}]+ }x;

# A die or warn location: " at FILE line N", with the line of the last read
# handle (", <FH> line N" or "chunk N") when Perl adds one; FILE is $1. The one
# rule of the dist (k42): World builds its Perl-error line from it, World and
# Structure cut a trailing one with it (k44), the CLI
# cuts relayed errors and warnings with _strip_location (k41).
our $LOCATION = qr/ at (\S+) line \d+(?:, <[^>]*> (?:line|chunk) \d+)?/;

# die and Carp locations anywhere, the closing dot optional ("called at" lines have none)
sub _strip_location { my ( $class, $text ) = @_; return $text =~ s/$LOCATION\.?//gr }

sub scrub {
  my ( $self, $text ) = @_;
  return $text unless defined $text;
  # the engine's own key, of whatever shape (cai-platform ModelTester::scrub)
  if ( ref $self ) {
    my $engine = $self->engine;
    my $key = $engine->can('api_key') ? eval { $engine->api_key } : undef;
    $text =~ s/\Q$key\E/***/g if defined $key && !ref $key && length $key >= 4;
  }
  $text = $self->_strip_location($text);
  # credentials in URLs: userinfo and secret query parameters
  $text =~ s{ ( \b [a-z][a-z0-9+.-]* :// ) [^/\s\@"']+ \@ }{$1***\@}gxi;
  $text =~ s{ ( [?&;] $SECRET_PARAM = ) $VALUE }{$1***}gx;
  # credentials in headers and JSON fields
  $text =~ s{ \b ( Authorization ["']? \s* [:=] \s* ["']? $AUTH_SCHEME? ) $VALUE }{$1***}gxi;
  $text =~ s{ \b ( Bearer \s+ ) (?!\*\*\*) $VALUE }{$1***}gxi;
  $text =~ s{ \b ( (?: x- (?: goog- )? )? api[_-]?key ["']? \s* [:=] \s* ["']? ) $VALUE }{$1***}gxi;
  # key shapes of the common providers
  $text =~ s{ \b (?: sk | pplx | gsk | xai | hf ) [-_] [A-Za-z0-9_-]{16,} }{***}gx;
  $text =~ s{ \b AIza [0-9A-Za-z_-]{30,} }{***}gx;
  # absolute host paths: Unix (two segments at least, not inside a URL), home, Windows
  $text =~ s{ (?<! [\w.:/~\\\@-] ) (?: ~ | [A-Za-z]: )? [/\\] (?: $SEG [/\\] )+ $SEG }{<path>}gx;
  return $text;
}

=method scrub

  my $clean = $target->scrub($text);    # also callable on the class, without the key

The text of a failed turn with what must not leave the run removed (ADR
0006: "error texts pass the engine's scrubbing first" -- Langertha has no
scrubber of its own, so the target does it). L</chat_turn_f> scrubs its C<error>; the
class of the failure is read off the raw text before. What goes:

=over

=item * the engine's own C<api_key> (4 characters and up), wherever it stands
-- C<***>; only on an object, the class knows no key;

=item * die and Carp locations (C<at FILE line N.>, C<called at ...>, with
C<< , <FH> line N >> when Perl adds it), dropped;

=item * URL credentials: the userinfo (C<https://***@host/...>) and the value
of a query parameter named C<key>, C<api_key>, C<access_token>, C<token>,
C<auth>, C<secret>, C<password>, C<sig>, C<signature> -- C<***>, the rest of
the URL stays;

=item * header and JSON field values: C<Authorization> (after its scheme),
C<Bearer> tokens, C<x-api-key>, C<x-goog-api-key>, C<api_key>/C<api-key> --
C<***>;

=item * key shapes of the common providers (C<sk->, C<pplx->, C<gsk_>,
C<xai->, C<hf_> with 16 characters and up, C<AIza...>) -- C<***>;

=item * absolute host paths (C</a/b>, C<~/a>, C<C:\a\b>; not the path of a
URL, not a single segment) -- C<< <path> >>.

=back

The status line, the provider's reason and the URL's host and path stay
readable. This is a net for what Langertha's error text can carry, not a
proof: a credential the engine does not hold and that has none of these
shapes passes.

=cut

#### The turn

sub chat_turn_f {
  my ( $self, %opts ) = @_;
  my $f;
  {
    my $max = $self->error_body_max_length;
    local $Langertha::Role::HTTP::error_body_max_length =
      $Langertha::Role::HTTP::error_body_max_length > $max ? $Langertha::Role::HTTP::error_body_max_length : $max;
    $f = eval { $self->engine->chat_f( %opts, %{ $self->variant } ) };
    $f = Future->fail( $@ || ref( $self->engine ).'->chat_f returned no Future' )
      unless blessed $f && $f->isa('Future');
  }
  return $f->then(
    sub {
      my ( $response ) = @_;
      return Future->done( { response => $response, error => undef, error_class => undef } );
    },
    sub {
      my ( $failure ) = @_;
      my $text = defined $failure ? "$failure" : '';
      $text =~ s/\s+\z//;
      # classified on the raw text, scrubbed before it leaves (k38)
      my $class = $self->classify_error($text);
      return Future->done( { response => undef, error => $self->scrub($text), error_class => $class } );
    },
  );
}

=method chat_turn_f

  my $turn = await $target->chat_turn_f(
    messages => \@messages,      # system prompt included as the runner builds it
    tools    => \@tools,         # the suite's tool schemas
    %controls,                   # temperature, max_tokens, seed, ...
  );

One model turn: the options go to the engine's C<chat_f> unchanged, with the
L</variant> settings added on top. Returns a L<Future> that is always
B<done> -- a failed request is a result, not a failed Future -- with a
HashRef:

=over

=item * C<response> -- the L<Langertha::Response> of a turn that succeeded,
C<undef> otherwise. Usage, finish reason, tool calls and timing are read from
it.

=item * C<error> -- the error text of a failed turn (Langertha's croak,
without the trailing whitespace, through L</scrub>), C<undef> otherwise.

=item * C<error_class> -- C<undef> for a turn that succeeded, else
C<no_vision>, C<context_exceeded> or C<error> (L</classify_error>); the
runner ends the case with that status.

=back

Anything C<chat_f> throws or fails with counts as a failed turn, including
a croak before the request (a capability exclusion, a malformed tool). What
the model may see is the caller's business: the target strips nothing, so
the runner hands it messages and tools without state, rules or C<untrusted>
marks. The error body is kept up to L</error_body_max_length> characters (see
there for the limit under a real event loop).

=cut

__PACKAGE__->meta->make_immutable;

1;
