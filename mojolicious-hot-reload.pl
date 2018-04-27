#!perl -w
package Reload::ChangeNotify::Threaded;
use strict;
our $enabled;
BEGIN {
    my $ok = eval { require threads; 1 };
    my $err = $@;
    $enabled = $ok;
}
use Thread::Queue;
use Filesys::Notify::Simple;
use File::Basename 'dirname';
use File::Spec;

use Filter::signatures;
use feature 'signatures';
no warnings 'experimental::signatures';

use vars qw($reload $watcher %watched_files);

sub watch_files(@files) {
    return unless $enabled;
    @files = map { File::Spec->rel2abs( $_, '.' ) } @files;
    my @dirs = map {dirname($_)} @files;
    my %removed_files = %watched_files;
    delete @removed_files{ @files };
    my $other_files = grep { ! $watched_files{ $_ }} @files;
    $other_files ||= keys %removed_files;
    if( $other_files and $watcher ) {
        # We will accumulate dead threads here, because Filesys::Watcher::Simple
        # never returns and we don't have a way to stop a thread hard
        $watcher->kill('KILL')->detach if $watcher;
    };
    @watched_files{ @files } = (1) x @files;
    $reload ||= Thread::Queue->new();

    #status("Watching directories @dirs",1);
    $watcher = threads->create(sub(@dirs) {
        $SIG{'KILL'} = sub { threads->exit(); };
        while (1) {
            my $fs = Filesys::Notify::Simple->new(\@dirs)->wait(sub(@events) {
                my %affected;
                for my $event (@events) {
                    $affected{ $event->{path} } = 1;
                };
                #warn "Files changed: $_"
                #    for sort keys %affected;
                $reload->enqueue([sort keys %affected]);
            });
        };
        warn "Should never get here";
    }, @dirs);
};

sub files_changed() {
    return unless $enabled;
    my %changed;
    while ($reload and defined(my $item = $reload->dequeue_nb())) {
        undef @changed{ @$item };
    };
    return
    grep { $watched_files{ $_ } }
    sort keys %changed;
}

1;

package main;
use strict;
use Mojolicious::Lite;
use Mojo::IOLoop;
use Path::Class 'dir';
use Getopt::Long;

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
  var {path, type, str} = JSON.parse(msg.data)
  if (type == 'reload') location.reload()
  if (type == 'jsInject') eval(str)
  if (type == 'cssInject') {
  /*
    Array.from(document.querySelectorAll('link'))
      .filter(d => d.href.includes(path))
      .forEach(function(d) {console.log(d.href)});
      */
    try {
    Array.from(document.querySelectorAll('link'))
      .filter(d => d.href.includes(path))
      .forEach(function( d ) {
          try {
          const cacheBuster = '?dev=' + Math.floor(Math.random() * 100); // Justin Case, cache buster
          d.href = d.href.replace(/\?.*|$/, cacheBuster);
          console.log(d.href);
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
    for my $client (values %pages) {
        app->log->warn("Notifying client of @files");
        for my $f (@files) {
            # Convert path to what the client will likely have requested (duh)
            my $rel = Mojo::File->new($f);
            $rel = $rel->to_rel( $dir );
            $rel =~ s!\\!/!g;
            if( $f =~ /\.html$/i ) {
                $client->send({json => { path => $rel, type => 'reload', str => '' }});
            } elsif( $f =~ /\.css/i ) {
                $client->send({json => { path => $rel, type => 'cssInject', str => '' }});
            } elsif( $f =~ /\.js/i ) {
                my $content = Mojo::File->new( $f );
                $client->send({json => { path => $rel, type => 'eval', str => $content->slurp }});
            };
        };
    };
}

Reload::ChangeNotify::Threaded::watch_files( @watch );
my $reload = Mojo::IOLoop->recurring(1, sub {
    #warn "Checking";
    my @changed = Reload::ChangeNotify::Threaded::files_changed();
    app->log->debug("$_ changed") for @changed;
    notify_changed(@changed) if @changed;
});

app->start;
