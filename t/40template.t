#!/usr/bin/perl
use warnings;
use strict;

use Test::More tests => 80;
use Carp::Assert qw( assert );
use Daizu;
use Daizu::TTProvider;
use Daizu::Test;

my $cms = Daizu->new($Daizu::Test::TEST_CONFIG);
my $db = $cms->db;
my $wc = $cms->live_wc;

my $homepage_file = $wc->file_at_path('foo.com/_index.html');
my $docidx_file = $wc->file_at_path('foo.com/doc/_index.html');
my $subidx_file = $wc->file_at_path('foo.com/doc/subdir/_index.html');
my $a_file = $wc->file_at_path('foo.com/doc/subdir/a.html');
my $blog_article_file = $wc->file_at_path('foo.com/blog/2006/fish-fingers/article-1.html');
assert(defined $_)
    for $homepage_file, $docidx_file, $subidx_file, $a_file,
        $blog_article_file;


# article_template_overrides() and article_template_variables()
isa_ok($homepage_file->generator->article_template_overrides, 'HASH',
       'Daizu::Gen->article_template_overrides');
isa_ok($homepage_file->generator->article_template_variables, 'HASH',
       'Daizu::Gen->article_template_variables');
isa_ok($blog_article_file->generator->article_template_overrides, 'HASH',
       'Daizu::Gen::Blog->article_template_overrides');
isa_ok($blog_article_file->generator->article_template_variables, 'HASH',
       'Daizu::Gen::Blog->article_template_variables');


# Daizu::Gen->navigation_menu
my $menu = get_nav_menu_carefully($homepage_file);
is(scalar @$menu, 3, 'navigation_menu: homepage: children');
test_menu_item($menu->[0], 'homepage, 0', 0, 'about.html', 'About Foo.com');
test_menu_item($menu->[1], 'homepage, 1', 0, 'blog/', 'Foo Blog');
test_menu_item($menu->[2], 'homepage, 2', 0, 'doc/',
               "Title for \x{2018}doc\x{2019} index page");

$menu = get_nav_menu_carefully($docidx_file);
is(scalar @$menu, 1, 'navigation_menu: docidx: one item');
test_menu_item($menu->[0], 'docidx, 0', 2, undef,
               "Title for \x{2018}doc\x{2019} index page");
test_menu_item($menu->[0]{children}[0], 'docidx, 0.0', 0,
               'Util.html', 'Daizu::Util - various utility functions');
test_menu_item($menu->[0]{children}[1], 'docidx, 0.1', 0,
               'subdir/', 'Subdir index');

$menu = get_nav_menu_carefully($subidx_file);
test_menu_item($menu->[0], 'subidx, 0', 1,
               '../', "Title for \x{2018}doc\x{2019} index page");
test_menu_item($menu->[0]{children}[0], 'subidx, 0.0', 3,
               undef, 'Subdir index');
test_menu_item($menu->[0]{children}[0]{children}[0], 'subidx, 0.0.0', 0,
               'a.html', 'First article');
test_menu_item($menu->[0]{children}[0]{children}[1], 'subidx, 0.0.1', 0,
               'q.html', 'Middle article');
test_menu_item($menu->[0]{children}[0]{children}[2], 'subidx, 0.0.2', 0,
               'z.html', 'Last article');

$menu = get_nav_menu_carefully($a_file);
test_menu_item($menu->[0], 'afile, 0', 1,
               '../', "Title for \x{2018}doc\x{2019} index page");
test_menu_item($menu->[0]{children}[0], 'afile, 0.0', 3,
               './', 'Subdir index');
test_menu_item($menu->[0]{children}[0]{children}[0], 'afile, 0.0.0', 0,
               undef, 'First article');
test_menu_item($menu->[0]{children}[0]{children}[1], 'afile, 0.0.1', 0,
               'q.html', 'Middle article');
test_menu_item($menu->[0]{children}[0]{children}[2], 'afile, 0.0.2', 0,
               'z.html', 'Last article');

# Daizu::Gen::Blog->navigation_menu - TODO


# Daizu::TTProvider->_load()
test_load_template($cms, $a_file,        'test1.tt',
                   'Test template 1, in foo.com/doc');
test_load_template($cms, $subidx_file,   'test1.tt',
                   'Test template 1, in foo.com/doc');
test_load_template($cms, $docidx_file,   'test1.tt',
                   'Test template 1, in foo.com/doc');
test_load_template($cms, $homepage_file, 'test1.tt',
                   undef);

test_load_template($cms, $a_file,        'test2.tt',
                   'Test template 2, in foo.com/doc');
test_load_template($cms, $subidx_file,   'test2.tt',
                   'Test template 2, in foo.com/doc');
test_load_template($cms, $docidx_file,   'test2.tt',
                   'Test template 2, in foo.com/doc');
test_load_template($cms, $homepage_file, 'test2.tt',
                   'Test template 2, in foo.com');

test_load_template($cms, $a_file,        'test3.tt',
                   'Test template 3, in foo.com');
test_load_template($cms, $subidx_file,   'test3.tt',
                   'Test template 3, in foo.com');
test_load_template($cms, $docidx_file,   'test3.tt',
                   'Test template 3, in foo.com');
test_load_template($cms, $homepage_file, 'test3.tt',
                   'Test template 3, in foo.com');

test_load_template($cms, $a_file,        'test4.tt',
                   'Test template 4, in top level');
test_load_template($cms, $subidx_file,   'test4.tt',
                   'Test template 4, in top level');
test_load_template($cms, $docidx_file,   'test4.tt',
                   'Test template 4, in top level');
test_load_template($cms, $homepage_file, 'test4.tt',
                   'Test template 4, in top level');

test_load_template($cms, $a_file,        'article_meta/pubdatetime.tt',
                   'Template to override one which is provided with Daizu.');
test_load_template($cms, $subidx_file,   'article_meta/pubdatetime.tt',
                   'Template to override one which is provided with Daizu.');
test_load_template($cms, $docidx_file,   'article_meta/pubdatetime.tt',
                   'Template to override one which is provided with Daizu.');
test_load_template($cms, $homepage_file, 'article_meta/pubdatetime.tt',
                   'Template to override one which is provided with Daizu.');
test_load_template($cms, $wc->file_at_path('example.com/foo.html'),
                   'article_meta/pubdatetime.tt',
                   '<p>[% INCLUDE article_pubdatetime.tt datetime = entry.issued_at %]</p>');

# Check that binary data is preserved.
test_load_template($cms, $homepage_file, 'binary-test.tt',
                   "foo\x00\x1B\x7F\x80\xA0\x{FF}bar");

# With template overrides in place.
test_load_template($cms, $a_file,        'test1.tt',
                   'Test template 2, in foo.com/doc',
                   { 'test1.tt' => 'test2.tt' });
test_load_template($cms, $subidx_file,   'test1.tt',
                   'Test template 2, in foo.com/doc',
                   { 'test1.tt' => 'test2.tt' });
test_load_template($cms, $docidx_file,   'test1.tt',
                   'Test template 2, in foo.com/doc',
                   { 'test1.tt' => 'test2.tt' });
test_load_template($cms, $homepage_file, 'test1.tt',
                   'Test template 2, in foo.com',
                   { 'test1.tt' => 'test2.tt' });


sub get_nav_menu_carefully
{
    my ($file) = @_;
    my $gen = $file->generator;
    my @urls = $gen->urls_info($file);
    assert(@urls >= 1);

    my $menu = $gen->navigation_menu($file, $urls[0]);

    my $num_undef_links = _nav_menu_check_children($menu);
    assert($num_undef_links == 0 || $num_undef_links == 1);
    return $menu;
}
 
sub _nav_menu_check_children
{
    my ($items) = @_;
    assert(defined $items);
    assert(ref $items eq 'ARRAY');

    my $num_undef_links = 0;
    for my $item (@$items) {
        assert(defined $item);
        assert(ref $item eq 'HASH');
        assert(defined $item->{title});
        ++$num_undef_links unless defined $item->{link};
        $num_undef_links += _nav_menu_check_children($item->{children});
    }

    return $num_undef_links;
}

sub test_menu_item
{
    my ($item, $desc, $num_children, $url, $title) = @_;
    SKIP: {
        skip "expected menu item doesn't exist", 3
            unless defined $item;
        is($item->{link}, $url, "navigation_menu: $desc: link");
        is($item->{title}, $title, "navigation_menu: $desc: title");
        is(scalar @{$item->{children}}, $num_children,
           "navigation_menu: $desc: num children");
    }
}

sub test_load_template
{
    my ($cms, $file, $template, $expected, $overrides) = @_;
    my $msg = "TTProvider: $template in $file->{path}";
    $msg .= ' with overrides'
        if defined $overrides && keys %$overrides;

    my $provider = Daizu::TTProvider->new({
        daizu_cms => $cms,
        daizu_wc_id => $file->{wc_id},
        daizu_file_path => $file->directory_path,
        daizu_template_overrides => $overrides,
    });

    my ($data, $error) = $provider->_load($template);
    my $text = $data->{text};

    # Render 'declined' as undef, so that I can compare it with $expected.
    # Other errors get reported as such.
    if ($error && $error == Template::Constants::STATUS_DECLINED) {
        $text = undef;
        $error = undef;
    }

    if ($error) {
        fail("$msg: error: $error");
    }
    else {
        $text =~ s/\n\z// if defined $text;
        is($text, $expected, $msg);
    }
}

# vi:ts=4 sw=4 expandtab filetype=perl
