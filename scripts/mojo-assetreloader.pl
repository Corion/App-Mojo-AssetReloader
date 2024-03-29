#!perl -w
use strict;
use Mojolicious::Lite;
use Mojo::Asset::Memory;
use Path::Class 'dir';
use Getopt::Long;
use Pod::Usage;

use App::Mojo::AssetReloader;

use Filter::signatures;
use feature 'signatures';
no warnings 'experimental::signatures';
GetOptions(
    'config|f=s' => \my $config_file,
    'help'       => \my $display_help,
) or pod2usage(2);
pod2usage(1) if $display_help;

=head1 SYNOPSIS

  mojo-assetreloader.pl daemon _site/
  mojo-assetreloader.pl daemon _site/ --config=mysite.ini

  Options:
    --config config file to use

=head1 OPTIONS

=over 4

=item B<--config>

Specify a config file.

=item B<--help>

Print a brief help message

=item B<--verbose>

=back

=head1 DESCRIPTION

This program will serve a directory over HTTP and will notify the browser of
changes to the files on the file system.

=cut

my( $command, @watch ) = @ARGV;

my $reloader = App::Mojo::AssetReloader->new(
    watch => \@watch,
);

$config_file ||= $reloader->find_config_file(
    name => 'assetreloader',
    dirs => [@watch, '.', $ENV{HOME}, $ENV{USERPROFILE}],
    global => '/etc/assetreloader'
);

if( $config_file and -f $config_file ) {
    # Read the config
    $config_file = Mojo::File->new( $config_file )->to_abs;
    # Hmm - this overwrites the whole app config, thus preventing reuse within
    # a larger application?!
    app->plugin('INIConfig' => { file => $config_file });
    app->log->info("Loading config file '$config_file'");
};

# Overwrite directories in the config that were specified on the command line

$reloader->restructure_config(
    config => app->config,
    config_file_name => $config_file,
);

# Maybe this should become an "after_body" hook so we can also rewrite
# dynamic HTML replies?!
hook 'after_static' => sub( $c ) {
    # serve everything as static
    app->log->debug(sprintf "Serving static file '%s' (%s)", $c->req->url, $c->res->headers->content_type);
    return if $c->res->headers->content_type !~ m!^text/html\b!i;

    app->log->debug(sprintf "Rewriting HTML for '%s'", $c->req->url);

    # rewrite HTML to append/add our <script> tag to the end
    my $inject = $reloader->inject_html;
    my $res = $c->res->content->asset->slurp;
    $res =~ s!</body>!$inject</body>!i;

    my $r = Mojo::Asset::Memory->new();
    $r->add_chunk( $res );

    # should we maybe remember an expected reconnect to our websocket here?!
    # Also, before reloading, should we syntax-check things?!
    $c->res->content->asset( $r );

    $res
};

websocket sub($c) {
    my $client_id = $reloader->add_client( $c );
    app->log->warn("Client $client_id connected");
};

# Have a reload timer that will check
app->log->info("Watching things below $_")
    for @{ $reloader->watch};
unshift @{ app->static->paths }, @{ $reloader->watch };

$reloader->start_watching( 1 );

@ARGV=(daemon => '-l', 'http://*:5001');
app->start;

=head1 CONFIG

    [watch]
    dir1=.
    dir2=
    [HTML]
    filename=.html$
    type=reload
    [Template]
    filename=\.tmpl$
    run=make
    [CSS]
    filename=\.css$
    type=refetch
    attr=href
    selector=link[rel="stylesheet"]
    [image]
    filename=\.(png|jpe?g)$
    type=refetch
    attr=src
    selector=img[src]
    [JS]
    filename=\.js$
    type=eval

=head1 SEE ALSO

L<Mojolicious::Plugin::AutoReload> - this is a Mojolicious plugin already,
which this program is not (yet). It has more controlled JS injection and
less complex Javascript. It can reload generated HTML instead of just static
assets. On the downside, it can't reload changed images or CSS
without reloading the HTML page.

Reloading of assets only happens on Morbo restarts
with L<Mojolicious::Plugin::AutoReload>.

=cut
