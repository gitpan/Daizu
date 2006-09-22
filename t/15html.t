#!/usr/bin/perl
use warnings;
use strict;

use Test::More tests => 26;
use Path::Class qw( file );
use XML::LibXML;
use Encode qw( decode );
use Daizu;
use Daizu::Test;
use Daizu::HTML qw(
    parse_xhtml_content
    dom_body_to_html4 dom_node_to_html4 dom_body_to_text
    absolutify_links
    html_escape_text html_escape_attr
);

# html_escape_text
is(html_escape_text(q{ < > & ' " }), q{ &lt; &gt; &amp; ' " },
   'html_escape_text');

# html_escape_attr
is(html_escape_attr(q{ < > & ' " }), q{ &lt; &gt; &amp; ' &quot; },
   'html_escape_attr');

# dom_node_to_html4
{
    is(dom_node_to_html4(XML::LibXML::Text->new(q{ < > & ' " })),
       q{ &lt; &gt; &amp; ' " },
       'dom_node_to_html4: text');
    is(dom_node_to_html4(XML::LibXML::Comment->new(q{ < > & ' " })),
       q{<!-- &lt; &gt; &amp; ' " -->},
       'dom_node_to_html4: comment');

    my $elem = XML::LibXML::Element->new('p');
    is(dom_node_to_html4($elem), q{<p></p>},
       'dom_node_to_html4: empty paragraph');

    $elem->appendText(q{ < > & ' " });
    is(dom_node_to_html4($elem),
       q{<p> &lt; &gt; &amp; ' " </p>},
       'dom_node_to_html4: paragraph with text');

    $elem->appendChild(XML::LibXML::Element->new('br'));
    $elem->appendText("more\ntext");
    my $em = XML::LibXML::Element->new('em');
    $em->appendText('text nested in <em>');
    $elem->appendChild($em);
    my $img = XML::LibXML::Element->new('img');
    $img->setAttribute(src => 'foo.png');
    $img->setAttribute(class => 'TestImage');
    $elem->appendChild($img);
    my $got = dom_node_to_html4($elem);

    # Munge the output to remove dependence on Perl's hash ordering.
    $got =~ s/class="TestImage" src="foo\.png"/src="foo.png" class="TestImage"/;

    is($got,
       qq{<p> &lt; &gt; &amp; ' " <br>more\ntext<em>text nested in &lt;em&gt;</em><img src="foo.png" class="TestImage"></p>},
       'dom_node_to_html4: complex markup and empty elements');
}

# parse_xhtml_content
{
    no warnings 'redefine';
    my @opens;
    local *Daizu::HTML::_open_uri = sub { push @opens, \@_; return \'mock-fh' };
    my $done_read = 0;
    local *Daizu::HTML::_read_uri = sub { $done_read++ ? '' : "read:${$_[0]}"; };
    local *Daizu::HTML::_close_uri = sub { };

    my $doc = parse_xhtml_content('$cms', '$wc_id', 'test/file', \q{
        <p>Paragraph.</p>
        <daizu:fold/>
        <blockquote><xi:include href="inc.txt" parse="text"/></blockquote>
    });

    is(scalar(@opens), 1, 'parse_xhtml_content: opens one included file');
    is($opens[0][0], '$cms',
       'parse_xhtml_content: _open_uri passed right cms');
    is($opens[0][1], '$wc_id',
       'parse_xhtml_content: _open_uri passed right wc_id');
    is($opens[0][2], 'daizu:///test/inc.txt',
       'parse_xhtml_content: _open_uri passed right URL');

    my $root = $doc->documentElement;
    is($root->nodeName, 'body', 'parse_xhtml_content: right root elem');

    my (@child_elems) = map {
        $_->nodeType == XML_ELEMENT_NODE ? ($_) : ()
    } $root->getChildNodes();
    is(scalar(@child_elems), 3,
       'parse_xhtml_content: right number of child elems');
    is($child_elems[0]->localname, 'p', 'parse_xhtml_content: elem 0 is p');
    is($child_elems[0]->namespaceURI, 'http://www.w3.org/1999/xhtml',
       'parse_xhtml_content: elem 0 is XHTML');
    is($child_elems[1]->localname, 'fold',
       'parse_xhtml_content: elem 1 is fold');
    is($child_elems[1]->namespaceURI,
       'http://www.daizucms.org/ns/html-extension/',
       'parse_xhtml_content: elem 0 is Daizu extension');
    is($child_elems[2]->textContent, 'read:mock-fh',
       'parse_xhtml_content: XInclude daizu: URI expanded correctly');
}

# dom_body_to_html4
{
    my $doc = XML::LibXML::Document->new('1.0', 'UTF-8');
    my $body = XML::LibXML::Element->new('body');
    $body->setNamespace('http://www.w3.org/1999/xhtml');
    $doc->setDocumentElement($body);

    my @para;
    for (1 .. 3) {
        my $elem = XML::LibXML::Element->new('p');
        $elem->appendText($_);
        $body->appendChild($elem);
        push @para, $elem;
    }

    # This extension element should not be output to the HTML 4 code.
    $body->appendChild(
        $doc->createElementNS($Daizu::HTML_EXTENSION_NS, 'extension'),
    );

    is(dom_body_to_html4($doc), '<p>1</p><p>2</p><p>3</p>',
       'dom_body_to_html4: whole document');
    is(dom_body_to_html4($doc, $para[0], undef), '<p>1</p><p>2</p><p>3</p>',
       'dom_body_to_html4: start=first para, end=undef');
    is(dom_body_to_html4($doc, $para[1], undef), '<p>2</p><p>3</p>',
       'dom_body_to_html4: start=second para, end=undef');
    is(dom_body_to_html4($doc, undef, $para[2]), '<p>1</p><p>2</p>',
       'dom_body_to_html4: start=undef, end=last para');
    is(dom_body_to_html4($doc, $para[1], $para[2]), '<p>2</p>',
       'dom_body_to_html4: start=second para, end=last para');
    is(dom_body_to_html4($doc, $para[2], $para[2]), '',
       'dom_body_to_html4: start=second para, end=second para');
}

# dom_body_to_text
{
    my $input = read_file('text-input.html');
    my $expected = read_file('text-expected.txt');
    $expected = decode('UTF-8', $expected, Encode::FB_CROAK);

    my $doc = parse_xhtml_content(undef, undef, 'test', \$input);

    is(dom_body_to_text($doc), $expected, 'dom_body_to_text');
}

# absolutify_links
{
    my $input = read_file('absolutify-input.html');
    my $expected = read_file('absolutify-expected.html');

    my $doc = parse_xhtml_content(undef, undef, 'test/path/filename', \$input);
    absolutify_links($doc, 'http://example.com/base/basefile.html');

    my $output = '';
    for ($doc->documentElement->childNodes) {
        $output .= $_->toString;
    }
    is($output, $expected, 'absolutify_links');
}


sub test_filename { file(qw( t data 15html ), @_) }

# TODO perhaps some stuff like this should be moved to Daizu::Test
sub read_file
{
    my ($test_file) = @_;
    open my $fh, '<', test_filename($test_file)
        or die "error: $!";
    binmode $fh
        or die "error reading file '$test_file' in binary mode: $!";
    local $/;
    return <$fh>;
}

# vi:ts=4 sw=4 expandtab filetype=perl
