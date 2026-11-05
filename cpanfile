requires 'perl', '5.020';

requires 'Carp';
requires 'Digest::SHA';
requires 'Encode';
requires 'Exporter';
requires 'Future';
requires 'Future::AsyncAwait';
requires 'Getopt::Long';
requires 'JSON::MaybeXS';
requires 'Langertha', '0.504';
requires 'Module::Runtime';
requires 'Moose';
requires 'namespace::autoclean';
requires 'Path::Tiny';
requires 'Scalar::Util';
requires 'Text::Xslate';
requires 'Time::HiRes';
requires 'Time::Local';
requires 'URI';
requires 'YAML::XS';

on test => sub {
  requires 'IPC::Open3';
  requires 'Test::Fatal';
  requires 'Test::More';
};
