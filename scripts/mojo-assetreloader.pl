#!perl -w
use strict;
use Mojolicious::Lite;
use Mojo::IOLoop;
use Path::Class 'dir';
use Getopt::Long;
use Cwd;

use Helper::File::ChangeNotify::Threaded;

use Filter::signatures;
use feature 'signatures';
no warnings 'experimental::signatures';
GetOptions();

#my ($serve) = @ARGV;
my( $command, @watch ) = @ARGV;
if( ! @watch ) {
    @watch = '.';
};
@watch = map {
    Mojo::File->new( $_ )->to_abs(getcwd())
} @watch;

# Inject a live reload, keep all logic on the server
my $inject = <<'HTML';
<!-- hot-server appends this snippit to inject code via a websock  -->
<script>
function _ws_reopen() {
    //console.log("Retrying connection");
    var me = {
        retry: null,
        ping: null,
        _ws: null,
        open: () => {
            me._ws = new WebSocket(location.origin.replace(/^http/, 'ws'));
            me._ws.onerror = (e) => {
                if( me.ping ) {
                    //console.log("Ping stopped",e);
                    clearInterval( me.ping );
                    me.ping = null;
                    };
                if(!me.retry) me.retry = setInterval( () => { me.open(); }, 5000 );
            };
            me._ws.onclose = (e) => {
                if( me.ping ) {
                    //console.log("Ping stopped",e);
                    clearInterval( me.ping );
                    me.ping = null;
                    };
                if(!me.retry) me.retry = setInterval( () => { me.open(); }, 5000 );
            };
            me._ws.onopen = () => {
                //console.log("(Re)connected");
                clearInterval(me.retry)
                me.retry = null;
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
    $pages{ $id++ } = $c->tx;
    $c->inactivity_timeout(60);
    app->log->warn("Client $id connected");
    $c->on(finish => sub( $c, @rest ) {
        app->log->warn("Client $id disconnected");
        delete $pages{ $id };
    });
};

# Have a reload timer that will check
app->log->info("Watching things below $_")
    for @watch;
unshift @{ app->static->paths }, @watch;

my $config = [
    { filename => qr/\.html$/,        type => 'reload' },
    { filename => qr/\.css$/,         type => 'refetch', attr => 'href', selector => 'link[rel="stylesheet"]' },
    { filename => qr/\.(png|jpe?g)$/, type => 'refetch', attr => 'src', selector => 'img[src]' },
    { filename => qr/\.js$/,          type => 'eval', },
];

sub notify_changed( @files ) {
    my $dir = $watch[0]; # let's hope we only have one source for files for the moment

    my @actions;
    for my $f (@files) {
        my $rel = Mojo::File->new($f);
        $rel = $rel->to_rel( $dir );
        $rel =~ s!\\!/!g;

        # Go through all potential actions, first one wins
        my $found;
        for my $candidate (@$config) {
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
            app->log->warn("Notifying client $client_id of '$action->{type}' change to '$action->{path}'");
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

=head1 SEE ALSO

L<Mojolicious::Plugin::AutoReload> - this is a Mojolicious plugin already,
which this program is not (yet). It has more controlled JS injection and
less complex Javascript. It can reload generated HTML instead of just static
assets. On the downside, it can't reload changed images or CSS
without reloading the HTML page.

=cut