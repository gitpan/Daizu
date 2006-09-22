use warnings;
use strict;

use Test::More tests => 1;
use Path::Class qw( file );
use Carp::Assert qw( assert );
use Daizu::Test qw(
    create_test_repos create_database
);
use Daizu::Util qw( db_insert );

my $ra = create_test_repos();
assert($ra);

my $db = create_database();
assert($db);

# Add people to the database, for usernames used in the test repository.
db_insert($db, 'person', id => 1, username => 'geoff');
db_insert($db, 'person_info',
    person_id => 1,
    path => '',
    name => 'Geoff Richards',
    email => 'geoff@daizucms.org',
    uri => 'http://www.laxan.com/',
);

db_insert($db, 'person', id => 2, username => 'alice');
db_insert($db, 'person_info',
    person_id => 2,
    path => 'foo.com',
    name => 'Alice Foonly',
);
db_insert($db, 'person_info',
    person_id => 2,
    path => 'example.com',
    name => 'Alice Anonym',
);

db_insert($db, 'person', id => 3, username => 'bob');
db_insert($db, 'person_info',
    person_id => 3,
    path => '',
    name => 'bob',
    email => 'bob@daizucms.org',
);

# Create the config file to use from the template.
{
    open my $tmpl_file, '<', 'test-config.xml.tmpl'
        or die "error opening test config template file: $!";
    my $config = do { local $/; <$tmpl_file> };

    $config =~ s/\@TEST_REPOS_URL\@/$Daizu::Test::TEST_REPOS_URL/g;
    $config =~ s/\@TEST_DOCROOT_DIR\@/$Daizu::Test::TEST_DOCROOT_DIR/g;

    open my $config_file, '>', 'test-config.xml'
        or die "error opening test config file: $!";
    print $config_file $config or die $!;
    close $config_file or die $!;
}

ok(1, 'set up test database and repository');

# vi:ts=4 sw=4 expandtab filetype=perl
