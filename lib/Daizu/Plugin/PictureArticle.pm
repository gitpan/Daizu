package Daizu::Plugin::PictureArticle;
use warnings;
use strict;

use Carp qw( croak );
use Carp::Assert qw( assert DEBUG );
use Encode qw( decode );
use Math::Round qw( round );
use Encode qw( encode );
use Daizu;
use Daizu::Util qw(
    trim display_byte_size
    db_select
    add_xml_elem xml_attr xml_croak
);

=head1 NAME

Daizu::Plugin::PictureArticle - publish image files as articles

=head1 DESCRIPTION

This plugin allows you to mark an image file as being an article
(by setting its C<daizu:type> property to C<article> as normal).
When it is published a normal article HTML page will be generated
with the title, description, and so on from the image file's
properties.  The image itself will also be published and included
in the page.  If the image is too big then an additional scaled down
'thumbnail' image will be generated and included in the page, and will
be linked to the full size original version.

This plugin will be triggered for any article with a MIME type
(according to the file's C<svn:mime-type> property) where the first
part is C<image>, for example C<image/jpeg>.

=head1 CONFIGURATION

To turn on this plugin, include the following in your Daizu CMS configuration
file:

=for syntax-highlight xml

    <plugin class="Daizu::Plugin::PictureArticle" />

By default it will ensure that the image included in the page will
not be more than 600 pixels wide or 600 pixels high.  The thumbnail
image will have the suffix I<-thm> added to its URL just before the
file extension.  You can change these settings in the configuration
file as follows:

=for syntax-highlight xml

    <plugin class="Daizu::Plugin::PictureArticle">
     <thumbnail max-width="400" min-height="400"
                filename-suffix="-small"/>
    </plugin>

This example limits included images to 400 pixels on a side, and
will use I<-small> as the suffix on the filename.

If the C<thumbnail> element is present at all then the C<max-width>
and C<max-height> values will default to unlimited size.  This means
that you can specify a maximum width but leave the height unbounded.

You can use different configuration for different websites, or parts
of websites, by providing multiple C<plugin> elements in the configuration
file: a default one and others in C<config> elements with paths.

=cut

our $DEFAULT_THUMBNAIL_MAX_WIDTH = 600;
our $DEFAULT_THUMBNAIL_MAX_HEIGHT = 600;
our $DEFAULT_THUMBNAIL_FILENAME_SUFFIX = '-thm';

# This is done on demand when it's needed.
sub _parse_config
{
    my ($self) = @_;
    return if $self->{config_parsed};

    my $config = $self->{config};
    my $config_filename = $self->{cms}{config_filename};
    my ($elem, $extra) = $config->getChildrenByTagNameNS($Daizu::CONFIG_NS,
                                                         'thumbnail');
    xml_croak($config_filename, $extra, "only one <thumbnail> element allowed")
        if defined $extra;

    if (!defined $elem) {
        # If there's no 'thumbnail' element, fall back to defaults.
        $self->{max_width} = $DEFAULT_THUMBNAIL_MAX_WIDTH;
        $self->{max_height} = $DEFAULT_THUMBNAIL_MAX_HEIGHT;
        $self->{thumbnail_filename_suffix} = $DEFAULT_THUMBNAIL_FILENAME_SUFFIX;
    }
    else {
        # Extract attributes from 'thumbnail' element.
        my $max_wd = trim(xml_attr($config_filename, $elem, 'max-width', ''));
        my $max_ht = trim(xml_attr($config_filename, $elem, 'max-height', ''));
        for ($max_wd, $max_ht) {
            if (!defined $_ || $_ eq '') {
                $_ = undef;
                next;
            }
            xml_croak($config_filename, $elem,
                      "attribute on element <thumbnail> should be a number")
                unless /^\d+$/;
        }

        $self->{max_width} = $max_wd;
        $self->{max_height} = $max_ht;

        $self->{thumbnail_filename_suffix} =
            trim(xml_attr($config_filename, $elem, 'filename-suffix',
                          $DEFAULT_THUMBNAIL_FILENAME_SUFFIX));
        xml_croak($config_filename, $elem, "filename-suffix must not be empty")
            if $self->{thumbnail_filename_suffix} eq '';
    }

    $self->{config_parsed} = 1;
}

=head1 METHODS

=over

=item Daizu::Plugin::PictureArticle-E<gt>register($cms, $whole_config, $plugin_config, $path)

Called by Daizu CMS when the plugin is registered.  It registers the
L<picture_to_article()|/$self-E<gt>picture_to_article($cms, $file)>
method as an article parser for all MIME types like 'image/*'.

=cut

sub register
{
    my ($class, $cms, $whole_config, $plugin_config, $path) = @_;
    my $self = bless { config => $plugin_config }, $class;
    $cms->add_article_parser('image/*', '', $self => 'picture_to_article');
}

=item $self-E<gt>picture_to_article($cms, $file)

Upgrades C<$file> (which should be a L<Daizu::File> object) to include
the information necessary for publishing the file as an article.
Creates an article document to contain the picture, or a thumbnail of
it if it is too big.

Never rejects a file, and therefore always returns true.

=cut

sub picture_to_article
{
    my ($self, $cms, $file) = @_;
    $self->_parse_config;

    # Size of the article picture itself.
    my ($pic_wd, $pic_ht) = ($file->{image_width}, $file->{image_height});
    croak "size of picture article image file not available in database"
        unless defined $pic_wd && defined $pic_ht;

    my $article_url = '';
    my $base_url = $file->generator->base_url($file);
    if ($base_url !~ m!/$!) {
        $article_url = $file->{name};
        $article_url =~ s!\.[^./]+$!.html!
            or $article_url .= '.html';
    }
    $file->set_article_pages_url($article_url);
    $file->add_extra_url($file->{name}, $file->{content_type},
                         'Daizu::Gen', 'unprocessed', '');

    # Filename of the thumbnail image, if any.
    my $thm_filename = $file->{name};
    my $filename_suffix = $self->{thumbnail_filename_suffix};
    $thm_filename =~ s!\.([^/.]+)$!$filename_suffix.$1!
        or $thm_filename .= $filename_suffix;

    # Does the thumbnail exist in the repository, and if so how big is it.
    my ($thm_exists, $thm_wd, $thm_ht) = db_select($cms->db, wc_file => {
        wc_id => $file->{wc_id},
        parent_id => $file->{parent_id},
        name => $thm_filename,
    }, qw( 1 image_width image_height ));
    croak "image to be thumbnailed doesn't have size recorded in database"
        if $thm_exists && (!defined $thm_wd || !defined $thm_ht);

    # How big is the thumbnail allowed to be, if there's a limit.
    my $max_wd = $self->{max_width};
    $max_wd = $pic_wd unless defined $max_wd;
    my $max_ht = $self->{max_height};
    $max_ht = $pic_ht unless defined $max_ht;

    # If there is no thumbnail provided for us, and the article image is too
    # big, then add add our own thumbnail URL.
    if (!$thm_exists && ($pic_wd > $max_wd || $pic_ht > $max_ht)) {
        $thm_wd = $pic_wd unless defined $thm_wd;
        $thm_ht = $pic_ht unless defined $thm_ht;

        my $x_mul = $thm_wd / $max_wd;
        my $y_mul = $thm_ht / $max_ht;
        if ($x_mul > $y_mul) {
            $thm_wd = $max_wd;
            $thm_ht = round($thm_ht / $x_mul);
        }
        else {
            $thm_wd = round($thm_wd / $y_mul);
            $thm_ht = $max_ht;
        }
        assert($thm_wd <= $max_wd && $thm_ht <= $max_ht) if DEBUG;
        assert($thm_wd == $max_wd || $thm_ht == $max_ht) if DEBUG;

        $file->add_extra_url($thm_filename, $file->{content_type},
                             'Daizu::Gen', 'scaled_image', "$thm_wd $thm_ht");
        $thm_exists = 1;
    }

    # Create the article content.
    $file->init_article_doc;
    my $body = $file->article_body;

    my $img = XML::LibXML::Element->new('img');
    $img->setAttribute(src => ($thm_exists ? $thm_filename : $file->{name}));

    my $alt = $file->property('daizu:alt');
    $alt = decode('UTF-8', $alt, Encode::FB_CROAK)
        if defined $alt;
    $img->setAttribute(alt => (defined $alt ? $alt : ''));

    $img->setAttribute(width => $thm_wd) if $thm_wd;
    $img->setAttribute(height => $thm_ht) if $thm_ht;

    my $img_block = add_xml_elem($body, 'div', undef,
        class => 'daizu-main-thumbnail',
    );
    if ($thm_exists) {
        add_xml_elem($img_block, 'a', $img, href => $file->{name});
        add_xml_elem($img_block, 'br');
        # Since we're linking to the full size image, provide some details
        # about it, mainly as a warning if it's really big.
        my $pic_size = $file->{data_len};
        my $TIMES = encode('UTF-8', "\xD7");
        my $desc = "full size: $pic_wd$TIMES$pic_ht, " .
                   display_byte_size($file->{data_len});
        add_xml_elem($img_block, 'a', $desc, href => $file->{name});
    }
    else {
        # Don't provide a link to the image if it's the same file as we're
        # including directly in the page.
        $img_block->appendChild($img);
    }

    return 1;
}

=back

=head1 COPYRIGHT

This software is copyright 2006 Geoff Richards E<lt>geoff@laxan.comE<gt>.
For licensing information see this page:

L<http://www.daizucms.org/license/>

=cut

1;
# vi:ts=4 sw=4 expandtab
