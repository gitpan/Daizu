package Daizu::File;
use warnings;
use strict;

use Carp qw( croak );
use Carp::Assert qw( assert DEBUG );
use XML::LibXML;
use Encode qw( encode decode );
use Daizu::Wc;
use Daizu::Util qw(
    trim pgregex_escape
    parse_db_datetime
    db_select db_select_col db_insert db_update
    wc_file_data
    instantiate_generator
);
use Daizu::HTML qw( dom_body_to_html4 absolutify_links );

=head1 NAME

Daizu::File - class representing files in working copies

=head1 DESCRIPTION

Each object of this class represents a particular file in a Daizu CMS
working copy (a record in the C<wc_file> table).

=head1 METHODS

Note that all the functions which return the value of a Subversion property
will strip leading and trailing whitespace, and treat a value which is empty
or entirely whitespace as if it wasn't set at all.

=over

=item Daizu::File-E<gt>new($cms, $file_id)

Return a new Daizu::File object for the file with the specified ID number.

=cut

sub new
{
    my ($class, $cms, $file_id) = @_;
    my $db = $cms->{db};

    my $record = $db->selectrow_hashref(q{
        select wc_id, guid_id, parent_id,
               is_dir, name, path,
               cur_revnum, modified, deleted,
               generator, base_url, article, retired,
               issued_at, title, description, content_type, modified_at,
               image_width, image_height, data_len
        from wc_file
        where id = ?
    }, undef, $file_id);
    croak "no file found with ID $file_id"
        unless defined $record;

    return bless {
        cms => $cms,
        db => $db,
        id => $file_id,
        %$record,
    }, $class;
}

=item $file-E<gt>data

Return a reference to a string containing the file data (content).

=cut

sub data
{
    my ($self) = @_;
    return wc_file_data($self->{db}, $self->{id});
}

=item $file-E<gt>wc

Return a L<Daizu::Wc> object representing the working copy in which this
file lives.

=cut

sub wc
{
    my ($self) = @_;
    return Daizu::Wc->new($self->{cms}, $self->{wc_id});
}

=item $file-E<gt>guid_uri

Return the GUID URI for this file.

=cut

sub guid_uri
{
    my ($self) = @_;
    return db_select($self->{db}, file_guid => $self->{guid_id}, 'uri');
}

=item $file-E<gt>directory_path

Returns the path of a directory, either the same as the file if it's a
directory itself, or the path of its parent directory, or '' if it's at
the top level.

=cut

sub directory_path
{
    my ($self) = @_;
    my $path = $self->{path};
    return $path if $self->{is_dir};
    return $path =~ m!^(.*)/[^/]+\z! ? $1 : '';
}

=item $file-E<gt>permalink

Returns the first URL generated by the file, which will be the URL you
want to link to most of the time.  For articles this will always be the
normal HTML version of the article, even if there are also other URLs
available for it, and it will always be the first page of multipage
articles.  For non-article files there is no guarantee about what this
will return, but most will only generate a single URL anyway, and for
those that don't generators are likely to return the most 'linkable' URL
first.

The URL returned is an absolute URL provided as a L<URI> object.

Returns nothing if the file doesn't generate any URLs.

There are some cases where this might not be what you want.  For
example, the root directory of a website using L<Daizu::Gen> will
either not generate a URL at all, or will generate one for a Google
sitemap XML file, neither of which is likely to be useful for linking.
To get the URL of the website you would probably need to find a file
called something like '_index.html'.  On the other hand, the
L<Daizu::Gen::Blog> generator will give you a sensible URL for the
blog homepage if you call this on its root directory.

=cut

sub permalink
{
    my ($self) = @_;
    my ($permalink) = $self->generator->urls_info($self);
    return unless defined $permalink;
    return $permalink->{url};
}

=item $file-E<gt>urls_in_db($method, $argument)

Return a list of the URLs (plain strings, each an absolute URI) of the file
which have the specified method and argument values, drawing from the
C<url> table in the database.

=cut

sub urls_in_db
{
    my ($self, $method, $argument) = @_;

    my %criteria = (
        wc_id => $self->{wc_id},
        guid_id => $self->{guid_id},
        status => 'A',
    );

    $criteria{method} = $method
        if defined $method;
    $criteria{argument} = $argument
        if defined $argument;

    return db_select_col($self->{db}, url => \%criteria, 'url');
}

=item $file-E<gt>article_urls

Return information about the URLs which the file should have, if it
is an article.  Fails if it isn't.

The URLs are returned in the same format as the
L<Daizu::Gen method custom_urls_info|Daizu::Gen/$gen-E<gt>custom_urls_info($file)>, and
should be used within implementations of that method to ensure that
articles get the proper URLs even if an article parser plugin or
DOM filtering plugin has changed the usual forms.

There are two sets of URLs returned, as a single list:

=over

=item *

URLs for the pages of the actual article, as normal webpages published
through the templating system.  There will always be at least one of
these, which will be the first URL returned.  It will have a method of
'article', an empty argument string, and a content type of 'text/html'.
The generator class is likely to be L<Daizu::Gen>, although it doesn't
have to be.  The URL for this first article page will be the one set
with the L<set_article_pages_url()|/$file-E<gt>set_article_pages_url($url)>
method, or
empty string by default.  If the article has multiple pages, this URL
info will be followed by others, one for each subsequent page, which
will be identical except for the actual URL and the argument, which
will contain the page number (starting from '2' for the second page).

The first 'article' page URL is the one which should be used when linking
to an article, unless you have some special reason to link to a particular
page or an alternative URL for the same file.  For example, this is
the URL which will be included in blog feeds and navigation menus.
To get at it conveniently, see the L<permalink()|/$file-E<gt>permalink> method.

=item *

There may be additional URLs for supplementary resources generated by
plugins, although by default a simple article written in XHTML won't
have any 'extra' URLs.  These URLs are the ones added with the
L<add_extra_url()|/$file-E<gt>add_extra_url($url, $mime_type, $generator_class, $method, $argument)>
method.  One example of an 'extra'
URL is a POD file (Perl documentation, like this document itself)
published with the L<Daizu::Plugin::PodArticle> plugin.  If the filename
of the POD file ends in '.pm', then this plugin will add an extra
URL for the original source code, since that might be of interest
to programmers reading API documentation.

=back

=cut

# Used by article_urls() below.  Uses some crufty heuristics to decide
# how pages (other than the first page) of articles should be referenced.
# $url should be the URL of the article's first page, which is likely to
# be the empty string or 'filename.html', although it could be an absolute
# URL.  It's up to the generator class.
sub _pagify_url
{
    my ($url, $page) = @_;
    assert($page > 0) if DEBUG;
    return $url if $page == 1;
    return "page$page.html" if $url eq '';
    return "$url/page$page.html" if $url =~ m!/$!;
    $url =~ s!\.([^/.]+)$!-page$page.$1! or $url .= "-page$page.html";
    return $url;
}

sub article_urls
{
    my ($self) = @_;

    $self->ensure_article_loaded;
    croak "file is not an article"
        unless $self->{article};

    my @page_urls = map {
        {
            url => _pagify_url($self->{article_pages_url}, $_),
            generator => (ref $self->generator),
            method => 'article',
            argument => ($_ == 1 ? '' : $_),
            type => 'text/html',
        }
    } (1 .. scalar @{$self->{page_start}});

    return @page_urls, @{$self->{extra_url}};
}

=item $file-E<gt>parent

Return a new Daizu::File object representing this file's parent directory.
Returns nothing if this file is at the 'top level' of its branch and so has
no parent.

=cut

sub parent
{
    my ($self) = @_;
    return unless defined $self->{parent_id};
    return Daizu::File->new($self->{cms}, $self->{parent_id});
}

=item $file-E<gt>issued_at

Return a L<DateTime> object for the publication date and time of the file.
All files have an 'issued' date, either specified explicitly in a
C<dcterms:issued> property, or determined from the time at which the file
was first committed into the Subversion repository (which is assumed to
be about the time it was first published).

=cut

sub issued_at
{
    my ($self) = @_;
    return parse_db_datetime($self->{issued_at});
}

=item $file-E<gt>modified_at

Return a L<DateTime> object for the last-updated date and time of the file.
This is always defined.  The value is either specified explicitly in a
C<dcterms:modified> property, or determined from the time of the last commit
which modified or renamed the file.

=cut

sub modified_at
{
    my ($self) = @_;
    return parse_db_datetime($self->{modified_at});
}

=item $file-E<gt>property($name)

Return the value of the Subversion property C<$name> on this file, or
C<undef> if there is no such property.

=cut

sub property
{
    my ($self, $name) = @_;
    return db_select($self->{db}, 'wc_property',
        { file_id => $self->{id}, name => $name },
        'value',
    );
}

=item $file-E<gt>most_specific_property($name)

Return the value of the Subversion property C<$name> on this file, or on its
closest ancestor if it has no such property.  Therefore properties on
subdirectories will override those of their parent directories.  Returns
C<undef> if there is no property of this name on the file or any of its
ancestors.

=cut

sub most_specific_property
{
    my ($file, $name) = @_;

    while (defined $file) {
        my $value = $file->property($name);
        return trim($value)
            if defined $value && $value =~ /\S/;
        $file = $file->parent;
    }

    return undef;
}

=item $file-E<gt>least_specific_property($name)

Return the value of the Subversion property C<$name> on this file, or on its
most distant ancestor if it has no such property.  Therefore the return
value is the 'top level' value for this property.  For example, if you ask
for the C<dc:title> property then you might get the title of the website
of which C<$file> is a part.  Returns C<undef> if there is no property of
this name on the file or any of its ancestors.

=cut

sub least_specific_property
{
    my ($file, $name) = @_;

    my $best;
    while (defined $file) {
        my $value = $file->property($name);
        $best = trim($value)
            if defined $value && $value =~ /\S/;
        $file = $file->parent;
    }

    return $best;
}

=item $file-E<gt>homepage_file

Return the file which most probably represents the 'homepage' of the
website on which C<$file> will be published.  This will be the file
closest to the top level of the filesystem hierarchy which has a
C<daizu:url> property set.

It is possible for this to return C<$file> itself if there is nothing
above it with a URL.  Returns C<undef> if not even C<$file> has a URL
set, in which case it can't have a homepage because it won't be published
itself.

=cut

sub homepage_file
{
    my ($file) = @_;

    my $best;
    while (defined $file) {
        $best = $file if defined $file->{base_url};
        $file = $file->parent;
    }

    return $best;
}

=item $file-E<gt>title

Return the title of C<$file>, as a decoded Perl text string, or C<undef>
if the file doesn't have a title.  The title is taken from the file's
C<dc:title> property if it has one, or from the C<dc:title> property of
one of its ancestors failing that.

This ensures that the article has been fully loaded, so that if the
article parser plugin sets a title for it, that will get used.

=cut

sub title
{
    my ($self) = @_;
    $self->ensure_article_loaded;
    my $title = $self->{title};
    $title = $self->most_specific_property('dc:title')
        unless defined $title;
    return undef unless defined $title;
    return decode('UTF-8', $title, Encode::FB_CROAK);
}

=item $file-E<gt>short_title

Same as the L<title() method|/$file-E<gt>title> above, except that if
the file or any of its ancestors have a C<daizu:short-title> property
then that is used in preference to C<daizu:title>.

=cut

sub short_title
{
    my ($self) = @_;
    $self->ensure_article_loaded;
    my $title = $self->{short_title};
    $title = $self->most_specific_property('daizu:short-title')
        unless defined $title;
    $title = $self->{title}
        unless defined $title;
    $title = $self->most_specific_property('dc:title')
        unless defined $title;
    return undef unless defined $title;
    return decode('UTF-8', $title, Encode::FB_CROAK);
}

=item $file-E<gt>description

Return the description/summary of C<$file>, as a decoded Perl text string,
or C<undef> if the file doesn't have a description.  The value is taken from
the file's C<dc:description> property if it has one.

This ensures that the article has been fully loaded, so that if the
article parser plugin sets a description for it, that will get used.

=cut

sub description
{
    my ($self) = @_;
    $self->ensure_article_loaded;
    my $description = $self->{description};
    return undef unless defined $description;
    return decode('UTF-8', $description, Encode::FB_CROAK);
}

=item $file-E<gt>generator

Create and return a generator object for the file C<$file>.
Figures out which generator class to use,
by looking at the C<daizu:generator> property for the file, and if
necessary its ancestors.  The class is loaded automatically.
It also knows to use L<Daizu::Gen> if no generator specification is found.

Returns the new object, which should support the API of class L<Daizu::Gen>.

=cut

{
    my %cache;  # TODO - should probably move this to instantiate_generator()

    sub generator
    {
        my ($self) = @_;
        return $self->{generator_obj} if exists $self->{generator_obj};
        my $cms = $self->{cms};

        my $root_file = $self;
        my $gen_class;
        # TODO - might be better to do this with recursion: $parent->generator
        while (1) {
            return $cache{$root_file->{id}}
                if exists $cache{$root_file->{id}};

            if (defined $root_file->{generator}) {
                $gen_class = $root_file->{generator};
                last;
            }
            else {
                my $parent = $root_file->parent;
                if (defined $parent) {
                    $root_file = $parent;
                    next;
                }
            }

            last;
        }

        my $generator = instantiate_generator($cms, $gen_class, $root_file);

        $self->{generator_obj} = $cache{$root_file->{id}} = $generator;
        return $generator;
    }
}

=item $file-E<gt>ensure_article_loaded

Updates C<$file> to include full article information, including the DOM
of the content of the article.  Does nothing if the file isn't an article.
Fails if it is but there are no plugins able to load it.

This is where article parser plugins set with the L<Daizu> method
L<add_article_parser()|Daizu/$cms-E<gt>add_article_parser($mime_type, $path, $object, $method)>
are invoked.

Doesn't return anything.

=cut

sub ensure_article_loaded
{
    my ($self) = @_;
    return unless $self->{article};
    return if $self->{article_loaded};

    croak "article already being loaded" if $self->{article_now_loading};
    local $self->{article_now_loading} = 1;

    $self->{extra_url} = [];
    $self->{article_pages_url} = '';

    my $cms = $self->{cms};
    my $mime_type = $self->{content_type};
    if (!defined $mime_type) {
        # Articles must have a mime type, but allow a default based on file
        # extension for the built-in XHTML format.
        croak "article in file '$self->{path}' has no mime type specified"
            unless $self->{name} =~ /\.html?$/i;
        $mime_type = 'text/html';
    }
    $mime_type =~ m!^(.+?)/!
        or croak "bad article mime type '$mime_type' in file '$self->{path}'";
    my $mime_type_family = "$1/*";

    # Search through applicable MIME type patterns.
    my $file_path = $self->{path};
    for my $match ($mime_type, $mime_type_family, '*') {
        next unless exists $cms->{article_parsers}{$match};
        my $plugins = $cms->{article_parsers}{$match};

        # Search through applicable paths, sorting in reverse order of length
        # so that the most specific configuration gets tested first.
        for my $match_path (sort { length $b <=> length $a } keys %$plugins) {
            next unless
                $match_path eq '' || $match_path eq $file_path ||
                substr($file_path, 0, length $match_path + 1) eq "$match_path/";

            # Search through the plugins we've found to find one which
            # accepts the file.
            for my $handler (@{$plugins->{$match_path}}) {
                my ($object, $method) = @$handler;
                next unless $object->$method($cms, $self);

                $self->_filter_loaded_article;
                return;
            }
        }
    }

    die "can't parse article $self->{id}," .
        " don't know how to handle content type '$mime_type'";
}

sub _filter_loaded_article
{
    my ($self) = @_;
    my $cms = $self->{cms};

    # Filter through plugins.
    my $doc = $self->{article_doc};
    my $file_path = $self->{path};

    # Go through the known filters in an arbitrary order.
    FILTER: for my $plugins (values %{$cms->{html_dom_filters}}) {
        # Search through applicable paths, sorting in reverse order of length
        # so that the most specific configuration gets tested first.
        for my $match_path (sort { length $b <=> length $a } keys %$plugins) {
            next unless
                $match_path eq '' || $match_path eq $file_path ||
                substr($file_path, 0, length $match_path + 1) eq "$match_path/";

            my ($object, $method) = @{$plugins->{$match_path}};
            $doc = $object->$method($cms, $doc);

            # Only execute the best match for each filter.
            next FILTER;
        }
    }

    # Find out where fold and page breaks are, and remove the markers.
    my $node = $doc->documentElement->firstChild;
    my $fold;
    my @page_start;
    push @page_start, $node;
    while (defined $node) {
        my $next = $node->nextSibling;
        last unless defined $next;

        if ($node->nodeType == XML_ELEMENT_NODE) {
            my $ns = $node->namespaceURI;
            push @page_start, $next
                if defined $ns && $ns eq $Daizu::HTML_EXTENSION_NS &&
                   $node->localname eq 'page';
            if (defined $ns && $ns eq $Daizu::HTML_EXTENSION_NS &&
                $node->localname eq 'fold')
            {
                croak "only one <daizu:fold/> is allowed in an article"
                    if defined $fold;
                $fold = $node;
            }
        }

        $node = $next;
    }

    $self->{article_doc} = $doc;
    $self->{fold} = defined $fold ? $fold
                  : @page_start > 1 ? $page_start[1]->previousSibling
                  : undef;
    $self->{page_start} = \@page_start;
    $self->{article_loaded} = 1;
}

=item $file-E<gt>init_article_doc

This can be used by plugins which know how to read the content of a
file and turn it into an article document.  It creates an empty
document (an L<XML::LibXML::Document> object) with a C<body> root
element in the XHTML namespace, and stores it so that the
L<article_doc()|/$file-E<gt>article_doc([$doc])> and
L<article_body()|/$file-E<gt>article_body> methods
can return it.  The document object is also returned from this method.
Dies if the file is not an article.

=cut

sub init_article_doc
{
    my ($self) =  @_;
    croak "article document already created"
        if exists $self->{article_doc};
    croak "file is not an article"
        unless $self->{article};

    my $doc = XML::LibXML::Document->new('1.0', 'UTF-8');
    $doc->setDocumentElement(
        $doc->createElementNS('http://www.w3.org/1999/xhtml', 'body'),
    );

    return $self->{article_doc} = $doc;
}

=item $file-E<gt>article_doc([$doc])

Returns an L<XML::LibXML::Document> object representing the
content of the article, loading the article's content first if
necessary.  Dies if the file is not an article.

If the argument C<$doc> is provided, sets the file's article content
to that value.  This can only be done once.

=cut

sub article_doc
{
    my ($self, $newdoc) = @_;

    if (defined $newdoc) {
        croak "file already has an article document"
            if exists $self->{article_doc};
        return $self->{article_doc} = $newdoc;
    }

    $self->ensure_article_loaded unless exists $self->{article_dic};
    croak "file is not an article"
        unless $self->{article};

    return $self->{article_doc};
}

=item $file-E<gt>article_body

Returns an L<XML::LibXML::Element> object representing the
root C<body> element of the content of the article, loading the
article's content first if necessary.  Dies if the file is not an article.

=cut

sub article_body
{
    my ($self) = @_;
    $self->ensure_article_loaded unless exists $self->{article_doc};
    croak "file is not an article"
        unless $self->{article};

    return $self->{article_doc}->documentElement;
}

=item $file-E<gt>article_content_html4([$page_num])

Returns the content of an article file as S<HTML 4>.  If C<$page_num>
is provided, only returns the content for that page, otherwise for
the whole article.  Fails if the file is not an article, or if
C<$page_num> is greater than the number of pages (C<$page_num> would
be 0 for the first page, not zero).

C<$page_num> can be C<undef> to select the whole article, and making
it the empty string has the same effect (to make this easier to use
from within templates).

=cut

sub article_content_html4
{
    my ($self, $page_num) = @_;

    # Make sure it's loaded before we look at how many pages it has got.
    my $doc = $self->article_doc;

    my ($start_node, $end_node);
    if (defined $page_num && $page_num ne '') {
        croak "page $page_num out of range for this article"
            if $page_num < 1 || $page_num > @{$self->{page_start}};
        $start_node = $self->{page_start}[$page_num - 1];
        $end_node = $self->{page_start}[$page_num];
    }

    return dom_body_to_html4($doc, $start_node, $end_node);
}

=item $file-E<gt>article_extract

Returns a short extract (up to a certain number of words) from the beginning
of the article's content, with all markup removed.  What's left is plain
text, except that the text from different top-level elements in the document
is separated by two newlines.  The text returned is not XML escaped.

=cut

sub article_extract
{
    my ($self) = @_;

    my $block_elem = $self->article_body->firstChild;

    my $max_words = 50;     # TODO - make configurable.
    my @words;

    while (@words <= $max_words && defined $block_elem) {
        $block_elem = $block_elem->nextSibling, next
            unless $block_elem->nodeType == XML_ELEMENT_NODE;

        $words[-1] .= "\n\n" if @words && $words[-1] !~ /\n\z/;

        my @new_words = split ' ', trim($block_elem->textContent);
        while (@words <= $max_words && @new_words) {
            push @words, shift @new_words;
        }

        $block_elem = $block_elem->nextSibling;
    }

    if (@words > $max_words) {
        pop @words;
        push @words, "\x{2026}";
    }

    my $text = join ' ', @words;
    $text =~ s/\n /\n/g;
    return $text;
}

=item $file-E<gt>set_article_pages_url($url)

Set the URL for the actual article's HTML page.  This will usually be
a relative URL, for example just a filename or the empty string.
It will be resolved relative to the 'base URL' provided by the file's
generator.

If the article has multiple pages, this URL will be used for the first
page and the subsequent ones will be generated automatically based on it.
See the L<article_urls()|/$file-E<gt>article_urls> method for details of how this
affects the URLs generated by an article file.

=cut

sub set_article_pages_url
{
    my ($self, $url) = @_;
    $self->{article_pages_url} = $url;
}

=item $file-E<gt>add_extra_url($url, $mime_type, $generator_class, $method, $argument)

Add an extra URL for a resource associated with the article.  This could
be used for example by a plugin which generates a printer-friendly PDF
version of an article to add the URL for the PDF file.

C<$argument> is optional, and defaults to the empty string.

Any URL information added here by plugins will be returned by the
L<article_urls()|/$file-E<gt>article_urls> method.

=cut

sub add_extra_url
{
    my ($self, $url, $mime_type, $generator_class, $method, $arg) = @_;
    push @{$self->{extra_url}}, {
        url => $url,
        generator => $generator_class,
        method => $method,
        argument => (defined $arg ? $arg : ''),
        type => $mime_type,
    };
}

=item $file-E<gt>add_article_extras_template($filename)

TODO

TODO - this should apply to the file as a whole, but to individual URLs

=cut

sub add_article_extras_template
{
    my ($self, $filename) = @_;
    push @{$self->{article_extras_templates}}, $filename;
}

=item $file-E<gt>article_extras_templates

TODO

=cut

sub article_extras_templates
{
    my ($self) = @_;
    return unless $self->{article_extras_templates};
    return @{$self->{article_extras_templates}};
}

=item $file-E<gt>tags

Return a list of tags which have been applied to this article.  The
list comes ultimately from the C<daizu:tags> property, although it is
loaded into the database tables C<tag> and C<wc_file_tag> when the
working copy is updated.  The tags are returned sorted by canonical tag
name.

A list is returned, each item of which is a hashref containing the
following values:

=over

=item tag

The canonical tag name, as used as the primary key in the C<tag> table.

=item original_spelling

The spelling used for to name the tag in the C<daizu:tags> property of
this file.

=back

=cut

sub tags
{
    my ($self) = @_;

    my $sth = $self->{cms}{db}->prepare(q{
        select t.tag, ft.original_spelling
        from tag t
        inner join wc_file_tag ft on ft.tag = t.tag
        where ft.file_id = ?
        order by t.tag
    });
    $sth->execute($self->{id});

    my @tags;
    while (my $row = $sth->fetchrow_hashref) {
        push @tags, { %$row };
    }

    return @tags;
}

=item $file-E<gt>article_snippet

Return an L<XML::LibXML::Document> object representing the part of
an article which comes before the fold, or before the first page break
(whichever comes first).  If there are no fold markers or page breaks
in the article, returns the complete article content.

=cut

sub article_snippet
{
    my ($self) = @_;
    return $self->{snippet_doc} if exists $self->{snippet_doc};

    my $whole_doc = $self->article_doc;
    my $fold = $self->{fold};
    return $whole_doc
        unless defined $fold;

    my $snippet_doc = XML::LibXML::Document->new('1.0', 'UTF-8');
    my $body = $snippet_doc->createElementNS('http://www.w3.org/1999/xhtml',
                                             'body');
    $snippet_doc->setDocumentElement($body);

    my $elem = $whole_doc->documentElement->firstChild;
    while (defined $elem && !$elem->isSameNode($fold)) {
        $body->appendChild($elem->cloneNode(1));
        $elem = $elem->nextSibling;
    }

    return $self->{snippet_doc} = $snippet_doc;
}

=item $file-E<gt>article_snippet_html4

Returns a chunk of S<HTML 4> markup for the article's content, just as the
L<article_content_html4() method|/$file-E<gt>article_content_html4([$page_num])>
does, except that this only returns the content up to the fold or first
page break, if the article has any of those.

This also sets an internal flag called C<snippet_is_not_whole_article> to
true if the content returned represents a truncated version of the article's
content (that is, there was a fold mark or page break found).

=cut

sub article_snippet_html4
{
    my ($self) = @_;
    my $snippet_doc = $self->article_snippet;
    $self->{snippet_is_not_whole_article} = 1
        unless $snippet_doc->isSameNode($self->article_doc);

    # This is going to be shown on the homepage or something, so links won't
    # be relative to the output page's URL.
    absolutify_links($snippet_doc, $self->permalink);

    # TODO - this could be more efficient if we passed in the fold position.
    return dom_body_to_html4($snippet_doc);
}

=item $file-E<gt>authors

Returns information about the author or authors credited with creating
the file.  The return value is a reference to an array of zero or more
references to hashes.
Each one contains the following keys:

=over

=item id

The ID number of the entry in the database's C<person> table.

=item username

The username, as specified in the C<daizu:author> property, decoded
into a Perl text string.  Always defined.

=item name

Full name of the author, as a Perl text string.  Always defined.

=item email

Email address as a binary string, or C<undef>.

=item uri

A URL associated with the author, probably their own website, or C<undef>.

=back

The authors are returned in the same order that they are specified in
the C<daizu:author> property.

Note that because of the way the standard property loader works, directories
are not considered to have authors.  If a directory has a C<daizu:author>
property, that will just affect all the files within it.

=cut

sub authors
{
    my ($self) = @_;
    my $db = $self->{cms}{db};

    # Build a PostgreSQL regular expression which will be used to select
    # all the 'person_info' records with a path which applies to the file,
    # in order to select the most specific one (with the longest path).
    my @path = map { pgregex_escape($_) }
               split '/', $self->{path};
    my $path_regex = '^(' . join('(/', @path) . '$' . ('|$)' x @path);

    my $sth = $db->prepare(q{
        select person_id
        from file_author
        where file_id = ?
        order by pos
    });
    $sth->execute($self->{id});

    my @author;
    while (my ($id) = $sth->fetchrow_array) {
        my $info = $db->selectrow_hashref(q{
            select p.id, p.username, i.name, i.email, i.uri
            from person p
            inner join person_info i on i.person_id = p.id
            where p.id = ?
              and i.path ~ ?
            order by length(i.path) desc
        }, undef, $id, $path_regex);
        croak "no 'person_info' record for user $id at path '$self->{path}'"
            unless defined $info;
        for (qw( username name )) {
            $info->{$_} = decode('UTF-8', $info->{$_}, Encode::FB_CROAK);
        }
        push @author, { %$info };
    }

    return \@author;
}

=item $file-E<gt>update_urls_in_db

Updates the C<url> table to match the current URLs generated by C<$file>,
as returned by the generator method
L<urls_info()|Daizu::Gen/$gen-E<gt>urls_info($file)>.
This includes changing active URLs to redirects or marking them 'gone'
if they are no longer generated by the file.

Returns a list of two values, which can each be either true or false.
They indicate whether the set of URLs which are redirects or marked as
'gone' have changed.  The first indicates that at least one redirect has
been added, removed, or had its destination changed.  The second value
indicates that a previously active or redirected URL is now marked 'gone',
or that a previously dead URL has been reactivated or turned into a redirect.
These two values can be used to determine whether redirect maps need to
be regenerated by the caller.

The work is done in a transaction, so that if it fails there will be
no changes to the database.

=cut

sub update_urls_in_db
{
    my ($self) = @_;
    my $db = $self->{cms}{db};

    $db->begin_work;

    my $sth = $db->prepare(q{
        select *
        from url
        where wc_id = ?
          and guid_id = ?
    });
    $sth->execute($self->{wc_id}, $self->{guid_id});

    # Get information about the URLs that we currently have for this file.
    my (%old_active, %old_redirect, %old_gone);
    while (my $r = $sth->fetchrow_hashref) {
        my $hash = $r->{status} eq 'A' ? \%old_active :
                   $r->{status} eq 'R' ? \%old_redirect :
                                         \%old_gone;
        $hash->{$r->{url}} = { %$r };
    }

    # Keep track of whether the set of redirects or gone files have changed,
    # which might mean that the caller will need to regenerate some redirect
    # files.
    my ($redirects_changed, $gone_changed);

    # Put the new URLs in the database.  Add the 'id' of each one to the
    # information in @new_url.
    my @new_url = $self->generator->urls_info($self);
    for (@new_url) {
        my $url = $_->{url};
        if (exists $old_active{$url}) {
            # Was active, and still is.
            my $id = $_->{id} = $old_active{$url}{id};
            db_update($db, url => $id,
                method => $_->{method},
                argument => $_->{argument},
                content_type => $_->{type},
            );
            delete $old_active{$url};
        }
        elsif (exists $old_redirect{$url}) {
            # Was a redirect, but now active again.
            my $id = $_->{id} = $old_redirect{$url}{id};
            db_update($db, url => $id,
                method => $_->{method},
                argument => $_->{argument},
                content_type => $_->{type},
                status => 'A',
                redirect_to_id => undef,
            );
            delete $old_redirect{$url};
            $redirects_changed = 1;
        }
        elsif (exists $old_gone{$url}) {
            # Was gone, but has come back.
            my $id = $_->{id} = $old_gone{$url}{id};
            db_update($db, url => $id,
                method => $_->{method},
                argument => $_->{argument},
                content_type => $_->{type},
                status => 'A',
            );
            delete $old_gone{$url};
            $gone_changed = 1;
        }
        else {
            # New URL.  It might replace a non-active one belonging to a
            # different file.
            my ($id, $status) = db_select($db, 'url',
                { wc_id => $self->{wc_id}, url => $url },
                qw( id status ),
            );
            if (defined $id) {
                if ($status eq 'A') {
                    $db->rollback;
                    croak "new URL '$url' would conflict with existing URL";
                }
                elsif ($status eq 'R') {
                    $redirects_changed = 1;
                }
                elsif ($status eq 'G') {
                    $gone_changed = 1;
                }
                $_->{id} = $id;
                $_->{id} = db_update($db, url => $id,
                    guid_id => $self->{guid_id},
                    method => $_->{method},
                    argument => $_->{argument},
                    content_type => $_->{type},
                    status => 'A',
                    redirect_to_id => undef,
                );
            }
            else {
                # This is the only place where new 'url' records are inserted.
                $_->{id} = db_insert($db, 'url',
                    url => $url,
                    wc_id => $self->{wc_id},
                    guid_id => $self->{guid_id},
                    generator => $_->{generator},
                    method => $_->{method},
                    argument => $_->{argument},
                    content_type => $_->{type},
                    status => 'A',
                );
            }
        }
    }

    # Adjust any previously-active URLs which are no longer active.
    for (values %old_active) {
        if (!@new_url) {
            # Nothing to redirect to, so mark the old one as gone.
            db_update($db, url => $_->{id},
                status => 'G',
            );
            $gone_changed = 1;

            # Also mark as gone any URLs which were redirects to this one.
            my $n = db_update($db, url => { redirect_to_id => $_->{id} },
                status => 'G',
                redirect_to_id => undef,
            );
            $redirects_changed = 1 if $n && $n > 0;
        }
        else {
            # Change it to a redirect, if there are any active URLs which
            # are suitable (same generator, method, and argument).  If there
            # are multiple choices, choose the one with the same content type,
            # or the first of any ties.
            my $best_match;
            for my $new (@new_url) {
                next unless $new->{generator} eq $_->{generator} &&
                            $new->{method} eq $_->{method} &&
                            $new->{argument} eq $_->{argument};

                $best_match = $new
                    unless defined $best_match;
                next unless $new->{type} eq $_->{content_type};

                $best_match = $new;
                last;
            }

            if (defined $best_match) {
                # Set old URL to redirect.
                db_update($db, url => $_->{id},
                    content_type => $best_match->{type},
                    status => 'R',
                    redirect_to_id => $best_match->{id},
                );
                $redirects_changed = 1;

                # Adjust any which previously redirected to the old URL
                # so that they point directly to the new one.
                db_update($db, url => { redirect_to_id => $_->{id} },
                    content_type => $best_match->{type},
                    redirect_to_id => $best_match->{id},
                );
            }
            else {
                # Kill the old URL and any which redirect to it.
                db_update($db, url => $_->{id},
                    status => 'G',
                );
                db_update($db, url => { redirect_to_id => $_->{id} },
                    status => 'G',
                    redirect_to_id => undef,
                );
                $gone_changed = 1;
            }
        }
    }

    $db->commit;

    return ($redirects_changed, $gone_changed);
}

=back

=head1 COPYRIGHT

This software is copyright 2006 Geoff Richards E<lt>geoff@laxan.comE<gt>.
For licensing information see this page:

L<http://www.daizucms.org/license/>

=cut

1;
# vi:ts=4 sw=4 expandtab
