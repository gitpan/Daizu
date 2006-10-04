package Daizu::Gen;
use warnings;
use strict;

use Carp qw( croak );
use Carp::Assert qw( assert DEBUG );
use Template;
use XML::LibXML;
use Compress::Zlib qw( gzopen $gzerrno );
use URI;
use Encode qw( decode encode );
use File::Temp qw( tempfile );
use Daizu::TTProvider;
use Daizu::HTML qw(
    dom_body_to_html4
);
use Daizu::Util qw(
    trim like_escape pgregex_escape
    w3c_datetime parse_db_datetime
    db_select
    add_xml_elem xml_attr
    daizu_data_dir
);

=head1 NAME

Daizu::Gen - default generator class

=head1 DESCRIPTION

This class, and subclasses of it, are responsible for deciding which
URLs should be created (generated) from each file or directory in a
working copy, and generating the output which will be served for those
URLs.  This class itself is used by default, but you can use a
different generator class by setting the C<daizu:generator> property
to the name of a Perl module and class.  If you set it on a file,
it will affect only that file.  If you set it on a directory then it
will affect that directory and all its descendants, unless they themselves
have a C<daizu:generator> property.

This class creates URLs based on the C<daizu:url> property, and the
names of files and directories.  The results will be similar to the
URLs that the filesystem would have if they were served directly from
a webserver.  Files with names like C<_index.html> (anything starting
with C<_index> followed by a dot) are special in that the filename will
not appear as part of the URL.  Instead the URL will end with a trailing
slash (C</>).

With this generator class only files generate URLs.  Directories are
ignored, except when a Google sitemap is configured as described below.

TODO - provide a whole section giving guidance on subclassing this.
Include an example of a C<*_urls_info()> override which calls its
superclass version, like C<root_dir_urls_info()> in L<Daizu::Gen::Blog>.

=head1 CONFIGURATION

The only configuration information which this generator currently makes use
of is the C<google-sitemap> element shown here:

=for syntax-highlight xml

    <config path="example.com">
     <generator class="Daizu::Gen">
      <google-sitemap />
     </generator>
    </config>

The sitemap URL will be generated from the directory at the path indicated.
It must be a directory, not a plain file.  In this case, the sitemap is
likely to have a URL like C<http://example.com/sitemap.xml.gz>.

The C<google-sitemap> element may an optional C<url> attribute, which
should be a relative or absolute URL at which to publish the sitemap file.
Its default value is I<sitemap.xml.gz>

=head1 METHODS

=over

=item Daizu::Gen-E<gt>new(%options)

Return a new generator object.  Requires the following options:

=over

=item cms

A L<Daizu> object.

=item root_file

A L<Daizu::File> object for the file on which this generator was specified,
or a top-level directory if there was no specification of which generator
was in use.  So usually this file will have a C<daizu:generator>
property naming this class.

=item config_elem

The XML DOM node (an L<XML::LibXML::Element> object) of a C<generator>
element in the Daizu CMS configuration file, or C<undef> if there is no
appropriate configuration provided.

=back

=cut

sub new
{
    my ($class, %option) = @_;
    for (qw( cms root_file )) {
        croak "missing required option '$_'"
            unless defined $option{$_};
    }
    return bless \%option, $class;
}

=item $gen-E<gt>base_url($file)

Return a single URL for C<$file>, as a L<URI> object.  This 'base URL'
is typically used as the basis for any other URLs the file might generate.

Files with a C<daizu:url> property will take that as their base URL.

Directories can have base URLs even if they don't actually generate any
URLs in the publication process, since those URLs are used to build URLs
for any content they contain.  Directory URLs end in a forward slash.

Files with names starting with I<_index.> have a base URL identical to
their parent directory.

Returns C<undef> if there is no URL for this file.  This can happen if
the file's name is I<_hide> or I<_template>, or if it is contained in
a directory with a name like that, or if there is no C<daizu:url> property
for the file or any of its ancestors.

Subclasses should typically not override this, but instead override
L<custom_base_url()|/$gen-E<gt>custom_base_url($file)>,
as the blog generator does for example.

=cut

sub base_url
{
    my ($self, $file) = @_;
    croak 'usage: $gen->base_url($file)'
        unless defined $file;

    # Files in directories like '_hide' don't have URLs.
    return undef if $file->{name} =~ /\A(?:$Daizu::HIDING_FILENAMES)\z/o;

    # URL set with daizu:url property.
    return URI->new($file->{custom_url}) if defined $file->{custom_url};

    # No user-defined URL at top-level.
    return undef unless defined $file->{parent_id};

    return $self->custom_base_url($file);
}

=item $gen-E<gt>custom_base_url($file)

Override this method in a subclass if you want to use a custom URL
scheme, for example one based on publication dates instead of file
and directory names.

This method is called by L<base_url()|/$gen-E<gt>base_url($file)>.
By the time it has been called, checks have already been done for
the C<daizu:url> property, the special names like I<_hide>, and
the base URL of the parent directory, if any.  If these don't
determine the URL, or absence of one, then the C<custom_base_url()>
method should supply one, or return C<undef> if the file shouldn't
have a base URL.

If this is called then C<$file> is guaranteed to have a parent, but
its parent's base URL hasn't been determined, so it may not have one.

The default implementation just uses the base URL of the parent
and the name of the file or directory in the obvious way.

=cut

sub custom_base_url
{
    my ($self, $file) = @_;

    my $parent = $file->parent;
    my $parent_base = $parent->generator->base_url($parent);
    return undef unless defined $parent_base;

    return URI->new($file->{is_dir}              ? "$file->{name}/"
                  : $file->{name} =~ /^_index\./ ? ''
                                                 : $file->{name})
              ->abs($parent_base);
}

=item $gen-E<gt>urls_info($file)

Return a list of URLs generated by C<$file> (a L<Daizu::File> object).
May return nothing if the file doesn't generate any URLs.

This method calls the L<base_url()|/$gen-E<gt>base_url($file)> and
L<custom_urls_info()|/$gen-E<gt>custom_urls_info($file)> methods to do
the actual work.
All it does is resolve relative URLs and fill in some missing
information, so you're more likely to need to override those two,
or one of the C<*_urls_info> methods below,
if you want to build a new generator class with a differnet URL scheme.
This is what the L<Daizu::Gen::Blog> generator does.

Each URL value returned is actually a reference to a hash containing the
following keys, which are all required:

=over

=item url

The actual URL as a L<URI> object.  This will always be an absolute URL.

=item generator

The name of the class of generator which was used to create these URLs.

=item method

The name of the method which should be called to
generate the output for this file at this URL.

TODO - reference to docs for API of generator methods

=item argument

Some value which determines exactly which one of a set of URLs of the same
basic type this is.  For example if there were several URLs for an article,
one for each of several pages, then they would probably have the same
generator and method, but the page number would be stored as the argument.

The argument is always defined.  It will be the empty string if
L<custom_urls_info()|/$gen-E<gt>custom_urls_info($file)> didn't supply an
argument value.

=item type

The MIME type which the resource should be served with.

=back

This method returns nothing if the file has no URLs, for example if
it has no base URL (which might happen if it is in an I<_hide> directory).

=cut

sub urls_info
{
    my ($self, $file) = @_;

    my $base_url = $self->base_url($file);
    return unless defined $base_url;

    my @url = $self->custom_urls_info($file);

    # Resolve relative URLs against the file's base URL, and in the
    # process turn them into URI objects in case that's useful.
    # Also store the name of the generator class, and make sure there's
    # an argument, even if it's just the empty string.
    for (@url) {
        assert(defined $_->{url} && defined $_->{method}) if DEBUG;
        $_->{url} = URI->new_abs($_->{url}, $base_url);
        $_->{generator} = ref $self unless defined $_->{generator};
        $_->{argument} = '' unless defined $_->{argument};
    }

    # Check that the requirements for an article's permalink is met.
    assert(!$file->{article} ||
        (@url && $url[0]{method} eq 'article' && $url[0]{argument} eq '' &&
         $url[0]{type} eq 'text/html')) if DEBUG;

    return @url;
}

=item $gen-E<gt>custom_urls_info($file)

This is called by the L<urls_info()|/$gen-E<gt>urls_info($file)>
method above, and
does the actual work of supplying the URLs.  It should also return
a list of hashes for the URLs generated by C<$file>, but is allowed
to be a bit more lazy.  The following are the differences it may make
in return value (although note that it is permissible for this method
to return exactly the same values as for
L<urls_info()|/$gen-E<gt>urls_info($file)> if it wishes):

=over

=item *

The C<url> value doesn't have to be an absolute URL, and doesn't have
to be a L<URI> object.  If the URL desired is the same as the value
returned by the L<base_url()|/$gen-E<gt>base_url($file)> method,
then this value can simply be the empty string.

=item *

The C<generator> value may be omitted or undefined, in which case
it will default to the class name of C<$gen>.

=item *

The C<argument> value may be omitted or undefined, in which case
it will default to the empty string.

=back

The Daizu::Gen implementation of the method simply calls the four
C<*_urls_info> methods listed next as appropriate, so usually subclasses
should override those instead of this method.

=cut

sub custom_urls_info
{
    my ($self, $file) = @_;
    my @urls;

    if ($file->{is_dir}) {
        push @urls, $self->root_dir_urls_info($file)
            if $file->{id} == $self->{root_file}{id};
        push @urls, $self->dir_urls_info($file);
    }
    else {
        if ($file->{article}) {
            push @urls, $self->article_urls_info($file);
        }
        else {
            push @urls, $self->unprocessed_urls_info($file);
        }
    }

    return @urls;
}

=item $gen-E<gt>article_urls_info($file)

Return a list of URLs for an article.  C<$file> must be a L<Daizu::File>
object for a file which is an article.  Uses the
L<article_urls() method in Daizu::File|Daizu::File/$file-E<gt>article_urls>
to do the work, so this is just a simple wrapper to allow subclasses to
override it.

The return value is as specified for
L<custom_urls_info()|/$gen-E<gt>custom_urls_info($file)>.

=cut

sub article_urls_info
{
    my ($self, $file) = @_;
    return $file->article_urls;
}

=item $gen-E<gt>unprocessed_urls_info($file)

Return a list of URLs for the non-article non-directory file in C<$file>,
which must be a L<Daizu::File> object.

This base-class implementation returns a single URL which uses the
L<unprocessed() method|/$gen-E<gt>unprocessed($file, $urls)> in this class.

The return value is as specified for
L<custom_urls_info()|/$gen-E<gt>custom_urls_info($file)>.

The content type, if not defined by the file, will default to
C<application/octet-stream>.

=cut

sub unprocessed_urls_info
{
    my ($self, $file) = @_;

    my $type = $file->{content_type};
    $type = 'application/octet-stream'
        unless defined $type;

    return {
        generator => 'Daizu::Gen',
        url => '',
        method => 'unprocessed',
        type => $type,
    };
}

=item $gen-E<gt>dir_urls_info($file)

Return a list of URLs for the directory specified by C<$file>,
which should be a L<Daizu::File> object.  This base-class implementation
returns no URLs.

The return value is as specified for
L<custom_urls_info()|/$gen-E<gt>custom_urls_info($file)>.

=cut

sub dir_urls_info { () }

=item $gen-E<gt>root_dir_urls_info($file)

Return a list of URLs for the directory C<$file>, which should
be a L<Daizu::File> object for the root directory of the generator
(the directory which has the C<daizu:generator> property or a
top-level directory).  This base-class implementation returns no
URLs unless the configuration specifies that a Google sitemap should
be published, in which case it returns a single URL for the sitemap
file, using the
L<google_sitemap() method|/$gen-E<gt>google_sitemap($file, $urls)>.

If a file, rather than a directory, has a C<daizu:generator> property,
then this method isn't called and the file isn't distinguished
in any way for being the 'root file'.

The return value is as specified for
L<custom_urls_info()|/$gen-E<gt>custom_urls_info($file)>.

=cut

sub root_dir_urls_info
{
    my ($self, $file) = @_;

    my $conf = $self->{config_elem};
    return unless defined $conf;

    my ($elem, $extra) = $conf->getChildrenByTagNameNS($Daizu::CONFIG_NS,
                                                       'google-sitemap');
    return unless defined $elem;

    my $config_filename = $self->{cms}{config_filename};
    die "$config_filename: only one Google sitemap allowed on $file->{path}"
        if defined $extra;

    my $url = trim(xml_attr($config_filename, $elem, 'url',
                            'sitemap.xml.gz'));

    return {
        url => $url,
        method => 'google_sitemap',
        type => 'application/xml',
    };
}

=item $gen-E<gt>generate_web_page($file, $url, $template_overrides, $template_vars)

Use L<Template Toolkit|Template> to do the generation of the content for
C<$file> into the URL in C<$url> (which must be a reference to a URL info
hash).  C<$template_vars> should be a reference to a hash, and is passed to
the template, as are the values 'cms' (the L<Daizu> object), 'file' (C<$file>),
and 'url' (C<$url>).

If C<$template_overrides> is defined it should be a reference to a hash
containing template rewriting instructions.  Whenever a template is loaded
its name will be looked up in the hash.  If an entry is found, the template
named by the corresponding value is loaded instead of the original template.

L<Daizu::TTProvider> is used for loading the templates, so they will get
loaded directly from the working copy C<$file> is from.

TODO - exactly what format do these URL hashes have to be in?  There are
several alternatives in use in various places now.  Ah, no, these ones need
a filehandle at least.

=cut

sub generate_web_page
{
    my ($self, $file, $url, $template_overrides, $vars) = @_;
    croak "the URL must be a reference to a hash"
        unless ref $url && ref($url) eq 'HASH';
    my $cms = $self->{cms};

    my $provider = Daizu::TTProvider->new({
        daizu_cms => $cms,
        daizu_wc_id => $file->{wc_id},
        daizu_file_path => $file->directory_path,
        daizu_template_overrides => $template_overrides,
    });

    my $tt = Template->new({
        FILTERS => {
            encode => sub { encode('UTF-8', shift, Encode::FB_CROAK) },
        },
        LOAD_TEMPLATES => $provider,
        RECURSION => 1,
    }) or die $Template::ERROR;

    $tt->process('page.tt', {
        cms => $cms,
        file => $file,
        url => $url,
        generator => $self,
        %$vars,
    }, $url->{fh}) or die $tt->error;
}

=item $gen-E<gt>article_template_overrides($file, $url_info)

Returns a reference to a hash of template rewriting instructions for articles.
Each key should be the name of a template which is expected to be loaded
(perhaps by a L<Template Toolkit|Template> C<INCLUDE> directive), and the
value is the name of a different template which should be loaded instead.

These rewrites will be done for all articles generated by the
L<article() method|/$gen-E<gt>article($file, $urls)>.

The base-class implementation returns an empty hash reference.

=cut

sub article_template_overrides { {} }

=item $gen-E<gt>article_template_variables($file, $url_info)

Returns a reference to a hash of template variable values which should
be passed to L<Template Toolkit|Template> when an article page is generated.
The keys should be the names of variables which are expected to be present
by a template, and the values are passed in as-is.

The base-class implementation returns an empty hash reference.

=cut

sub article_template_variables { {} }

=item $gen-E<gt>article($file, $urls)

A standard generator method for generating an article (a file with its
C<daizu:type> attribute set to C<article>).  It calls
the L<generate_web_page() method|/$gen-E<gt>generate_web_page($file, $url, $template_overrides, $template_vars)>
to handle the templating.  You can pass all the URLs for the different
pages of a multi-page article in at once.

Subclasses can provide template rewriting and extra template variables
by overriding the methods
L<article_template_overrides()|/$gen-E<gt>article_template_overrides($file, $url_info)> and
L<article_template_variables()|/$gen-E<gt>article_template_variables($file, $url_info)>.

=cut

sub article
{
    my ($self, $file, $urls) = @_;

    for my $url (@$urls) {
        $self->generate_web_page($file, $url,
            $self->article_template_overrides($file, $url),
            $self->article_template_variables($file, $url));
    }
}

=item $gen-E<gt>unprocessed($file, $urls)

Generate an 'unprocessed' file.  This is a standard generator method which
simply prints the file's data to each of the URL's file handles

=cut

sub unprocessed
{
    my ($self, $file, $urls) = @_;
    my $data = $file->data;

    for (@$urls) {
        my $fh = $_->{fh};
        print $fh $$data;
    }
}

=item $gen-E<gt>google_sitemap($file, $urls)

A standard generator method which generates a Google sitemap
file, gzip compressed.

The XML namespace URL used in Google sitemaps is available in the variable
C<$Daizu::Gen::SITEMAP_NS>.

The format of Google sitemaps is documented here:

L<http://www.google.com/webmasters/sitemaps/docs/en/protocol.html>

=cut

our $SITEMAP_NS = 'http://www.google.com/schemas/sitemap/0.84';

sub google_sitemap
{
    my ($self, $file, $urls) = @_;
    my $db = $self->{cms}{db};

    for my $url (@$urls) {
        my $base_url = $self->base_url($file);
        die "error generating sitemap: file $file->{id} has no base URL"
            unless defined $base_url;

        my $doc = XML::LibXML::Document->new('1.0', 'UTF-8');
        my $sitemap = $doc->createElementNS($SITEMAP_NS, 'urlset');
        $doc->setDocumentElement($sitemap);

        my $sth = $db->prepare(qq{
            select u.url, f.modified_at, f.article
            from url u
            inner join wc_file f on u.wc_id = f.wc_id and u.guid_id = f.guid_id
            where f.wc_id = ?
              and u.status = 'A'
              and not f.no_index
              and u.content_type in
                  ('application/xhtml+xml', 'text/html', 'application/pdf')
              and u.url like ?
            order by u.url
        });
        $sth->execute($file->{wc_id}, like_escape($base_url) . '%');

        while (my ($url, $updated, $article) = $sth->fetchrow_array) {
            next if length($url) >= 2048;   # Google won't accept this

            $sitemap->appendText("\n");
            my $elem = add_xml_elem($sitemap, 'url');
            add_xml_elem($elem, loc => $url);
            $updated = parse_db_datetime($updated);
            add_xml_elem($elem, lastmod => w3c_datetime($updated))
                if defined $updated;
            add_xml_elem($elem, priority => ($article ? '1.0' : '0.5'));
        }

        my $gz = gzopen($url->{fh}, 'wb9')
            or die "error opening sitemap file: $gzerrno";
        $gz->gzwrite($doc->toStringC14N)
            or die 'error writing compressed sitemap file: ' . $gz->gzerror;
        $gz->gzclose
            and die 'error closing compressed sitemap file: ' . $gz->gzerror;
        $url->{fh} = undef;     # don't try to close it again later
    }
}


=item $gen-E<gt>scaled_image($file, $urls)

A standard generator method which generates a scaled version of an image
file.  C<$file> must represent an image in a format which can be understood
by L<Image::Magick>.

The argument should consist of two numbers, the desired width and height
of the resulting image, separated by a single space.

=cut

sub scaled_image
{
    my ($self, $file, $urls) = @_;
    my $data = $file->data;

    for my $url (@$urls) {
        die "bad argument '$url->{argument}' for scaled_image URL"
            unless $url->{argument} =~ /^(\d+) (\d+)$/;
        my ($width, $height) = ($1, $2);

        require Image::Magick;
        my $img = Image::Magick->new;
        $img->BlobToImage($$data);

        # Discard all but the first frame, in case it's an animated GIF,
        # otherwise we'll end up with multiple output files.
        $#$img = 0;

        $img->Thumbnail(width => $width, height => $height);

        # TODO: This atrocity is only temporary, until I work out how to
        # tell ImageMagick to write to a bloody file handle.  What the
        # documentation says doesn't work, it just goes to STDOUT.
        my ($tmp_fh, $tmp_filename) = tempfile();
        $img->Write($tmp_filename);

        seek $tmp_fh, 0, 0 or die "error seeking: $!";
        binmode $tmp_fh or die "error binmoding: $!";
        my $out_fh = $url->{fh};
        while (<$tmp_fh>) {
            print $out_fh $_;
        }

        close $tmp_fh;
        unlink $tmp_filename
            or warn "error removing temporary file '$tmp_filename': $!";
    }
}

=item $gen-E<gt>navigation_menu($file, $url)

Return a recursive data structure describing a suitable menu for displaying
on a page associated with C<$file>, which must be a L<Daizu::File> object.
C<$url> is the URL info for the page being generated.

This is called from the default I<nav_menu.tt> template to generate the
menu to put in the right-hand column.

The menu will not include the homepage (because that is presumably already
linked from the top of the page or something, and it would be a waste of
an extra level in the menu), and will not include any 'retired' articles.

The return value is a reference to an array of zero or more hashes,
each of which will contain the following keys:

=over

=item link

The URL of the page the menu item refers to, relative to C<$url>.  That is,
this may not be an absolute URL, but it should get you to the right place
from the page this menu was intended for.

This value will not be present for a menu item which refers to the current
URL, because that shouldn't be a link (it's bad usability practice to link
to the current page, because people might wonder why nothing happened).

=item title

The full title of the page the item refers to, if any.

=item short_title

An alternative title which might be more suitable for display in a menu.
It will usually be the same as C<title>, but sometimes the user (or a plugin)
might provide an abbreviated title which is better in this kind of context.

=item children

A reference to an array of zero or more hashes, in the same format as
the top-level ones, for items which should be presented as 'children'
of this menu item, typically as a nested list.

=back

=cut

sub navigation_menu
{
    my ($self, $cur_file, $cur_url_info) = @_;
    my $cms = $self->{cms};
    my $db = $cms->{db};
    my $wc_id = $cur_file->{wc_id};
    my $cur_url = $cur_url_info->{url};

    # Get a list of the ancestor URLs of the current one, going backwards
    # up the tree until we get to the top.  But don't include the top itself.
    my @above;
    my $url = $cur_url->clone;
    while (1) {
        my $old_url = $url->clone;
        my $path = $url->path;
        #assert(defined $path) if DEBUG;
        $path =~ s{[^/]+/?\z}{};        # take off last path component
        $url->path($path);
        last if $url->eq($old_url);
        last if $path eq '/';

        my ($file_id, $title, $short_title) = $db->selectrow_array(q{
            select id, title, short_title
            from wc_file
            where wc_id = ?
              and article_pages_url = ?
              and article
              and not retired
        }, undef, $wc_id, $url);
        next unless defined $file_id;

        # Skip if we've already got this in the menu.
        next if  @above && $file_id == $above[-1]{id};
        next if !@above && $file_id == $cur_file->{id};

        unshift @above, {
            id => $file_id,
            link => $url->clone,
            title => decode('UTF-8', $title, Encode::FB_CROAK),
            short_title => decode('UTF-8', $short_title, Encode::FB_CROAK),
        };
    }

    # Turn that linear list of ancestors into a hiearchical structure.
    # The point is that the format of the output is then more flexible
    # than is required by this (current) default menu implementation,
    # so that subclasses can do more clever things if they want.
    my @menu;
    my $children = \@menu;
    for (@above) {
        my $submenu = [];
        push @$children, {
            link => $_->{link}->rel($cur_url),
            title => $_->{title},
            short_title => $_->{short_title},
            children => $submenu,
        };
        $children = $submenu;
    }

    # Get menu items for the children under the current URL, if any.
    my $tmp_menu = [];
    my $has_children = _menu_url_children($cms, $wc_id, $cur_url, $cur_url,
                                          $tmp_menu)
        if $cur_url =~ m!/$!;

    if ($has_children) {
        # Graft the children and possibly the current URL onto the menu.
        if ($cur_url->path ne '/') {
            push @$children, {
                title => $cur_file->title,
                short_title => $cur_file->short_title,
                children => $tmp_menu,
            };
        }
        else {
            # A menu for a page at the root just contains its own children.
            assert(!@menu) if DEBUG;
            @menu = @$tmp_menu;
        }
    }
    else {
        # Add siblings of the current URL.
        my $parent_url = $cur_url->clone;
        my $path = $parent_url->path;
        $path =~ s{[^/]+/?\z}{};        # take off last path component
        $parent_url->path($path);
        _menu_url_children($cms, $wc_id, $cur_url, $parent_url, $children)
            if $parent_url =~ m!/$! && !$parent_url->eq($cur_url);
    }

    return \@menu;
}

sub _menu_url_children
{
    my ($cms, $wc_id, $cur_url, $parent_url, $menu) = @_;
    my $db = $cms->{db};
    assert($parent_url =~ m!/$!) if DEBUG;

    # Search for an appropriate 'daizu:nav-menu' property.  If the parent
    # file doesn't have one, then look at the directory it's in if it's
    # an article with an index-like name.
    my ($parent_id, $grand_parent_id, $parent_name, $parent_is_dir) =
    $db->selectrow_array(q{
        select f.id, f.parent_id, f.name
        from wc_file f
        inner join url u on u.wc_id = f.wc_id and u.guid_id = f.guid_id
        where u.wc_id = ?
          and u.url = ?
          and u.status = 'A'
    }, undef, $wc_id, $parent_url);

    my ($menu_file_id, $menu_prop);
    if (defined $parent_id) {
        $menu_file_id = $parent_id;
        $menu_prop = db_select($db, 'wc_property',
            { file_id => $parent_id, name => 'daizu:nav-menu' },
            'value',
        );
    }
    if (!defined $menu_prop && defined $grand_parent_id &&
        !$parent_is_dir && $parent_name =~ /^_index\./)
    {
        $menu_file_id = $grand_parent_id;
        $menu_prop = db_select($db, 'wc_property',
            { file_id => $grand_parent_id, name => 'daizu:nav-menu' },
            'value',
        );
    }

    my $has_children;
    if (defined $menu_prop) {
        # Return menu items from the 'daizu:nav-menu' property.
        $menu_prop = decode('UTF-8', $menu_prop, Encode::FB_CROAK),
        my $menu_file = Daizu::File->new($cms, $menu_file_id);
        my $base_url = $menu_file->permalink;
        for my $line (split /[\x0A\x0D]/, $menu_prop) {
            $line = trim($line);
            next if $line eq '';
            my ($url, $title) = split ' ', $line, 2;
            die "bad line '$line' in 'daizu:nav-menu' on file $menu_file_id"
                unless defined $url && defined $title;
            $url = URI->new_abs($url, $base_url);
            push @$menu, {
                ($url->eq($cur_url) ? () : (link => $url->rel($cur_url))),
                title => $title,
                children => [],
            };
            $has_children = 1;
        }
    }
    else {
        # Return menu items for articles with appropriate URLs.
        my $sth = $db->prepare(q{
            select article_pages_url, title, short_title
            from wc_file
            where wc_id = ?
              and article_pages_url ~ ('^' || ? || '[^/]+/?$')
              and article
              and not retired
            order by article_pages_url
        });
        $sth->execute($wc_id, pgregex_escape($parent_url));

        while (my ($url, $title, $short_title) = $sth->fetchrow_array) {
            $url = URI->new($url);
            push @$menu, {
                ($url->eq($cur_url) ? () : (link => $url->rel($cur_url))),
                title => decode('UTF-8', $title, Encode::FB_CROAK),
                short_title => decode('UTF-8', $short_title, Encode::FB_CROAK),
                children => [],
            };
            $has_children = 1;
        }
    }

    return $has_children;
}

=back

=head1 COPYRIGHT

This software is copyright 2006 Geoff Richards E<lt>geoff@laxan.comE<gt>.
For licensing information see this page:

L<http://www.daizucms.org/license/>

=cut

1;
# vi:ts=4 sw=4 expandtab
