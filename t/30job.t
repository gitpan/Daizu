#!/usr/bin/perl
use warnings;
use strict;

use Test::More;
use Daizu;
use Daizu::Test qw( init_tests );
use Daizu::Publish qw( create_publishing_job );

init_tests(undef);
plan skip_all => 'publishing jobs not implemented yet';

my $cms = Daizu->new($Daizu::Test::TEST_CONFIG);
create_publishing_job($cms);

# vi:ts=4 sw=4 expandtab filetype=perl
