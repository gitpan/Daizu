package Daizu::Gen::Blog;
use warnings;
use strict;

use base 'Daizu::Gen';

use DateTime;
use DateTime::Format::Pg;
use Carp::Assert qw( assert DEBUG );
use Encode qw( encode );
use Daizu;
use Daizu::Feed;
use Daizu::Util qw(
    trim like_escape validate_number
    parse_db_datetime
    db_select
    xml_attr xml_croak
);

=head1 NAME

Daizu::Gen::Blog - generator for publishing a blog

=head1 DESCRIPTION

To publish a blog using Daizu CMS, create a top-level directory for
it and set that directory's generator class to this one.

This class is a subclass of L<Daizu::Gen>.  The ways in which it
differs are described below.

=head2 Article URLs

Article URLs are partially date-based.  Articles can be stored anywhere
inside the blog directory (the one with this generator class), providing
their generator isn't overridden.  You can use an arbitrary directory
structure to organise your articles, but the URL will always be of this
format:

    .../YYYY/MM/slug/

where the first two parts are based on the 'published' date of the article.
'slug' is either the base part of its filename (everything but the last file
extension) or if it is an '_index' file then the name of its parent directory.
Any other directories, which don't directly contain an '_index' file, won't
affect URLs at all.

Apart from having slightly different URLs than normal, blog articles are
treated like any other articles.

=head2 Homepage

The blog directory will generate a homepage listing recent articles.
Articles with C<daizu:fold> elements in can be displayed specially,
with only the content above the fold shown in the homepage (and date-based
archive pages described below), with a 'Read more' link to the full article.

=head2 Feeds

XML feeds of the latest articles will be generated, either in Atom or RSS
format.  See L</CONFIGURATION> below for information about how to set these
up.  There will always be at least one feed generated for each blog.

=head2 Archive pages

For each year and month in which at least one article was published (based
on the 'published' date) there will be an archive page generated listing
those articles.

=head1 CONFIGURATION

The configuration file can be used to set up the XML feeds for each blog
in various ways.  If you don't configure any feeds then you'll get a default
one.  The default feed will be an S<Atom 1.0> format one, which will include
the content of articles above the 'fold' (or all the content when there
is no fold), and will have the URL 'feed.atom' relative to the URL of the
blog directory.

If you want to change these defaults, for example to add an RSS feed as
well as the Atom one, then you'll need to add C<feed> elements to the
generator configuration for the blog directory, something like this:

=for syntax-highlight xml

    <generator class="Daizu::Gen::Blog" path="ungwe.org/blog">
     <feed format="atom" type="content" />
     <feed format="rss2" type="description" url="qefsblog.rss" />
    </generator>

Each feed element can have the following attributes:

=over

=item format

Required.  Either C<atom> to generate an S<Atom 1.0> feed, or C<rss2>
to generate an S<RSS 2.0> feed.  See L<Daizu::Feed/FEED FORMATS> for
details.

=item type

The type of content to include with each item in the feed.  The default
is C<snippet>, which means to include the full content of each article,
unless the article contains a 'fold' (a C<daizu:fold> element) in which
case only the content above the fold will be included in the feed.
A page break (a C<daizu:page> element) will also be counted as a fold
if no C<daizu:fold> element is found on the first page.
If only part of the article is shown then a link is provided to the
URL where the full article can be read.

The alternative types are C<content> which includes the full content
of each article regardless of whether it as a fold or page break or not, and
C<description> which never includes the full content, but only the
description (from the C<dc:description> property) if available.
If there is no description, a sample of text from the start of the article
will be used instead.

See L<Daizu::Feed/FEED TYPES> for details of how this information is
encoded in the different feed formats.

=item url

The URL where the feed will be published, usually a relative path which
will be resolved against the URL of the blog directory (homepage).

The default is either C<feed.atom> or C<feed.rss>, depending on the
'format' value.

=item size

The number of articles which should be included in the feed.  The default
depends on the 'type' value.

=back

=cut

our $DEFAULT_FEED_FORMAT = 'atom';
our $DEFAULT_FEED_TYPE = 'snippet';
our %DEFAULT_FEED_SIZE = (
    description => 14,
    snippet => 14,
    content => 8,
);
our %FEED_FORMAT_INFO = (
    atom => { default_url => 'feed.atom', mime_type => 'application/atom+xml' },
    rss2 => { default_url => 'feed.rss',  mime_type => 'application/rss+xml' },
);

=head1 METHODS

=over

=item Daizu::Gen::Blog-E<gt>new(%options)

Create a new generator object for a blog.  The options are the same as
for L<the Daizu::Gen constructor|Daizu::Gen/Daizu::Gen-E<gt>new(%options)>.

=cut

sub new
{
    my $class = shift;
    my $self = $class->SUPER::new(@_);

    # Load configuration, if there is any.
    my @feeds;
    if (my $conf = $self->{config_elem}) {
        my $config_filename = $self->{cms}{config_filename};
        for my $elem ($conf->getChildrenByTagNameNS($Daizu::CONFIG_NS, 'feed'))
        {
            my $format = trim(xml_attr($config_filename, $elem, 'format'));
            xml_croak($config_filename, $elem, "unknown feed format '$format'")
                unless exists $FEED_FORMAT_INFO{$format};
            my $type = trim(xml_attr($config_filename, $elem, 'type',
                                     $DEFAULT_FEED_TYPE));
            my $size = trim(xml_attr($config_filename, $elem, 'size',
                                     $DEFAULT_FEED_SIZE{$type}));
            xml_croak($config_filename, $elem, "bad feed size '$size'")
                unless validate_number($size);
            my $url = trim(xml_attr($config_filename, $elem, 'url',
                                    $FEED_FORMAT_INFO{$format}{default_url}));
            push @feeds, {
                format => $format,
                type => $type,
                size => $size,
                url => $url,
            };
        }
    }

    # If no feeds are specified, provide a snippet Atom one as a default.
    if (!@feeds) {
        push @feeds, {
            format => $DEFAULT_FEED_FORMAT,
            type => $DEFAULT_FEED_TYPE,
            size => $DEFAULT_FEED_SIZE{$DEFAULT_FEED_TYPE},
            url => $FEED_FORMAT_INFO{$DEFAULT_FEED_FORMAT}{default_url},
        };
    }

    $self->{feeds} = \@feeds;

    return $self;
}

=item $gen-E<gt>custom_base_url($file, $base)

See the L<custom_base_url() method in Daizu::Gen|Daizu::Gen/$gen-E<gt>custom_base_url($file)>
for details.  The only differences in behaviour
for blogs are that article files (and directories which contain articles
called things like I<_index.html>) get special URLs based on the publication
date of the article and the 'slug' (file or directory name), based
at the URL of the blog directory itself.

Unprocessed files get the same URLs as L<Daizu::Gen> would give them,
unless they are inside a directory which 'belongs' to an article.
That is, if a directory has a child called I<_index.html> or similar,
then all the other non-article files in that directory, including
any in subdirectories to any level, will all get URLs which start
with the article's URL, followed by their path below the article's
directory.  So if an article is in a file called I<blog/foo/_index.html>
and there is also an image file inside I<foo> then it will get a URL
like I<2006/05/foo/image.jpg>, which means the article can include it
with a relative path like I<image.jpg>.  These relative URLs will be
adjusted as necessary when used in feeds and index pages.

=cut

sub custom_base_url
{
    my ($self, $file) = @_;

    # Don't do anything special for the root 'blog directory'.
    return $self->SUPER::custom_base_url($file)
        if $file->{id} == $self->{root_file}{id};

    # No base URL for blog as a whole.
    my $blog_url = $self->base_url($self->{root_file});
    return undef unless defined $blog_url;

    # Blog articles have date-based URLs.
    if ($file->{article}) {
        my $archive_date = $file->issued_at->strftime('%Y/%m');
        my $slug;
        if ($file->{name} =~ /^_index\./) {
            $slug = $file->parent->{name};
        }
        else {
            $slug = $file->{name};
            $slug =~ s/\.[^.]+\z//;
        }
        return URI->new("$archive_date/$slug/")->abs($blog_url);
    }

    # Handle directories which 'belong' to an article specially.
    # They get a URL identical to the article itself, so that any
    # ancillary files in the directory will be published alongside the
    # article.
    if ($file->{is_dir}) {
        my ($article_id) = $self->{cms}{db}->selectrow_array(q{
            select id
            from wc_file
            where parent_id = ?
              and article
              and name ~ '^_index\\\.'
            order by name
            limit 1
        }, undef, $file->{id});
        return $self->base_url(Daizu::File->new($self->{cms}, $article_id))
            if defined $article_id;
    }

    return $self->SUPER::custom_base_url($file);
}

=item $gen-E<gt>root_dir_urls_info($file)

Return the URLs generated by C<$file> (a L<Daizu::File> object),
which will be the blog directory itself.  This overrides the
L<root_dir_urls_info() method in
Daizu::Gen|Daizu::Gen/$gen-E<gt>root_dir_urls_info($file)>, although
it also calls that version in case the blog directory is home to a
Google sitemap.  It adds URLs with the following methods:

=over

=item homepage

Exactly one of these, with no argument.

=item feed

One for each configured feed.  There is always at least one of these,
and there can be as many as you want.  The argument will consist of the
feed format, the feed type, and the number of entries to include, each
separated by a space.

=item year_archive

URLs like '2006/', with the year number as the argument.

=item month_archive

URLs like '2006/05/' with the year and month numbers, separated by
a space, as the argument.  In the argument the month to two digits
(with leading zeroes added if necessary) because some of the code
relies on the month archive argument values sorting in the right order.

=back

=cut

sub root_dir_urls_info
{
    my ($self, $file) = @_;
    my @url = $self->SUPER::root_dir_urls_info($file);

    # Blog homepage
    push @url, { url => '', method => 'homepage', type => 'text/html' };

    # Feeds.
    for (@{$self->{feeds}}) {
        push @url, {
            url => $_->{url},
            method => 'feed',
            argument => "$_->{format} $_->{type} $_->{size}",
            type => $FEED_FORMAT_INFO{$_->{format}}{mime_type},
        };
    }

    # Yearly and monthly archive pages.
    my $sth = $self->{cms}{db}->prepare(qq{
        select distinct extract(year  from issued_at) as year,
                        extract(month from issued_at)
        from wc_file
        where wc_id = ?
          and article
          and not retired
          and path like ?
          and path !~ '(^|/)($Daizu::HIDING_FILENAMES)(/|\$)'
        order by year
    });
    $sth->execute($file->{wc_id}, like_escape($self->{root_file}{path}) . '/%');

    my $last_year;
    while (my ($year, $month) = $sth->fetchrow_array) {
        my $padded_year = sprintf '%04d', $year;
        my $padded_month = sprintf '%02d', $month;
        if (!defined $last_year || $year != $last_year) {
            push @url, {
                url => "$padded_year/",
                method => 'year_archive',
                argument => $padded_year,
                type => 'text/html',
            };
            $last_year = $year;
        }
        push @url, {
            url => "$padded_year/$padded_month/",
            method => 'month_archive',
            argument => "$padded_year $padded_month",
            type => 'text/html',
        };
    }

    return @url;
}

=item $gen-E<gt>article_template_variables($file, $url_info)

This method is overridden to provide extra information to the template
I<blog/head_meta.tt> so that it can correctly provide a C<link> element
pointing to the first blog feed.

=cut

sub article_template_variables
{
    my ($self, $file, $url_info) = @_;
    my $cms = $self->{cms};

    # TODO - this is a kludge because $self->{root_file} isn't right yet.
    my $root_generator = $file->generator;

    my $feed_url_info;
    for ($root_generator->urls_info($root_generator->{root_file})) {
        next unless $_->{generator} eq 'Daizu::Gen::Blog' &&
                    $_->{method} eq 'feed';
        $feed_url_info = $_;
        last;
    }
    assert(defined $feed_url_info) if DEBUG;

    my %links;
    my ($prev_id, $prev_url, $prev_type) = $cms->{db}->selectrow_array(q{
        select f.id, u.url, u.content_type
        from wc_file f
        inner join url u on u.wc_id = f.wc_id and u.guid_id = f.guid_id
        where f.wc_id = ?
          and u.generator = 'Daizu::Gen::Blog'
          and u.method = 'article'
          and f.issued_at < ?
          and path like ?
        order by issued_at desc, id desc
        limit 1
    }, undef, $file->{wc_id}, $file->{issued_at},
              like_escape($self->{root_file}{path}) . '/%');
    if (defined $prev_id) {
        $links{prev} = {
            href => URI->new($prev_url),
            type => $prev_type,
            title => Daizu::File->new($cms, $prev_id)->title,
        };
    }
    my ($next_id, $next_url, $next_type) = $cms->{db}->selectrow_array(q{
        select f.id, u.url, u.content_type
        from wc_file f
        inner join url u on u.wc_id = f.wc_id and u.guid_id = f.guid_id
        where f.wc_id = ?
          and u.generator = 'Daizu::Gen::Blog'
          and u.method = 'article'
          and f.issued_at > ?
          and path like ?
        order by issued_at, id
        limit 1
    }, undef, $file->{wc_id}, $file->{issued_at},
              like_escape($self->{root_file}{path}) . '/%');
    if (defined $next_id) {
        $links{next} = {
            href => URI->new($next_url),
            type => $next_type,
            title => Daizu::File->new($cms, $next_id)->title,
        };
    }

    return {
        first_feed_url => $feed_url_info->{url},
        first_feed_type => $feed_url_info->{type},
        head_links => \%links,
    };
}

=item $gen-E<gt>article_template_overrides($file, $url_info)

This method is overridden to adjust the display of article metadata for
blogs, since blog articles should display their author and publication
time.  It also provides a rewrite which adds a feed auto-subscription
link to the heading of the page.

=cut

sub article_template_overrides
{
    return {
        'head/meta.tt' => 'blog/head_meta.tt',
        'article_meta.tt' => 'blog/article_meta.tt',
    };
}

=item $gen-E<gt>homepage($file, $urls)

Generate the output for the homepage, which will be an index page listing
recent articles.

=cut

sub homepage
{
    my ($self, $file, $urls) = @_;
    my $cms = $self->{cms};
    my $HOW_MANY = 10;       # TODO - put this in the config

    for my $url (@$urls) {
        my $sth = $cms->{db}->prepare(q{
            select id from wc_file
            where wc_id = ?
              and article
              and not retired
              and path like ?
            order by issued_at desc, id desc
            limit ?
        });
        $sth->execute($file->{wc_id}, like_escape($file->{path}) . '/%',
                      $HOW_MANY);

        my @articles;
        while (my ($id) = $sth->fetchrow_array) {
            push @articles, Daizu::File->new($cms, $id);
        }

        $self->generate_web_page($file, $url, {
            %{ $self->article_template_overrides($file, $url) },
            'page_content.tt' => 'blog/homepage.tt',
        }, {
            %{ $self->article_template_variables($file, $url) },
            articles => \@articles,
            page_title => $file->title,
        });
    }
}

=item $gen-E<gt>feed($file, $url)

Generate output for a blog feed, in the appropriate format.

=cut

sub feed
{
    my ($self, $file, $urls) = @_;
    my $cms = $self->{cms};

    my $sth = $cms->{db}->prepare(q{
        select id
        from wc_file
        where wc_id = ?
          and article
          and not retired
          and path like ?
        order by issued_at desc, id desc
        limit ?
    });

    # Run the query to get enough entries for the largest feed.
    my $feeds = $self->{feeds};
    my $largest_size = 0;
    for my $url (@$urls) {
        my ($format, $type, $size) = split ' ', $url->{argument};
        $url->{feed_format} = $format;
        $url->{feed_type} = $type;
        $url->{feed_size} = $size;
        $largest_size = $size
            if $size > $largest_size;
    }
    $sth->execute($file->{wc_id}, like_escape($file->{path}) . '/%',
                  $largest_size);

    my @articles;
    while (my ($id) = $sth->fetchrow_array) {
        push @articles, Daizu::File->new($cms, $id);
    }

    for my $url (@$urls) {
        my $feed = Daizu::Feed->new($cms, $file, $url->{url},
                                    $url->{feed_format}, $url->{feed_type});

        my $num_entries = 0;
        for my $article (@articles) {
            last if $num_entries == $url->{feed_size};
            $feed->add_entry($article);
            ++$num_entries;
        }

        # The XML is printed in canonical form to avoid some extraneous
        # namespace declarations in the <content> of the Atom feed.
        my $fh = $url->{fh};
        print $fh encode('UTF-8', $feed->xml->toStringC14N, , Encode::FB_CROAK);
    }
}

=item $gen-E<gt>year_archive($file, $urls)

Generate a yearly archive page, listing all files published during
a given year.

=cut

sub year_archive
{
    my ($self, $file, $urls) = @_;
    my $cms = $self->{cms};

    for my $url (@$urls) {
        die "bad argument '$url->{argument}' for year archive URL"
            unless $url->{argument} =~ /^(\d+)$/;
        my $year = $1;

        my $sth = $cms->{db}->prepare(q{
            select id, extract(month from issued_at)
            from wc_file
            where wc_id = ?
              and article
              and not retired
              and path like ?
              and extract(year from issued_at) = ?
            order by issued_at, id
        });
        $sth->execute($file->{wc_id}, like_escape($file->{path}) . '/%', $year);

        my @months;
        my $cur_month;
        my $cur_articles;
        while (my ($id, $month) = $sth->fetchrow_array) {
            if (!defined $cur_month || $cur_month != $month) {
                $cur_month = $month;
                $cur_articles = [];
                push @months, {
                    month_url => sprintf('%02d/', $month),
                    month_name => DateTime->new(year => $year, month => $month)
                                          ->strftime('%B'),
                    articles => $cur_articles,
                };
            }
            push @$cur_articles, Daizu::File->new($cms, $id);
        }

        my %links;
        my ($prev_url, $prev_arg, $prev_type) = $cms->{db}->selectrow_array(q{
            select url, argument, content_type
            from url
            where wc_id = ?
              and guid_id = ?
              and generator = 'Daizu::Gen::Blog'
              and method = 'year_archive'
              and argument < ?
            order by argument desc
            limit 1
        }, undef, $file->{wc_id}, $file->{guid_id}, $url->{argument});
        if (defined $prev_url) {
            $links{prev} = {
                href => URI->new($prev_url),
                type => $prev_type,
                title => _year_archive_title($prev_arg),
            };
        }
        my ($next_url, $next_arg, $next_type) = $cms->{db}->selectrow_array(q{
            select url, argument, content_type
            from url
            where wc_id = ?
              and guid_id = ?
              and generator = 'Daizu::Gen::Blog'
              and method = 'year_archive'
              and argument > ?
            order by argument
            limit 1
        }, undef, $file->{wc_id}, $file->{guid_id}, $url->{argument});
        if (defined $next_url) {
            $links{next} = {
                href => URI->new($next_url),
                type => $next_type,
                title => _year_archive_title($next_arg),
            };
        }

        $self->generate_web_page($file, $url, {
            %{ $self->article_template_overrides($file, $url) },
            'page_content.tt' => 'blog/year_index.tt',
        }, {
            %{ $self->article_template_variables($file, $url) },
            months => \@months,
            page_title => _year_archive_title($year),
            head_links => \%links,
        });
    }
}

sub _year_archive_title
{
    my ($year) = @_;
    return "Articles for $year";
}

=item $gen-E<gt>month_archive($file, $urls)

Generate a monthly archive page, listing the articles published during
a given year and month.

=cut

sub month_archive
{
    my ($self, $file, $urls) = @_;
    my $cms = $self->{cms};

    for my $url (@$urls) {
        die "bad argument '$url->{argument}' for month archive URL"
            unless $url->{argument} =~ /^(\d+)\s+(\d+)$/;
        my $year = $1;
        my $month = $2;

        my $sth = $cms->{db}->prepare(q{
            select id
            from wc_file
            where wc_id = ?
              and article
              and not retired
              and path like ?
              and extract(year from issued_at) = ?
              and extract(month from issued_at) = ?
            order by issued_at, id
        });
        $sth->execute($file->{wc_id}, like_escape($file->{path}) . '/%',
                      $year, $month);

        my @articles;
        while (my ($id, $month) = $sth->fetchrow_array) {
            push @articles, Daizu::File->new($cms, $id);
        }

        my %links;
        my ($prev_url, $prev_arg, $prev_type) = $cms->{db}->selectrow_array(q{
            select url, argument, content_type
            from url
            where wc_id = ?
              and guid_id = ?
              and generator = 'Daizu::Gen::Blog'
              and method = 'month_archive'
              and argument < ?
            order by argument desc
            limit 1
        }, undef, $file->{wc_id}, $file->{guid_id}, $url->{argument});
        if (defined $prev_url) {
            $links{prev} = {
                href => URI->new($prev_url),
                type => $prev_type,
                title => _month_archive_title(split ' ', $prev_arg),
            };
        }
        my ($next_url, $next_arg, $next_type) = $cms->{db}->selectrow_array(q{
            select url, argument, content_type
            from url
            where wc_id = ?
              and guid_id = ?
              and generator = 'Daizu::Gen::Blog'
              and method = 'month_archive'
              and argument > ?
            order by argument
            limit 1
        }, undef, $file->{wc_id}, $file->{guid_id}, $url->{argument});
        if (defined $next_url) {
            $links{next} = {
                href => URI->new($next_url),
                type => $next_type,
                title => _month_archive_title(split ' ', $next_arg),
            };
        }

        $self->generate_web_page($file, $url, {
            %{ $self->article_template_overrides($file, $url) },
            'page_content.tt' => 'blog/month_index.tt',
        }, {
            %{ $self->article_template_variables($file, $url) },
            articles => \@articles,
            page_title => _month_archive_title($year, $month),,
            head_links => \%links,
        });
    }
}

sub _month_archive_title
{
    my ($year, $month) = @_;
    return 'Articles for ' .
           DateTime->new(year => $year, month => $month)
                   ->strftime("\%B\xA0\%Y");    # September&nbsp;2006
}

=item $gen-E<gt>navigation_menu($file, $url)

Returns a navigation menu for the page with the URL info C<$url>,
for the file C<$file>.  See the
L<subclass method|Daizu::Gen/$gen-E<gt>navigation_menu($file, $url)>
for details of what it does.

This implementation provides a menu of the archive pages, with a link
for each year in which an article was published.  The most recent years
have submenus for months.  After a certain number of months the menu
just shows years.  Each year either has all its months shown (or at least
the ones with articles in), or none at all.

=cut

sub navigation_menu
{
    my ($self, $cur_file, $cur_url_info) = @_;
    my $cms = $self->{cms};
    my $db = $cms->{db};
    my $cur_url = $cur_url_info->{url};

    # We need to identify the blog directory.  Currently the root file of
    # the generator used to create a URL isn't recorded with the URL, so
    # we find the root file for the generator of the current file in the
    # menu, and hope that's the same.
    my $root_file = $cur_file->generator->{root_file};

    # As an optimization, set one of these values to the argument of the
    # current URL for comparison with those of items in the menu, if the
    # current URL might appear in the menu itself, so that we can more
    # efficiently determine which URL to leave without a link.
    my ($cur_year_arg, $cur_month_arg);
    if ($cur_file->{guid_id} == $root_file->{guid_id} &&
        $cur_url_info->{generator} eq 'Daizu::Gen::Blog')
    {
        $cur_year_arg = $cur_url_info->{argument}
            if $cur_url_info->{method} eq 'year_archive';
        $cur_month_arg = $cur_url_info->{argument}
            if $cur_url_info->{method} eq 'month_archive';
    }

    my $year_sth = $db->prepare(q{
        select url, argument
        from url
        where wc_id = ?
          and guid_id = ?
          and generator = 'Daizu::Gen::Blog'
          and method = 'year_archive'
        order by argument
    });
    my $month_sth = $db->prepare(q{
        select url, argument
        from url
        where wc_id = ?
          and guid_id = ?
          and generator = 'Daizu::Gen::Blog'
          and method = 'month_archive'
          and argument like ? || ' %'
        order by argument
    });

    # Keep a count of how many months in total have been included in the
    # menu, so that I can decide not to include any more for older years.
    my $months_included = 0;

    my @menu;
    $year_sth->execute($root_file->{wc_id}, $root_file->{guid_id});
    while (my ($year_url, $year) = $year_sth->fetchrow_array) {
        my @months;
        push @menu, {
            (defined $cur_year_arg && $cur_year_arg eq $year ? () :
                (link => URI->new($year_url)->rel($cur_url))),
            title => _year_archive_title($year),
            short_title => $year,
            children => \@months,
        };

        next if $months_included >= 6;

        $month_sth->execute($root_file->{wc_id}, $root_file->{guid_id},
                            sprintf('%04d', $year));
        while (my ($month_url, $month_arg) = $month_sth->fetchrow_array) {
            die unless $month_arg =~ /^\d+ (\d+)$/;
            my $month = $1;
            push @months, {
                (defined $cur_month_arg && $cur_month_arg eq $month_arg ? () :
                    (link => URI->new($month_url)->rel($cur_url))),
                title => _month_archive_title($year, $month),
                short_title => DateTime->new(year => $year, month => $month)
                                       ->strftime('%B'),
                children => [],
            };
        }
    }

    return \@menu;
}

=back

=head1 COPYRIGHT

This software is copyright 2006 Geoff Richards E<lt>geoff@laxan.comE<gt>.
For licensing information see this page:

L<http://www.daizucms.org/license/>

=cut

1;
# vi:ts=4 sw=4 expandtab
