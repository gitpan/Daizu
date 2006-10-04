package Daizu::Publish;
use warnings;
use strict;

use base 'Exporter';
our @EXPORT_OK = qw(
    create_publishing_job
);

use DateTime;
use File::Temp qw( tempfile );
use Digest::SHA1;
use Carp qw( croak );
use Carp::Assert qw( assert DEBUG );
use Daizu::Wc;
use Daizu::Publish::Editor;
use Daizu::Util qw(
    db_datetime
    db_select db_insert db_update db_replace
);

=head1 NAME

Daizu::Publish - functions for creating publishing jobs

=head1 FUNCTIONS

The following functions are available for export from this module.
None of them are exported by default.

=over

=item create_publishing_job($cms, $start_revnum)

Create a new publishing job to bring the live websites up to date with
revision number C<$start_revnum>.  If there are no new revisions which
haven't already been published, then it does nothing and returns nothing.
Otherwise it returns the ID number of the new job (identifying a record
in the C<publish_job> table).

=cut

sub create_publishing_job
{
    my ($cms, $start_rev) = @_;
    return transactionally($cms->{db}, \&_create_publishing_job_txn,
                           $cms, $start_rev);
}

sub _create_publishing_job_txn
{
    my ($cms, $start_rev) = @_;
    my $db = $cms->{db};

    my $live_wc = $cms->live_wc;
    my $latest_rev = $live_wc->current_revision;
    assert($latest_rev >= 1) if DEBUG;
    my $cur_rev = db_select($db, live_revision => {}, 'revnum') || 0;

    # Quit if we're publishing the unpublished stuff, and there's none to do.
    return if !defined $start_rev && $cur_rev == $latest_rev;

    # Default to publishing everything that hasn't been made live yet.
    $start_rev = $cur_rev
        unless defined $start_rev;

    croak "bad start_rev revision number r$start_rev"
        if $start_rev < 0;
    croak "bad revisions for publication job (r$start_rev to r$latest_rev)"
        unless $latest_rev > $start_rev;

    my $job_id = db_insert($db, 'publish_job',
        start_rev => ($start_rev == 0 ? undef : $start_rev),
        end_rev => $latest_rev,
        created_at => db_datetime(DateTime->now),
    );

    my $editor = Daizu::Publish::Editor->new(
        cms => $cms,
        db => $db,
        job_id => $job_id,
        live_wc => $live_wc,
        start_rev => $start_rev,
        latest_rev => $latest_rev,
        branch_id => $live_wc->{branch_id},
        branch_path => $live_wc->{branch_path},
    );
    my $ra = $cms->{ra};
    my $reporter = $ra->do_update($latest_rev, $live_wc->{branch_path}, 1,
                                  $editor);
    $reporter->set_path('', $start_rev, 0, undef);
    $reporter->finish_report;

    # Compare files with path changes to see what really changed.
    my $sth = $db->prepare(q{
        select jf.guid_id, f.id, f.data_sha1, fp.path
        from job_file jf
        -- for file ID and current version's content hash:
        inner join wc_file f on f.guid_id = jf.guid_id
                            and f.wc_id = ?
        -- for the old version's path:
        inner join file_path fp on fp.guid_id = jf.guid_id
                               and fp.branch_id = ?
                               and fp.first_revnum >= ?
                               and fp.last_revnum <= ?
        where jf.job_id = ?
          and jf.path_changed
          and jf.action = '?'
    });
    $sth->execute($live_wc->{id}, $live_wc->{branch_id}, $start_rev,
                  $start_rev, $job_id);
    while (my ($guid_id, $file_id, $new_sha1, $old_path) = $sth->fetchrow_array)
    {
        # Check whether actual file content has changed.
        my ($content_changed, $old_props);
        if (defined $new_sha1) {
            # TODO - I could probably avoid the temp file by having a separate
            # thread read the data from a pipe directly into Digest::SHA1,
            # and pass the 'write' end of the pipe to Subversion.
            my $fh = tempfile();
            binmode $fh;
            my $path = $live_wc->{branch_path} .
                       ($old_path eq '' ? '' : "/$old_path");
            (undef, $old_props) = $ra->get_file($path, $start_rev, $fh);

            seek $fh, 0, 0
                or croak "unable to seek to start of temp file: $!";
            my $digest = Digest::SHA1->new;
            $digest->addfile($fh);

            $content_changed = 1 if $digest->b64digest ne $new_sha1;
        }

        db_update($db, 'job_file',
            { job_id => $job_id, guid_id => $guid_id },
            action => ($content_changed ? 'M' : undef),
        );

        # Each item in this is an array ref of two items: old value, new value.
        my %props;

        while (my ($name, $value) = each %$old_props) {
            next if $name =~ /^svn:entry:/;
            $props{$name}[0] = $value;
        }

        my $prop_sth = $db->prepare(q{
            select name, value
            from wc_property
            where file_id = ?
        });
        $prop_sth->execute($file_id);
        while (my ($name, $value) = $prop_sth->fetchrow_array) {
            $props{$name}[1] = $value;
        }

        db_delete($db, 'job_property', job_id => $job_id, guid_id => $guid_id);

        while (my ($name, $values) = each %props) {
            my ($old, $new) = @$values;
            assert(defined $old || defined $new) if DEBUG;
            my $action = !defined $old ? 'M' :
                         !defined $new ? 'D' :
                         $old ne $new  ? 'M' : undef;
            next unless defined $action;
            db_insert($db, 'job_property',
                job_id => $job_id,
                guid_id => $guid_id,
                name => $name,
                action => $action,
            );
        }
    }

    db_replace($db, 'live_revision', { revnum => $cur_rev },
        revnum => $latest_rev,
    );

    return $job_id;
}

=back

=head1 COPYRIGHT

This software is copyright 2006 Geoff Richards E<lt>geoff@laxan.comE<gt>.
For licensing information see this page:

L<http://www.daizucms.org/license/>

=cut

1;
# vi:ts=4 sw=4 expandtab
