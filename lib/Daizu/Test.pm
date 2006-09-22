package Daizu::Test;
use warnings;
use strict;

use base 'Exporter';
our @EXPORT_OK = qw(
    $TEST_DB_NAME $DB_SCHEMA_FILENAME
    $TEST_REPOS_DIR $TEST_REPOS_URL
    create_database drop_database
    editor_set_file_content
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

=head1 NAME

Daizu::Test - functions for use by the test suite

=head1 DESCRIPTION

The functions defined in here are only really useful for testing Daizu CMS.
This stuff is used by the test suite, in particular C<t/00setup.t> which
creates a test database and repository.

=head1 CONSTANTS

=over

=item $TEST_DB_NAME

Name of database to use for testing.

Value: daizu_test

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

our $TEST_DB_NAME = 'daizu_test';
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

=item pg_template_dbh()

Returns a L<DBI> database handle connected to the PostgreSQL C<template1>
database, which can be used for example to create the test database.

=cut

sub pg_template_dbh
{
    return DBI->connect('dbi:Pg:dbname=template1', undef, undef,
                        { AutoCommit => 1, RaiseError => 1, PrintError => 0 });
}

=item create_database()

Create the test database, load the database schema into it, and return
a L<DBI> handle for accessing it.

=cut

sub create_database
{
    # Drop the test DB if it already exists.
    my $db = DBI->connect("dbi:Pg:dbname=$TEST_DB_NAME", undef, undef,
                          { RaiseError => 0, PrintError => 0 });
    if (defined $db) {
        undef $db;
        drop_database();
    }

    $db = pg_template_dbh();
    $db->do(qq{
        create database $TEST_DB_NAME
    });

    $db->disconnect;
    $db = DBI->connect("dbi:Pg:dbname=$TEST_DB_NAME", undef, undef,
                        { AutoCommit => 1, RaiseError => 1, PrintError => 0 });

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
    $db->do(qq{
        drop database $TEST_DB_NAME
    });
}

=item editor_set_file_content($ed, $file_baton, $content)

Send some data from C<$content> (which should be a reference to a string)
into the Subversion delta editor C<$ed>.  C<$file_baton> should be the
baton returned from the editor when you called its C<add_file> or
C<open_file> method.

=cut

sub editor_set_file_content
{
    my ($ed, $file_baton, $content) = @_;
    my $handle = $ed->apply_textdelta($file_baton, undef);
    die "bad textdelta handle" unless $handle && $#$handle > 0;
    my $fh = IO::Scalar->new(\$content);
    SVN::TxDelta::send_stream($fh, @$handle);
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

=head1 COPYRIGHT

This software is copyright 2006 Geoff Richards E<lt>geoff@laxan.comE<gt>.
For licensing information see this page:

L<http://www.daizucms.org/license/>

=cut

1;
# vi:ts=4 sw=4 expandtab
