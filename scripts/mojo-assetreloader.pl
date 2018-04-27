#!perl -w
use strict;
use Mojolicious::Lite;
use Mojo::IOLoop;
use Path::Class 'dir';
use Getopt::Long;
use Cwd;
use Pod::Usage;

use Helper::File::ChangeNotify::Threaded;

use Filter::signatures;
use feature 'signatures';
no warnings 'experimental::signatures';
GetOptions(
    'config|f=s' => \my $config_file,
) or pod2usage(2);

=head1 SYNOPSIS

  mojo-assetreloader.pl _site/

=head1 OPTIONS

=cut

my( $command, @watch ) = @ARGV;
my $default_config = {
    actions => [
        { name => 'HTML',  filename => qr/\.html$/,        type => 'reload' },
        { name => 'CSS',   filename => qr/\.css$/,         type => 'refetch', attr => 'href', selector => 'link[rel="stylesheet"]' },
        { name => 'image', filename => qr/\.(png|jpe?g)$/, type => 'refetch', attr => 'src', selector => 'img[src]' },
        { name => 'JS',    filename => qr/\.js$/,          type => 'eval', },
    ]
};

sub maybe_exists( $f ) {
    return $f
        if( $f and -f $f );
    return "$f.ini"
        if( $f and -f "$f.ini" );
}

if( !$config_file ) {
    my $config_name = '.assetreloader';
    ($config_file) = grep { defined $_ }
                     map { maybe_exists "$_/$config_name" }
                     grep { defined $_ && length $_ }
                     (@watch, '.', $ENV{HOME});
    $config_file ||= maybe_exists '/etc/assetreloader';
};

if( $config_file and -f $config_file ) {
    # Read the config
    $config_file = Mojo::File->new( $config_file )->to_abs;
    app->plugin('INIConfig' => { file => $config_file });
    app->log->info("Loading config file '$config_file'");
};

my $config = app->config;

# Overwrite directories in the config that were specified on the command line

if( @watch ) {
    $config->{watch} = \@watch;
};

$config = restructure_config( $config );

# Restructure config from the INI file into our default actions
sub restructure_config( $config ) {
    $config->{watch} ||= ['.'];
    unshift @{ $config->{watch}}, $config_file
        if ($config_file and -f $config_file);

    # Convert from hash to array if necessary
    if( 'HASH' eq ref $config->{watch}) {
        $config->{watch} = [ sort keys %{ $config->watch } ];
    };

    my $cwd = getcwd();
    @{ $config->{watch} } = map {
        Mojo::File->new( $_ )->to_abs($cwd)
    } @{ $config->{watch} };

    $config->{actions} ||= $default_config->{actions};
    for my $section ( grep { $_ ne 'watch' and $_ ne 'actions' } keys %$config ) {
        my $user_specified = $config->{$section};
        $user_specified->{name} = $section;
        unshift @{ $config->{actions}}, $user_specified;
    };
    return $config
};

# Inject a live reload, keep all logic on the server
my $inject = <<'HTML';
<!-- hot-server appends this snippit to inject code via a websock  -->
<script>
function _ws_reopen() {
    //console.log("Retrying connection");
    var me = {
        retry: null,
        ping: null,
        was_connected: null,
        _ws: null,
        open: () => {
            me._ws = new WebSocket(location.origin.replace(/^http/, 'ws'));
            me._ws.onerror = (e) => {
                if( me.ping ) {
                    //console.log("Ping stopped",e);
                    clearInterval( me.ping );
                    me.ping = null;
                    };
                if(me.was_connected && !me.retry) me.retry = setInterval( () => { me.open(); }, 5000 );
            };
            me._ws.onclose = (e) => {
                if( me.ping ) {
                    //console.log("Ping stopped",e);
                    clearInterval( me.ping );
                    me.ping = null;
                    };
                if(me.was_connected && !me.retry) me.retry = setInterval( () => { me.open(); }, 5000 );
            };
            me._ws.onopen = () => {
                //console.log("(Re)connected");
                clearInterval(me.retry)
                me.retry = null;
                me.was_connected = true;
                if( !me.ping) {
                    me.ping = setInterval( () => {
                      //console.log("pinging");
                      try {
                          me._ws.send( "ping" )
                      } catch( e ) {
                          //console.log("Lost connection", e);
                          me._ws.onerror(e);
                      };
                    }, 5000 );
                };
            };
            me._ws.onmessage = msg => {
            try {
              var {path, type, selector, attr, str} = JSON.parse(msg.data)
              } catch(e) { console.log(e) };
              if (type == 'reload') location.reload()
              if (type == 'jsInject') eval(str)
              if (type == 'refetch') {
                try {
                Array.from(document.querySelectorAll(selector))
                  .filter(d => d[attr].includes(path))
                  .forEach(function( d ) {
                      try {
                          const cacheBuster = '?dev=' + Math.floor(Math.random() * 100); // Justin Case, cache buster
                          d[attr] = d[attr].replace(/\?(?:dev=.*?(?=\&|$))|$/, cacheBuster);
                          console.log(d[attr]);
                      } catch( e ) {
                          console.log(e);
                      };
                  });
                  } catch( e ) {
                    console.log(e);
                  };
              }
            };
        },
    };
    me.open();
    return me
};
var ws = _ws_reopen();
</script>
HTML

hook 'after_static' => sub( $c ) {
    # serve everything as static
    app->log->debug(sprintf "Serving static file '%s' (%s)", $c->req->url, $c->res->headers->content_type);
    return if $c->res->headers->content_type !~ m!^text/html\b!i;

    app->log->debug(sprintf "Rewriting HTML for '%s'", $c->req->url);

    # rewrite HTML to append/add our <script> tag to the end
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
    for @watch;
unshift @{ app->static->paths }, @watch;

sub notify_changed( @files ) {
    my $dir = $watch[0]; # let's hope we only have one source for files for the moment

    my @actions;
    for my $f (@files) {
        my $rel = Mojo::File->new($f);
        $rel = $rel->to_rel( $dir );
        $rel =~ s!\\!/!g;

        # Go through all potential actions, first one wins
        my $found;
        my $config = app->config;
        for my $candidate (@{ $config->{actions} }) {
            if( $f =~ /$candidate->{filename}/i ) {
                my $action = { path => $rel, %$candidate };

                if( $action->{type} eq 'eval' ) {
                    my $content = Mojo::File->new( $f );
                    $action->{ str } = $content->slurp;
                };
                push @actions, $action;
                $found++;
                last;
            };
        };
        app->log->warn("Ignoring change to $rel")
            if not $found;
    };

    for my $client_id (sort keys %pages) {
        my $client = $pages{ $client_id };
        for my $action (@actions) {
            # Convert path to what the client will likely have requested (duh)

            # These rules should all come from a config file, I guess
            app->log->warn("Notifying client $client_id of '$action->{name}' change to '$action->{path}'");
            $client->send({json => $action });
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

=cut