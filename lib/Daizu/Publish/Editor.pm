package Daizu::Publish::Editor;
use warnings;
use strict;

use SVN::Delta;
use base 'SVN::Delta::Editor';

use Carp::Assert qw( assert DEBUG );
use Daizu::Revision qw( file_guid );
use Daizu::Util qw(
    like_escape
    db_row_exists db_insert db_update
);

=head1 Daizu::Publish::Editor - Subversion editor for creating publishing jobs

=head2 BATONS

Directory and file batons are a reference to a hash which can contain the
following keys:

=over

=item guid_id

Reference to entry in C<file_guid> table.

=item action

Type of change made to a directory or the actual content of a file.
Can be 'A' for added, 'M' for content modified.  If it isn't present no
actual changes have been made to the content (although there may still
be changes to properties).

=item props

A reference to a hash where the keys are property names and the values
are either 'M' if a new property has been added or an existing one
changed, or 'D' if an existing property has been deleted.  Only present
if any property modifications have been made.  Doesn't include special
'entry' properties (those with names starting with C<svn:entry:>).

=back

The file/directory batons are C<undef> for directories which aren't stored
in the working copy, but are further up the directory hierarchy, such
as 'trunk'.

=cut

sub _add_file_change
{
    my ($db, $job_id, $guid_id, $action) = @_;

    my $exists = db_row_exists($db, 'job_file',
        job_id => $job_id,
        guid_id => $guid_id,
    );
    if ($exists) {
        # If it already has a change, then it must have been both added and
        # deleted, and that implies a path change.  We record that it is
        # uncertain whether it has other modifications, but after the update
        # is finished that will be checked to see which content or property
        # changes really apply in addition to the path change.
        assert($action ne 'M') if DEBUG;
        db_update($db, 'job_file',
            { job_id => $job_id, guid_id => $guid_id },
            path_changed => 1,
            action => '?',
        );
    }
    else {
        db_insert($db, 'job_file',
            job_id => $job_id,
            guid_id => $guid_id,
            action => $action,
        );
    }
}

sub delete_entry
{
    my ($self, $path) = @_;
    my $db = $self->{db};
    my $branch_path = $self->{branch_path};
    my $job_id = $self->{job_id};

    my $sth;
    if (length($path) <= length($branch_path)) {
        # If this is the branch directory or something above it, then
        # all the files which were present in the base revision should be
        # deleted.
        assert($path eq substr($branch_path, 0, length($path))) if DEBUG;
        my $sth = $db->prepare(q{
            select guid_id
            from file_path
            where branch_id = ?
              and first_revnum >= ?
              and last_revnum <= ?
        });
        $sth->execute($self->{branch_id}, $self->{start_rev},
                      $self->{start_rev});
    }
    else {
        # Delete a file or directory, and anything which was inside it.
        assert($branch_path eq substr($path, 0, length($branch_path))) if DEBUG;
        $path = substr($path, length($branch_path) + 1);
        my $sth = $db->prepare(q{
            select guid_id
            from file_path
            where branch_id = ?
              and first_revnum >= ?
              and last_revnum <= ?
              and (path = ? or path like ?)
        });
        $sth->execute($self->{branch_id}, $self->{start_rev},
                      $self->{start_rev}, $path, like_escape($path) . '/%');
    }

    while (my ($guid_id) = $sth->fetchrow_array) {
        _add_file_change($db, $job_id, $guid_id, 'D');
    }
}

sub add_file
{
    my ($self, $path) = @_;
    my $branch_path = $self->{branch_path};
    return undef unless length($path) > length($branch_path);

    assert($branch_path eq substr($path, 0, length($branch_path))) if DEBUG;
    $path = substr($path, length($branch_path) + 1);
    my $guid = file_guid($self->{db}, $self->{branch_id}, $path,
                         $self->{latest_rev});

    return { guid_id => $guid->{id}, action => 'A' };
}

*add_directory = *add_file;

sub open_file
{
    my ($self, $path) = @_;
    my $branch_path = $self->{branch_path};
    return undef unless length($path) > length($branch_path);

    assert($branch_path eq substr($path, 0, length($branch_path))) if DEBUG;
    $path = substr($path, length($branch_path) + 1);
    my $guid = file_guid($self->{db}, $self->{branch_id}, $path,
                         $self->{latest_rev});
    return { guid_id => $guid->{id} };
}

*open_directory = *open_file;

sub change_file_prop
{
    my ($self, $baton, $name, $value) = @_;
    return unless defined $baton;

    # Don't bother storing the special 'entry' properties, since on their own
    # they don't represent changes that should affect what gets republished.
    return if $name =~ /^svn:entry:/;

    $baton->{props}{$name} = defined $value ? 'M' : 'D';
}

*change_dir_prop = *change_file_prop;

sub absent_file
{
    my ($self, $path) = @_;
    warn "file or directory '$path' cannot be updated for some reason";
}

*absent_directory = *absent_file;

sub close_file
{
    my ($self, $baton) = @_;
    return unless defined $baton;
    return unless defined $baton->{action} || exists $baton->{props};

    my $db = $self->{db};
    my $job_id = $self->{job_id};
    my $guid_id = $baton->{guid_id};
    my $action = defined $baton->{action} ? $baton->{action} : 'P';

    _add_file_change($db, $job_id, $guid_id, $action);

    while (my ($name, $action) = each %{$baton->{props}}) {
        db_insert($db, 'job_property',
            job_id => $job_id,
            guid_id => $guid_id,
            name => $name,
            action => $action,
        );
    }
}

*close_directory = *close_file;

sub apply_textdelta
{
    my ($self, $baton) = @_;
    assert(defined $baton) if DEBUG;

    if (defined $baton->{action}) {
        assert($baton->{action} eq 'A') if DEBUG;
    }
    else {
        $baton->{action} = 'M';
    }
}

sub abort_edit
{
    my ($self, $pool) = @_;
    # TODO
    print STDERR "abort_edit: self=$self, pool=$pool;\n";
}

=head1 COPYRIGHT

This software is copyright 2006 Geoff Richards E<lt>geoff@laxan.comE<gt>.
For licensing information see this page:

L<http://www.daizucms.org/license/>

=cut

1;
# vi:ts=4 sw=4 expandtab
