requires 'perl', '5.020';

requires 'Carp';
requires 'Digest::SHA';
requires 'Encode';
requires 'Future';
requires 'JSON::MaybeXS';
requires 'Langertha', '0.504';
requires 'Module::Runtime';
requires 'Moose';
requires 'namespace::autoclean';
requires 'Path::Tiny';
requires 'Scalar::Util';
requires 'Time::Local';
requires 'URI';
requires 'YAML::XS';

on test => sub {
  requires 'Test::Fatal';
  requires 'Test::More';
};
