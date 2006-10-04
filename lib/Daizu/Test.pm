package Daizu::Test;
use warnings;
use strict;

use base 'Exporter';
our @EXPORT_OK = qw(
    $TEST_DBCONF_FILENAME $DB_SCHEMA_FILENAME
    $TEST_REPOS_DIR $TEST_REPOS_URL
    init_tests test_config
    create_database drop_database
    create_test_repos
);

use Path::Class qw( file dir );
use DBI;
use IO::Scalar;
use File::Path qw( rmtree );
use SVN::Core;
use SVN::Ra;
use SVN::Repos;
use SVN::Delta;
use Carp qw( croak );
use Carp::Assert qw( assert DEBUG );
use Test::More;

=head1 NAME

Daizu::Test - functions for use by the test suite

=head1 DESCRIPTION

The functions defined in here are only really useful for testing Daizu CMS.
This stuff is used by the test suite, in particular C<t/00setup.t> which
creates a test database and repository.

=head1 CONSTANTS

=over

=item $TEST_DBCONF_FILENAME

Name of configuration file which provides information about how to connect
to the databases used for the test suite.  The C<test_config> function
parses this.

Value: I<test.conf>

=item $DB_SCHEMA_FILENAME

Name of the SQL file containing the database schema to load into the
test database after creating it.

Value: db.sql

=item $TEST_REPOS_DIR

Full path to the directory which should contain the testing repository
created at the start of running the tests.

Value: I<.test-repos> in the current directory

=item $TEST_REPOS_URL

A 'file' URL to the test repository.

=item $TEST_REPOS_DUMP

Full path to the Subversion dump file which is loaded into the
test repository.

Value: I<test-repos.dump> in the current directory.

=item $TEST_DOCROOT_DIR

Full path to the directory into which output from publishing test
content should be written.

Value: I<.test-docroot> in the current directory

=item $TEST_CONFIG

Filename of config file to use for testing.

Value: I<test-config.xml> (which is created from I<test-config.xml.tmpl>
by I<t/00setup.t>)

=back

=cut

our $TEST_DBCONF_FILENAME = file('test.conf')->absolute->stringify;
our $DB_SCHEMA_FILENAME = 'db.sql';
our $TEST_REPOS_DIR = dir('.test-repos')->absolute->stringify;
our $TEST_REPOS_URL = "file://$TEST_REPOS_DIR";
our $TEST_REPOS_DUMP = file('test-repos.dump')->absolute->stringify;
our $TEST_DOCROOT_DIR = dir('.test-docroot')->absolute->stringify;
our $TEST_CONFIG = 'test-config.xml';

=head1 FUNCTIONS

The following functions are available for export from this module.
None of them are exported by default.

=over

=item init_tests($num_tests, [$show_errors])

Load the test configuration file (which will allow you to use
the L<test_config()|/test_config()> function later), and check it to make sure
the tests are properly configured.  If they are then initialize L<Test::More>
with the number of tests expected (unless C<$num_tests> is undef).
Otherwise tell Test::More to skip all the tests.

If C<$show_errors> is present and true, display warnings about any problems
with the test configuration file.  This should be done in the first test
program so that the user knows why the tests aren't being run.  The others
can just skip the tests.

=item test_config()

Return a reference to a hash of configuration values from the
file specified by L<$TEST_DBCONF_FILENAME|/$TEST_DBCONF_FILENAME>.
This will fail if L<init_tests()|/init_tests($num_tests, [$show_errors])>
hasn't been run yet.

=cut

{
    my $test_config;

    sub init_tests
    {
        my ($num_tests, $show_errors) = @_;
        my $errors = '';

        open my $fh, '<', $TEST_DBCONF_FILENAME
            or die "$0: error opening 'TEST_DBCONF_FILENAME': $!\n";

        my %config;
        while (<$fh>) {
            next unless /\S/;
            next if /^\s*#/;
            chomp;
            my ($key, $value) = split ' ', $_, 2;
            $errors .= "$TEST_DBCONF_FILENAME:$.: duplicate value for '$key'\n"
                if exists $config{$key};
            $errors .= "$TEST_DBCONF_FILENAME:$.: value missing for '$key'\n"
                if !defined $value || $value eq '';
            $config{$key} = $value;
        }

        $errors .= "$0: you need to edit the file '$TEST_DBCONF_FILENAME'" .
                   " before you can run the test suite, to configure how the" .
                   " tests should access your PostgreSQL server.\n"
            if $config{'not-configured'};

        for (qw( template-dsn test-dsn )) {
            $errors .= "$0: configuration file '$TEST_DBCONF_FILENAME' must" .
                       " contain a value called '$_' for the test suite to" .
                       " work.\n"
                 unless $config{$_};
        }

        if ($errors ne '') {
            warn "\n\n$errors\n" if $show_errors;
            plan skip_all => "Tests not configured in '$TEST_DBCONF_FILENAME'";
        }
        else {
            plan tests => $num_tests
                if defined $num_tests;
        }

        $test_config = \%config;
    }

    sub test_config
    {
        croak "can't call 'test_config' until you've called 'init_tests'"
            unless defined $test_config;
        return $test_config;
    }
}

=item pg_template_dbh()

Returns a L<DBI> database handle connected to the PostgreSQL C<template1>
database, which can be used for example to create the test database.

=cut

sub pg_template_dbh
{
    my $config = test_config();
    return DBI->connect(
        $config->{'template-dsn'}, $config->{'template-user'},
        $config->{'template-password'},
        { AutoCommit => 1, RaiseError => 1, PrintError => 0 },
    );
}

=item create_database()

Create the test database, load the database schema into it, and return
a L<DBI> handle for accessing it.

=cut

sub create_database
{
    # Drop the test DB if it already exists.
    my $config = test_config();
    my $db = DBI->connect(
        $config->{'test-dsn'}, $config->{'test-user'},
        $config->{'test-password'},
        { RaiseError => 0, PrintError => 0 },
    );
    if (defined $db) {
        undef $db;
        drop_database();
    }

    $db = pg_template_dbh();
    my $db_name = _test_db_name();
    $db->do(qq{
        create database $db_name
    });

    $db->disconnect;
    $db = DBI->connect(
        $config->{'test-dsn'}, $config->{'test-user'},
        $config->{'test-password'},
        { AutoCommit => 1, RaiseError => 1, PrintError => 0 },
    );

    # Turn off warnings while loading the schema.  This silences the 'NOTICE'
    # messages about which indexes PostgreSQL is creating, which aren't
    # very interesting.
    local $db->{PrintWarn};

    open my $schema, '<', $DB_SCHEMA_FILENAME
        or die "error opening DB schema '$DB_SCHEMA_FILENAME': $!";
    my $sql = '';
    while (<$schema>) {
        next unless /\S/;
        next if /^\s*--/;
        $sql .= $_;
        if (/;$/) {
            eval { $db->do($sql) };
            die "Error executing statement:\n$sql:\n$@"
                if $@;
            $sql = '';
        }
    }

    croak "error in '$DB_SCHEMA_FILENAME': last statement should end with ';'"
        if $sql ne '';

    return $db;
}

=item drop_database()

Delete the test database.  Sleeps for a second before doing so, to give
the connections a chance to really get cleaned up.

=cut

sub drop_database
{
    my $db = pg_template_dbh();
    sleep 1;    # Wait until we're properly disconnected.

    my $db_name = _test_db_name();
    $db->do(qq{
        drop database $db_name
    });
}

=item create_test_repos()

Create an empty Subversion repository for testing, in C<$TEST_REPOS_DIR>.

=cut

sub create_test_repos
{
    rmtree($TEST_REPOS_DIR)
        if -e $TEST_REPOS_DIR;
    SVN::Repos::create($TEST_REPOS_DIR, undef, undef, undef, undef);
    system("svnadmin load --quiet $TEST_REPOS_DIR <$TEST_REPOS_DUMP");
    my $ra = SVN::Ra->new(url => $TEST_REPOS_URL);
    assert($ra->get_latest_revnum > 0);     # confirm undump worked
    return $ra;
}

=back

=cut

sub _test_db_name
{
    my $config = test_config();
    my $test_dsn = $config->{'test-dsn'};
    die "$0: can't extract 'dbname' part from test DSN '$test_dsn' in order" .
        " to drop the test database\n"
        unless $test_dsn =~ /\bdbname=(\w+)\b/i;
    return "$1";
}

=head1 COPYRIGHT

This software is copyright 2006 Geoff Richards E<lt>geoff@laxan.comE<gt>.
For licensing information see this page:

L<http://www.daizucms.org/license/>

=cut

1;
# vi:ts=4 sw=4 expandtab
