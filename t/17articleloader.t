#!/usr/bin/perl
use warnings;
use strict;

use Test::More;
use XML::LibXML;
use Carp::Assert qw( assert );
use Daizu;
use Daizu::Test qw( init_tests );
use Daizu::Plugin::XHTMLArticle;

init_tests(13);

my $cms = Daizu->new($Daizu::Test::TEST_CONFIG);

# XHTMLArticle
{
    my $plugin_info = $cms->{article_loaders}{'text/html'}{''}[0];
    assert(defined $plugin_info);
    my ($plugin_object, $plugin_method) = @$plugin_info;
    is(ref $plugin_object, 'Daizu::Plugin::XHTMLArticle',
       'XHTMLArticle: plugin object of right class');
    my $file = MockFile->new;
    my $article = $plugin_object->$plugin_method($cms, $file);
    ok(defined $article, 'XHTMLArticle: article info');

    is(scalar(keys %$article), 1, 'XHTMLArticle: no metadata');
    my $doc = $article->{content};
    ok(defined $doc, 'XHTMLArticle: content');
    isa_ok($doc, 'XML::LibXML::Document', 'XHTMLArticle: content');

    my $root = $doc->documentElement;
    is($root->nodeName, 'body', 'XHTMLArticle: right root elem');

    my (@child_elems) = map {
        $_->nodeType == XML_ELEMENT_NODE ? ($_) : ()
    } $root->getChildNodes();
    is(scalar(@child_elems), 4,
       'XHTMLArticle: right number of child elems');
    is($child_elems[0]->localname, 'p', 'XHTMLArticle: elem 0 is p');
    is($child_elems[0]->namespaceURI, 'http://www.w3.org/1999/xhtml',
       'XHTMLArticle: elem 0 is XHTML');
    is($child_elems[1]->localname, 'fold',
       'XHTMLArticle: elem 1 is fold');
    is($child_elems[1]->namespaceURI,
       'http://www.daizucms.org/ns/html-extension/',
       'XHTMLArticle: elem 0 is Daizu extension');
    ok($child_elems[2]->findnodes("*[local-name() = 'include']"),
       'XHTMLArticle: XInclude not expanded yet');

    my $text = $child_elems[3]->textContent;
    is($text, "More\x{2026}", 'XHTMLArticle: char entity refs expanded');
}


package MockFile;

sub new
{
    return bless { path => 'test/file' }, 'MockFile';
}

sub data
{
    return \q{
        <p>Paragraph.</p>
        <daizu:fold/>
        <blockquote><xi:include href="inc.txt" parse="text"/></blockquote>
        <p>More&hellip;</p>
    };
}

# vi:ts=4 sw=4 expandtab filetype=perl
