#!perl -w
use strict;
use Mojolicious::Lite;
use Mojo::IOLoop;
use Path::Class 'dir';
use Getopt::Long;
use Cwd;
use Pod::Usage;

use App::Mojo::AssetReloader;
use Helper::File::ChangeNotify::Threaded;

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

$config_file ||= App::Mojo::AssetReloader->find_config_file(
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

my $config = app->config;

# Overwrite directories in the config that were specified on the command line

if( @watch ) {
    $config->{watch} = \@watch;
};

$config = App::Mojo::AssetReloader->restructure_config(
    $config
);

# Restructure config from the INI file into our default actions
sub restructure_config( $config ) {
    $config->{watch} ||= ['.'];
    if( ! ref $config->{watch}) {
        $config->{watch} = [$config->{watch}];
    } elsif( 'HASH' eq ref $config->{watch}) {
        $config->{watch} = [values %{$config->{watch}}];
    };
    push @{ $config->{watch}}, $config_file
        if ($config_file and -f $config_file);

    # Convert from hash to array if necessary
    if( 'HASH' eq ref $config->{watch}) {
        $config->{watch} = [ sort keys %{ $config->watch } ];
    };

    my $cwd = getcwd();
    @{ $config->{watch} } = map {
        Mojo::File->new( $_ )->to_abs($cwd)
    } @{ $config->{watch} };

    $config->{actions} ||= App::Mojo::AssetReloader->default_config->{actions};
    my @actions;
    for my $section ( grep { $_ ne 'watch' and $_ ne 'actions' } keys %$config ) {
        my $user_specified = $config->{$section};
        $user_specified->{name} = $section;
        push @actions, $user_specified;
    };
    unshift @{ $config->{actions}}, @actions;
    return $config
};


hook 'after_static' => sub( $c ) {
    # serve everything as static
    app->log->debug(sprintf "Serving static file '%s' (%s)", $c->req->url, $c->res->headers->content_type);
    return if $c->res->headers->content_type !~ m!^text/html\b!i;

    app->log->debug(sprintf "Rewriting HTML for '%s'", $c->req->url);

    # rewrite HTML to append/add our <script> tag to the end
    my $inject = Mojo::App::AssetReloader->inject;
    my $res = $c->res->content->asset->slurp;
    $res =~ s!</body>!$inject</body>!i;

    my $r = Mojo::Asset::Memory->new();
    $r->add_chunk( $res );

    # should we maybe remember an expected reconnect to our websocket here?!
    # Also, before reloading, should we syntax-check things?!
    $c->res->content->asset( $r );

    $res
};

our %pages;
our $id = 0;
websocket sub($c) {
    my $client_id = $id++;
    $pages{ $client_id } = $c->tx;
    $c->inactivity_timeout(60);
    app->log->warn("Client $client_id connected");
    $c->on(finish => sub( $c, @rest ) {
        app->log->warn("Client $client_id disconnected");
        delete $pages{ $client_id };
    });
};

# Have a reload timer that will check
app->log->info("Watching things below $_")
    for @{ $config->{watch}};
unshift @{ app->static->paths }, @{ $config->{watch}};

sub notify_changed( @files ) {
    my $config = app->config;
    my $dir = app->config->{watch}->[0]; # let's hope we only have one source for files for the moment

    warn "Checking $dir/Makefile";
    if( -f "$dir/Makefile") {
        system qq(gmake -f "$dir/Makefile");
    }

    my @actions;
    for my $f (@files) {
        my $rel = Mojo::File->new($f);
        $rel = $rel->to_rel( $dir );
        $rel =~ s!\\!/!g;

        # Go through all potential actions, first one wins
        my $found;
        for my $candidate (@{ $config->{actions} }) {
            if( $f =~ /$candidate->{filename}/i ) {
                my $action = { path => $rel, %$candidate };

                if( $action->{type} eq 'eval' ) {
                    my $content = Mojo::File->new( $f );
                    $action->{ str } = $content->slurp;
                } elsif( $action->{type} eq 'run' ) {
                    my $cmd = $action->{command};
                    $cmd =~ s!\$file!$f!g;
                    system( $cmd ) == 0
                        or warn "Couldn't launch [$cmd]: $!/$?";
                    $found++;
                    last;
                };
                push @actions, $action;
                $found++;
                last;
            };
        };
        app->log->warn("Ignoring change to $rel")
            if not $found;
    };

    if( @actions ) {
        for my $client_id (sort keys %pages) {
            my $client = $pages{ $client_id };
            for my $action (@actions) {
                # Convert path to what the client will likely have requested (duh)

                # These rules should all come from a config file, I guess
                app->log->info("Notifying client $client_id of '$action->{name}' change to '$action->{path}'");
                $client->send({json => $action });
            };
        };
    };
}

Helper::File::ChangeNotify::Threaded::watch_files( @watch );
my $reload = Mojo::IOLoop->recurring(1, sub {
    my @changed = Helper::File::ChangeNotify::Threaded::files_changed();
    app->log->debug("$_ changed") for @changed;
    notify_changed(@changed) if @changed;
});

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

Reloading of assets only happens on Morbo restarts with L<Mojolicious::Plugin::AutoReload>.

=cut
