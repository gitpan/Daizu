#!/usr/bin/perl
use warnings;
use strict;

use Test::More skip_all => 'publishing jobs not implemented yet';
use Daizu;
use Daizu::Test;
use Daizu::Publish qw( create_publishing_job );

my $cms = Daizu->new($Daizu::Test::TEST_CONFIG);
create_publishing_job($cms);

# vi:ts=4 sw=4 expandtab filetype=perl
