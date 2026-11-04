requires 'perl', '5.020';

requires 'Carp';
requires 'Digest::SHA';
requires 'JSON::MaybeXS';
requires 'Langertha', '0.504';
requires 'Moose';
requires 'namespace::autoclean';
requires 'Path::Tiny';
requires 'Scalar::Util';
requires 'URI';

on test => sub {
  requires 'Test::More';
};
