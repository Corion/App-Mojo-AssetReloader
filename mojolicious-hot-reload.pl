#!perl -w
use strict;
use Mojolicious::Lite;
use Mojo::IOLoop;
use Path::Class 'dir';
use Getopt::Long;

use Helper::File::ChangeNotify::Threaded;

use Filter::signatures;
use feature 'signatures';
no warnings 'experimental::signatures';
GetOptions();

#my ($serve) = @ARGV;
our $serve ||= '.';

# Inject a live reload, keep all logic on the server
my $inject = <<'HTML';
<!-- hot-server appends this snippit to inject code via a websock  -->
<script>
new WebSocket(location.origin.replace(/^http/, 'ws')).onmessage = msg => {
// console.log(msg.data);
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
}
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
    #$c->tx->timeout( 3000 );
    $pages{ $id++ } = $c->tx;
    $c->inactivity_timeout(3600);
    app->log->warn("Client $id connected");
    $c->on(finish => sub( $c, @rest ) {
        app->log->warn("Client $id disconnected");
        delete $pages{ $id };
    });
};

# Have a reload timer that will check
my $dir = dir( $serve )->absolute;
app->log->info("Watching things below $dir");
unshift @{ app->static->paths }, $dir;

# XXX
my @watch = glob "$dir/*";
#warn "[[@watch]]";

sub notify_changed( @files ) {
    for my $client_id (sort keys %pages) {
        my $client = $pages{ $client_id };
        for my $f (@files) {
            # Convert path to what the client will likely have requested (duh)
            my $rel = Mojo::File->new($f);
            $rel = $rel->to_rel( $dir );
            $rel =~ s!\\!/!g;

            # These rules should all come from a config file, I guess
            if( $f =~ /\.html$/i ) {
                app->log->warn("Notifying client $client_id HTML change to $rel");
                $client->send({json => { path => $rel, type => 'reload', str => '' }});

            } elsif( $f =~ /\.css/i ) {
                app->log->warn("Notifying client $client_id of CSS change to $rel");
                #$client->send({json => { path => $rel, type => 'cssInject', str => '' }});
                $client->send({json => { path => $rel, type => 'refetch', attr => 'href', selector => 'link[rel="stylesheet"]' }});

            } elsif( $f =~ /\.(png|jpe?g)$/i ) {
                app->log->warn("Notifying client $client_id of image change to $rel");
                #$client->send({json => { path => $rel, type => 'cssInject', str => '' }});
                $client->send({json => { path => $rel, type => 'refetch', attr => 'src', selector => 'img[src]' }});
                # Also refetch images that were used as background via CSS:
                #$client->send({json => { path => $rel, type => 'refetch', attr => 'src', selector => '[style^="background-image:"][style*=".png)"]' }});
                #$client->send({json => { path => $rel, type => 'refetch', attr => 'src', selector => '[style^="background-image:"][style*=".jpg)"]' }});
                #$client->send({json => { path => $rel, type => 'refetch', attr => 'src', selector => '[style^="background-image:"][style*=".jpeg)"]' }});

            } elsif( $f =~ /\.js/i ) {
                app->log->warn("Notifying client $client_id of JS change to $rel");
                # We should check whether the Javascript passes a syntax check
                # before reloading it, maybe
                my $content = Mojo::File->new( $f );
                $client->send({json => { path => $rel, type => 'eval', str => $content->slurp }});

            # We should replace images by doing the same trick as cssInject, except
            # for images
            } else {
                app->log->warn("Ignoring change to $rel");
            }
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
