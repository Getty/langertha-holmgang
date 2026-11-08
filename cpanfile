requires 'perl', '5.020';

requires 'Carp';
requires 'Digest::MD5';
requires 'Digest::SHA';
requires 'Encode';
requires 'Exporter';
requires 'File::ShareDir';
requires 'Future';
requires 'Future::AsyncAwait';
requires 'Getopt::Long';
requires 'IO::Compress::Gzip';
requires 'IO::Uncompress::Gunzip';
requires 'JSON::MaybeXS';
requires 'Langertha', '0.504';
requires 'MIME::Base64';
requires 'Module::Runtime';
requires 'Moose';
requires 'namespace::autoclean';
requires 'Path::Tiny';
requires 'POSIX';
requires 'Scalar::Util';
requires 'Socket';
requires 'Text::Xslate';
requires 'Time::HiRes';
requires 'Time::Local';
requires 'URI';
requires 'YAML::XS';

on test => sub {
  requires 'File::Find';
  requires 'File::Spec';
  requires 'FindBin';
  requires 'IPC::Open3';
  requires 'Storable';
  requires 'Test::Fatal';
  requires 'Test::More';
};
