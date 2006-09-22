package Daizu::Util;
use warnings;
use strict;

use base 'Exporter';
our @EXPORT_OK = qw(
    trim trim_with_empty_null like_escape pgregex_escape url_encode url_decode
    validate_number validate_uri validate_mime_type
    validate_date w3c_datetime db_datetime rfc2822_datetime parse_db_datetime
    display_byte_size
    db_row_exists db_row_id db_select db_select_col
    db_insert db_update db_replace db_delete
    wc_file_data guess_mime_type wc_set_file_data mint_guid
    guid_first_last_times
    load_class instantiate_generator
    update_all_file_urls
    add_xml_elem xml_attr xml_croak
    branch_id daizu_data_dir
);

use Data::Validate::URI qw( is_uri );
use URI;
use DateTime;
use DateTime::Format::Pg;
use DBD::Pg;
use File::MMagic;
use Path::Class qw( file );
use Digest::SHA1 qw( sha1_base64 );
use Image::Size qw( imgsize );
use Math::Round qw( nearest );
use Encode qw( encode decode );
use Carp qw( croak );
use Carp::Assert qw( assert DEBUG );

=head1 NAME

Daizu::Util - various utility functions

=head1 FUNCTIONS

The following functions are available for export from this module.
None of them are exported by default.

=over

=item trim($s)

Returns C<$s> with leading and trailing whitespace stripped off,
or C<undef> if C<$s> is undefined.

=cut

sub trim
{
    my ($s) = @_;
    return unless defined $s;
    $s =~ s/^\s+//;
    $s =~ s/\s+\z//;
    return $s;
}

=item trim_with_empty_null($s)

Returns C<$s> with leading and trailing whitespace stripped off,
or C<undef> if C<$s> is undefined, or if C<$s> contains nothing but
whitespace.

Useful for tidying values which are to be stored in the database,
where sometimes it is preferable to store C<NULL> in place of a
value with no real content.

=cut

sub trim_with_empty_null
{
    my ($s) = @_;
    return unless defined $s;
    $s =~ s/^\s+//;
    return if $s eq '';
    $s =~ s/\s+\z//;
    return $s;
}

=item like_escape($s)

Returns an escaped version of C<$s> suitable for including in patterns
given to the SQL C<LIKE> operator.  Does NOT escape quotes, so you still
need to quote the result for the database before including it in any SQL.

Returns C<undef> if the input is undefined.

Escapes backslashes, underscores, and percent signs.

=cut

sub like_escape
{
    my ($s) = @_;
    return unless defined $s;
    $s =~ s/([\\_%])/\\$1/g;
    return $s;
}

=item pgregex_escape($s)

Returns an escaped version of C<$s> suitable for including in patterns
given to PostgreSQL's SQL S<C<~> operator>.  Does NOT escape quotes, so you
still need to quote the result for the database before including it in any SQL.

Returns C<undef> if the input is undefined.

Escapes the following characters:
C<. ^ $ + * ? ( ) [ ] { \>

=cut

sub pgregex_escape
{
    my ($s) = @_;
    return unless defined $s;
    $s =~ s/([.^\$+*?()\[\]{\\])/\\$1/g;
    return $s;
}

=item url_encode($s)

Returns a URL encoded version of C<$s>, with characters which would be
unsuitable for use in a URL escaped as C<%> followed by two uppercase
hexadecimal digits.  The opposite of L<url_decode()|/url_decode($s)>.

=cut

sub url_encode
{
    my ($s) = @_;
    $s = encode('UTF-8', $s, Encode::FB_CROAK);

    $s =~ s{([^-.,/_a-zA-Z0-9 ])}{sprintf('%%%02X', ord $1)}ge;
    $s =~ tr/ /+/;

    return decode('UTF-8', $s, Encode::FB_CROAK);
}

=item url_decode($s)

If C<$s> is URL encoded, return a decoded version.  The opposite
of L<url_encode()|/url_encode($s)>.

=cut

sub url_decode
{
    my ($s) = @_;
    $s = encode('UTF-8', $s, Encode::FB_CROAK);

    $s =~ tr/+/ /;
    $s =~ s/%([\da-fA-F]{2})/chr hex $1/eg;

    return decode('UTF-8', $s, Encode::FB_CROAK);
}

=item validate_number($num)

If C<$num> consists only of a sequence of digits, return it as an
untainted number, otherwise return nothing.

=cut

sub validate_number
{
    my ($num) = @_;
    return unless $num =~ /\A(\d+)\z/;
    return $1;
}

=item validate_uri($uri)

Return a L<URI> object representing C<$uri>, or C<undef> if it isn't defined
or if it is invalid.

=cut

sub validate_uri
{
    my ($uri) = @_;
    $uri = trim($uri);
    return unless defined is_uri($uri);

    return URI->new($uri);
}

=item validate_mime_type($mime_type)

Given something that might be a MIME type name, return either a valid
MIME type, folded to lowercase, or C<undef>.

Based on the definition from
S<RFC 2045> (see L<http://www.faqs.org/rfcs/rfc2045.html>).

=cut

sub validate_mime_type
{
    my ($s) = @_;
    return unless defined $s;
    return unless $s =~ m{
        \A (
        [-!#$%&'*+.0-9A-Z^_`a-z{|}~]+
        \/
        [-!#$%&'*+.0-9A-Z^_`a-z{|}~]+
        )\z
    }x;
    return lc $1;
}

=item validate_date($date)

Given something that might be a valid date/time in Subversion format,
return a L<DateTime> object containing the same timestamp.  Otherwise
returns C<undef>.

The date format recognized is one possible format for
W3CDTF (L<http://www.w3.org/TR/NOTE-datetime>) dates.
Only the exact format used by Subversion is supported, except that:
the 'T' and 'Z' letters are case-insensitive, whitespace at the
start of end of the string is ignored, and the fractional seconds part
is optional.

Note: it would have been nice to use L<DateTime::Format::W3CDTF> for this,
but as of S<version 0.04> it has a bug which prevents parsing of Subversion
dates (CPAN bug #14179, L<http://rt.cpan.org/Public/Bug/Display.html?id=14179>).

=cut

sub validate_date
{
    my ($s) = @_;
    return unless defined $s;
    return unless $s =~ m{
        ^\s*
        (\d\d\d\d)-(\d\d)-(\d\d)
        T
        (\d\d):(\d\d):(\d\d)(\.\d+)?
        Z
        \s*$
    }ix;
    return DateTime->new(
        year => $1,
        month => $2,
        day => $3,
        hour => $4,
        minute => $5,
        second => $6,
        (defined $7 ? (nanosecond => $7 * 1_000_000_000) : ()),
        time_zone => 'UTC',
    );
}

=item w3c_datetime($datetime, $include_micro)

Return a string version of the L<DateTime> object, formatted as a
W3CDTF (L<http://www.w3.org/TR/NOTE-datetime>) date and time.  If C<$datetime>
is just a string, it is automatically validated and parsed by
L<validate_date()|/validate_date($date)> first.  If the value is invalid
or undefined, then C<undef> is returned.

C<$include_micro> indicates whether microseconds should be included in
the returned string.  If true, a decimal point and six digits of fractional
seconds is included, unless they would all be zero, otherwise the value
will be accurate only to within a second.

=cut

sub w3c_datetime
{
    my ($dt, $include_micro) = @_;
    $dt = validate_date($dt) unless ref $dt;
    return undef unless defined $dt;
    $include_micro = 0 if $include_micro && $dt->nanosecond == 0;
    return $dt->strftime('%FT%T' . ($include_micro ? '.%6NZ' : 'Z'));
}

=item db_datetime($datetime)

C<$datetime> must either be a L<DateTime> object or a string which can be
parsed by L<validate_date()|/validate_date($date)>.  If not, C<undef> is
returned.

If valid, the date and time are returned formatted for use in PostgreSQL,
using L<DateTime::Format::Pg>.

=cut

sub db_datetime
{
    my ($dt) = @_;
    $dt = validate_date($dt) unless ref $dt;
    return undef unless defined $dt;
    return DateTime::Format::Pg->format_datetime($dt);
}

=item rfc2822_datetime($datetime)

C<$datetime> must either be a L<DateTime> object or a string which can be
parsed by L<validate_date()|/validate_date($date)>.  If not, C<undef> is
returned.

If valid, the date and time are returned formatted for according to
S<RFC 2822> (L<http://www.faqs.org/rfcs/rfc2822.html>), and is suitable
for use in (for example) S<RSS 2.0> feeds.

=cut

sub rfc2822_datetime
{
    my ($dt) = @_;
    $dt = validate_date($dt) unless ref $dt;
    return undef unless defined $dt;
    return $dt->strftime('%a, %d %b %Y %H:%M:%S %z');
}

=item parse_db_datetime($datetime)

Given a string containing a date and time formatted in PostgreSQL's format,
return a corresponding L<DateTime> object.  Returns C<undef> if C<$datetime>
isn't defined.

=cut

sub parse_db_datetime
{
    my ($dt) = @_;
    return undef unless defined $dt;
    return DateTime::Format::Pg->parse_datetime($dt);
}

=item display_byte_size($bytes)

Given a number of bytes, format it for display to a user with a suffix
indicating the units (either C<b>, C<Kb>, C<Mb>, or C<Gb>, depending how
big the value is).

=cut

{
    use constant K => 1024;
    use constant M => K * K;
    use constant G => M * K;

    sub display_byte_size
    {
        my ($bytes) = @_;

        return "${bytes}b"
            if $bytes < K;
        return nearest(1, $bytes / K) . 'Kb'
            if $bytes < M;
        return nearest(0.1, $bytes / M) . 'Mb'
            if $bytes < G;
        return nearest(0.01, $bytes / G) . 'Gb';
    }
}

# Used by some of the database utility functions to generate SQL 'where'
# clauses.
# Warning: don't use this when values might contain arbitrary binary data.
sub _where
{
    my $db = shift;
    return '' unless @_;

    return 'where id = ' . $db->quote(@_) if @_ == 1;

    my %condition = @_;
    return 'where ' . join ' and ',
                      map {
                          my $value = $condition{$_};
                          defined $value ? "$_ = " . $db->quote($value)
                                         : "$_ is null";
                      }
                      keys %condition;
}

=item db_row_exists($db, $table, ...)

Return true if a row exists in database table C<$table> on database connection
C<$db>, otherwise false.

The extra arguments can be omitted (in which case the table merely has to
be non-empty), can be a single value (which will be matched against the
C<id> column), or can be a hash of column-name to value mappings which must
be met by a record.

For example, to find out whether there is a current path for a GUID ID,
where C<last_revnum> is C<NULL>:

=for syntax-highlight perl

    my $guid_already_present = db_row_exists($db, file_path =>
        guid_id => $guid_id,
        branch_id => $branch_id,
        last_revnum => undef,
    );

=cut

sub db_row_exists
{
    my ($db, $table, @where) = @_;
    my $where = _where($db, @where);

    return $db->selectrow_array(qq{
        select 1
        from $table
        $where
        limit 1
    });
}

=item db_row_id($db, $table, %where)

Return the ID number (the value from the C<id> column) from C<$table> on
the database connection C<$db>, where the values in C<%where> match the
values in a record.  If there are more than one such value, an arbitrarily
chosen one is returned.  Nothing is returned if there are no matches.

=for syntax-highlight perl

    my $file_id = db_row_id($db, 'wc_file',
        wc_id => $wc_id,
        path => $path,
    );

=cut

sub db_row_id
{
    my ($db, $table, @where) = @_;
    my $where = _where($db, @where);

    return $db->selectrow_array(qq{
        select id
        from $table
        $where
        limit 1
    });
}

=item db_select($db, $table, $where, @columns)

Gets the named columns in C<@columns> from a record in table C<$table>
using database connection C<$db> and returns them as a list.  Only
one record is selected.  If there are multiple matches then an arbitrary
one is returned.

C<$where> can be either an ID number (to match the C<id> column) or
a reference to a hash of column names and values to match.  Values
can be C<undef> to match C<NULL>.  C<$where> can also be a reference
to an empty hash if you don't care which record is selected.

=for syntax-highlight perl

    my $branch_path = db_select($db, branch => $branch_id, 'path');

The column names are not quoted, so they can be SQL expressions:

=for syntax-highlight perl

    my $last_known_rev = db_select($db, revision => {}, 'max(revnum)');

=cut

sub db_select
{
    my ($db, $table, $where, @columns) = @_;
    croak 'usage: db_select($db, $table, $where, @columns)'
        unless @columns;

    my $columns = join ', ', @columns;
    $where = _where($db, (ref $where ? (%$where) : ($where)));

    return $db->selectrow_array(qq{
        select $columns
        from $table
        $where
        limit 1
    });
}

=item db_select_col($db, $table, $where, $column)

Return a list of values from the column named by C<$column> in C<$table>
using database connection C<$db>.

C<$where> can be either an ID number (to match the C<id> column) or
a reference to a hash of column names and values to match.  Values
can be C<undef> to match C<NULL>.  C<$where> can also be a reference
to an empty hash if you want to select all records.

=for syntax-highlight perl

    my @podcast_urls = db_select_col($db, url =>
        { method => 'article', content_type => 'audio/mpeg' },
        'url',
    );

The column name is not quoted, so it can be an SQL expression.

=cut

sub db_select_col
{
    my ($db, $table, $where, $column) = @_;
    croak 'usage: db_select_all($db, $table, $where, $column)'
        unless @_ == 4 && defined $column;

    $where = _where($db, (ref $where ? (%$where) : ($where)));

    my $sth = $db->prepare(qq{
        select $column
        from $table
        $where
    });
    $sth->execute;

    my @records;
    while (my ($val) = $sth->fetchrow_array) {
        push @records, $val;
    }

    return @records;
}

=item db_insert($db, $table, %value)

Insert a new record into C<$table> on database connection C<$db>.

C<%value> should be a hash of column names and values to use for
them.  The values are SQL quoted, but this should not be used for
inserting arbitrary binary data into C<bytea> columns.  Values can
be C<undef>, in which case C<NULL> will be inserted.

Returns the C<id> number of the new record, but only attempts to do
this (it might not work on tables without C<serial> columns) if a
return value is expected.

=for syntax-highlight perl

    my $branch_id = db_insert($db, 'branch', path => $path);

=cut

sub db_insert
{
    my ($db, $table, %value) = @_;
    croak 'usage: db_insert($db, $table, %value)'
        unless keys %value;

    my $columns = join ', ', keys %value;
    my $placeholders = join ', ', ('?') x scalar keys %value;
    $db->do("insert into $table ($columns) values ($placeholders)",
             undef, values %value);

    # Return the ID of the new value, unless we're in void context.
    return unless defined wantarray;
    return $db->last_insert_id(undef, undef, $table, undef);
}

=item db_update($db, $table, $where, %value)

Updates one or more records in C<$table> using database connection C<$db>.

Only records matching C<$where> are updated.  It can be either a single
number (matched against the C<id> column) or a reference to a hash of
column names and values to match.

=for syntax-highlight perl

    db_update($db, wc_file => $file_id,
        modified_at => db_datetime($time),
    );

If C<$where> is a reference to an empty hash then this function will die.
If you really want to update every record unconditionally, use a normal
C<$db-E<gt>do> method call.

Returns the number of rows updated, or C<undef> on error, or -1 if the number
of rows changed can't be determined.

=cut

sub db_update
{
    my ($db, $table, $where, %value) = @_;
    return unless keys %value;

    if (ref $where) {
        croak 'db_update() without any conditions is too dangerous'
            unless keys %$where;
        $where = _where($db, %$where);
    }
    else {
        $where = 'where id = ' . $db->quote($where);
    }
    assert($where) if DEBUG;

    my $sets = join ', ',
               map { "$_ = " . $db->quote($value{$_}) }
               keys %value;

    return $db->do("update $table set $sets $where");
}

=item db_replace($db, $table, $where, %value)

Either inserts a new record, if there is none matching C<$where>, or
updates one or more existing records if there is.

C<$where> must be a reference to a hash of column names and values to match.

If there is already at least one record which matches C<$where>, then this
behaves the same as L<db_update()|/db_update($db, $table, $where, %value)>.
Otherwise a new record is inserted using both the values in C<%value> and
the ones in C<%$where> combined.  If a column's value is given in both
hashes, the one in C<%value> is used.

If a new record is inserted and a return value is expected, then the C<id>
value of the new record will be returned.  For updates C<undef> is always
returned.

=cut

sub db_replace
{
    my ($db, $table, $where, %value) = @_;
    croak 'usage: db_replace($db, $table, $where, %value)'
        unless ref $where && keys %value;
    croak 'db_replace() without any conditions is too dangerous'
        unless keys %$where;

    if (db_row_exists($db, $table, %$where)) {
        db_update($db, $table, $where, %value);
        return undef;
    }
    else {
        while (my ($column, $value) = each %$where) {
            $value{$column} = $value
                unless exists $value{$column};
        }
        return db_insert($db, $table, %value);
    }
}

=item db_delete($db, $table, ...)

Delete records from C<$table> using database connection C<$db>.
If a single additional value is specified then it is matched against
the C<id> column, otherwise a hash of column names and values is
expected.

This function will die if you don't give it some conditions to check for.
If you really want to delete every record unconditionally, use a normal
C<$db-E<gt>do> method call.

=cut

sub db_delete
{
    my ($db, $table, @where) = @_;
    croak 'db_delete() without any conditions is too dangerous'
        unless @where;

    my $where = _where($db, @where);
    assert($where) if DEBUG;

    return $db->do("delete from $table $where");
}

=item wc_file_data($db, $file_id)

Returns a reference to the data (content) of the C<wc_file> record identified
by C<$file_id>.  Fails if the file is actually a directory or doesn't exist.

This takes care of getting data from the live working copy if the file
just has a reference to a file with the same content.

=cut

sub wc_file_data
{
    my ($db, $file_id) = @_;
    assert(defined $file_id) if DEBUG;

    my ($is_dir, $data, $data_ref_id) = db_select($db,
        wc_file => $file_id,
        qw( is_dir data data_from_file_id ),
    );
    assert(!$is_dir) if DEBUG;

    if (!defined $data) {
        croak "no data for file $file_id"
            unless defined $data_ref_id;
        $data = db_select($db, wc_file => $data_ref_id, 'data');
    }

    return \$data;
}

=item guess_mime_type($data, $filename)

Return the likely MIME type of the data referenced by C<$data> (a scalar
reference), or nothing if it is of an unknown type.

C<$filename> is optional, but can be used for some additional guesswork
if supplied.  Currently it is only used to recognize C<text/css> files,
which might otherwise get identified as C<text/plain>.

=cut

sub guess_mime_type
{
    my ($data, $filename) = @_;
    my $mime_magic = File::MMagic->new;
    my $mime_type = $mime_magic->checktype_contents($$data);
    return unless defined $mime_type;

    $mime_type =~ /^[-a-z0-9]+\/[-a-z0-9]+$/i
        or croak "got invalid mime type for '$filename' ($mime_type)";
    $mime_type = 'text/css'
        if $mime_type eq 'text/plain' && defined $filename &&
           $filename =~ /\.css$/i;

    return $mime_type;
}

=item guid_first_last_times($db, $guid_id)

Returns a list of two timestamps, as L<DateTime> values, which can be
used for the publication time and the time of the last update, in the
case that the user hasn't overridden them with Subversion properties
(C<dcterms:issued> and C<dcterms:modified> respectively).

=cut

sub guid_first_last_times
{
    my ($db, $guid_id) = @_;
    my ($first, $last) = db_select($db, file_guid => $guid_id,
                                   qw( first_revnum last_changed_revnum ));
    my ($issued) = db_select($db, revision => { revnum => $first },
                             'committed_at');
    my ($modified) = db_select($db, revision => { revnum => $last },
                               'committed_at');
    return (parse_db_datetime($issued), parse_db_datetime($modified));
}

=item wc_property($cms, $wc_id, $file_id, $content_type, $data, $allow_data_ref)

Warning: this should currently only be used for proper updates from the
repository, not making live uncommitted changes in a working copy.  Doing
so will currently break everything.

Updates the data stored for file C<$file_id> (which must not be a directory)
in working copy C<$wc_id>.  It takes care of things like calculating the
digest and the pixel size of image files.

C<$data> should be a reference to a scalar containing the actual data.

If C<$allow_data_ref> is true, and the working copy isn't the live working
copy, then this function will try to find an existing copy of the same
data in the live working copy and store a reference to that instead of an
additional copy of the data.

=cut

# TODO - if this changes the mime type, it should update the wc_property table
sub wc_set_file_data
{
    my ($cms, $wc_id, $file_id, $content_type, $data, $allow_data_ref) = @_;
    my $db = $cms->{db};

    my ($img_wd, $img_ht);
    ($img_wd, $img_ht) = imgsize($data)
        if defined $content_type && $content_type =~ m!^image/!i;

    my $sha1 = sha1_base64($$data);
    my $live_wc_id = $cms->{live_wc_id};

    # Working copies other than the live one can reference a file in the
    # live working copy which has the same data, rather than storing a
    # separate copy of it.
    my $saved;
    if (length($$data) > 0 && $wc_id != $live_wc_id && $allow_data_ref) {
        my ($src_file_id) = $db->selectrow_array(q{
            select id
            from wc_file
            where wc_id = ?
              and data is not null
              and data_sha1 = ?
              and data_len = ?
        }, undef, $live_wc_id, $sha1, length($$data));
        if (defined $src_file_id) {
            db_update($db, wc_file => $file_id,
                data => undef,
                data_from_file_id => $src_file_id,
                data_sha1 => $sha1,
                data_len => length($$data),
                image_width => $img_wd,
                image_height => $img_ht,
            );
            $saved = 1;
        }
    }
    elsif ($wc_id == $live_wc_id) {
        # When the live working copy's data is updated, make sure there
        # aren't any other files which reference the old version of the
        # data.  If there are, give them a full copy.
        $db->do(q{
            update wc_file
            set data = (select data from wc_file where id = ?),
                data_from_file_id = null
            where data_from_file_id = ?
        }, undef, $file_id, $file_id);
    }

    # Store the new content.
    if (!$saved) {
        my $sth = $db->prepare(q{
            update wc_file
            set data = ?,
                data_len = ?,
                data_sha1 = ?,
                image_width = ?,
                image_height = ?
            where id = ?
        });
        $sth->bind_param(1, $$data, { pg_type => DBD::Pg::PG_BYTEA });
        $sth->bind_param(2, length $$data);
        $sth->bind_param(3, $sha1);
        $sth->bind_param(4, $img_wd);
        $sth->bind_param(5, $img_ht);
        $sth->bind_param(6, $file_id);
        $sth->execute;
    }
}

=item mint_guid($cms, $is_dir, $path)

Add a new entry to the C<file_guid> table for a file which initially
(in the first revision for which it exists) resides at C<$path>.

A new 'tag' URI will be created for the GUID, using the appropriate entity
as defined in the configuration file (see the documentation for the
C<guid-entity> element in the Daizu configuration file
(see L<http://www.daizucms.org/doc/config-file/>).

A list of two values is returned: the ID number of the new record, and
the tag URI created for it.

=cut

sub mint_guid
{
    my ($cms, $is_dir, $path, $revnum) = @_;
    my $db = $cms->{db};

    my $guid_id = db_insert($db, file_guid =>
        is_dir => ($is_dir ? 1 : 0),
        uri => 'x-temp:',
        first_revnum => $revnum,
        last_changed_revnum => $revnum,
    );

    my $entity = $cms->guid_entity($path);
    my $guid_uri = "tag:$entity:$guid_id";
    db_update($db, file_guid => $guid_id,
        uri => $guid_uri,
    );

    return ($guid_id, $guid_uri);
}

=item load_class($class)

Load a Perl module called C<$class> which contains a class.  So this doesn't
do any C<import> calling, since that shouldn't be necessary.  It keeps track
of which classes have already been loaded, and won't do any extra work if
you try to load the same class twice.

This method is used to load generator classes and plugins.

=cut

{
    my %class_loaded;

    sub load_class
    {
        my ($class) = @_;
        unless (exists $class_loaded{$class}) {
            eval "require $class";
            die "$@" if $@;
            undef $class_loaded{$class};
        }
    }
}

=item instantiate_generator($cms, $class, $root_file)

Create a generator object from the Perl class C<$class>, passing in the
information generator classes except for their constructors.
C<$root_file>, which should be a L<Daizu::File> object, is passed to the
generator and as also used to find the configuration information, if
any, for this generator instance.  Typically C<$root_file> will be the
on which the C<daizu:generator> property was set to enable this generator
class.

If C<$class> is undef then the default generator is used (L<Daizu::Gen>).

=cut

sub instantiate_generator
{
    my ($cms, $class, $root_file) = @_;

    $class = 'Daizu::Gen'
        unless defined $class;

    load_class($class);

    my $path = $root_file->{path};
    my $config = $cms->{generator_config}{$class}{$path};
    $config = $cms->{generator_config}{$class}{''}
        unless defined $config;

    return $class->new(
        cms => $cms,
        root_file => $root_file,
        config_elem => $config,
    );
}

=item update_all_file_urls($cms, $wc_id)

Updates the C<url> table in the same way as the L<Daizu::File> method
L<update_urls_in_db()|Daizu::File/$file-E<gt>update_urls_in_db>, except that
it does so for all files in working copy C<$wc_id>, and the return
values are each true if I<any> of the changes include new or updated
redirects or 'gone' files.

TODO - each file's URLs are updated in a separate database transaction,
whereas really the whole thing should be done in a single transaction.

=cut

sub update_all_file_urls
{
    my ($cms, $wc_id) = @_;

    my $sth = $cms->db->prepare(q{
        select id
        from wc_file
        where wc_id = ?
    });
    $sth->execute($wc_id);

    my ($redirects_changed, $gone_changed);
    while (my ($file_id) = $sth->fetchrow_array) {
        my $file = Daizu::File->new($cms, $file_id);
        my ($rc, $gc) = $file->update_urls_in_db;
        $redirects_changed = 1 if $rc;
        $gone_changed = 1 if $gc;
    }

    return ($redirects_changed, $gone_changed);
}

=item add_xml_elem($parent, $name, $content, %attr)

Create a new XML DOM element (an L<XML::LibXML::Element> object) and
add it to the parent element C<$parent>.  C<$name> is the name of the
new element.

If C<$content> is defined, then it can either be a libxml object to
add as a child of the element, or a piece of text to use as its content.

The keys and values in C<%attr> are added to the new element as
attributes.

=cut

sub add_xml_elem
{
    my ($parent, $name, $content, %attr) = @_;
    my $elem = XML::LibXML::Element->new($name);
    $parent->appendChild($elem);

    if (defined $content) {
        $content = XML::LibXML::Text->new($content)
            unless ref $content;
        $elem->appendChild($content);
    }

    while (my ($attr_name, $value) = each %attr) {
        $elem->setAttribute($attr_name => $value);
    }

    return $elem;
}

=item xml_attr($filename, $elem, $attr, $default)

Returns the value of the attribute of the XML element C<$elem>,
which must be a L<XML::LibXML::Element> object.  If no such element
exists, return C<$default> if that is defined, otherwise die
with an appropriate error message.

=cut

sub xml_attr
{
    my ($filename, $elem, $attr, $default) = @_;
    return $elem->getAttribute($attr)
        if $elem->hasAttribute($attr);
    return $default
        if defined $default;

    my $elem_name = $elem->localname;
    xml_croak($filename, $elem,
              "missing attribute '$attr' on element <$elem_name>");
}

=item xml_croak($filename, $node, $message)

Croaks with an error message which includes C<$message>, but also
gives the filename and the line number at which C<$node> occurs.

C<$node> should be some kind of L<XML::LibXML::Node> object.

=cut

sub xml_croak
{
    my ($filename, $node, $msg) = @_;
    my $line_number = $node->line_number;
    croak "$filename:$line_number: $msg";
}

=item branch_id($db, $branch)

If C<$branch> is an number then return it unchanged, and just assume
that it is a valid branch ID.

Otherwise, try to find a branch with C<$branch> as its path, and return
the ID number of that.  Dies if no such branch exists.

=cut

sub branch_id
{
    my ($db, $branch) = @_;
    return $1 if $branch =~ /^(\d+)$/;

    my $branch_id = db_row_id($db, 'branch', path => $branch);
    croak "branch '$branch' does not exist"
        unless defined $branch_id;

    return $branch_id;
}

=item daizu_data_dir($dir)

Return the absolute path (on the native filesystem) of the directory
called C<$dir> under the directory C<Daizu> where the Perl modules are
installed.  This is used to locate data files which can be installed
along with the Daizu Perl modules, such as some XML DTD files in the
C<xml> directory.  Look for directories whose names are all lowercase
in C<lib/Daizu/> in the source tarball for these.

The return value is actually a L<Path::Class::Dir> object.

Note that it is assumed these directories will be alongside the location
of the file for this module (Daizu::Util).  This should ensure that the
right data files are used depending on whether you're using an installed
version of Daizu CMS or testing from the source directory.

This function will die if the directory doesn't exist where it is
expected to be.

=cut

sub daizu_data_dir
{
    my ($dir) = @_;
    my $path = file(__FILE__)->dir->subdir($dir)->absolute;
    die "data directory '$dir' not found at '$path' where it should be"
        unless -d $path;
    return $path;
}

=back

=head1 COPYRIGHT

This software is copyright 2006 Geoff Richards E<lt>geoff@laxan.comE<gt>.
For licensing information see this page:

L<http://www.daizucms.org/license/>

=cut

1;
# vi:ts=4 sw=4 expandtab
