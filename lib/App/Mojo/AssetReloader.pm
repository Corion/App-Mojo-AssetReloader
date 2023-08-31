package App::Mojo::AssetReloader;
use strict;
#use Mojo::Base -base;
use Mojo::Base 'Mojolicious::Plugin';
#use Mojo::IOLoop;
use Mojo::Util qw( unindent trim );

use Filter::signatures;
use feature 'signatures';
no warnings 'experimental::signatures';

use Cwd 'getcwd';
use Helper::File::ChangeNotify::Threaded;
use Mojo::File;
use Mojo::IOLoop;

our $VERSION = '0.01';

=head1 NAME

App::Mojo::AssetReloader - automatically reload static assets

=head1 SYNOPSIS

    plugin 'AssetReloader' => {
        watch => ['templates'],
    };

=cut

our $default_config = {
    actions => [
        { name => 'HTML',           filename => qr/\.html$/,              type => 'reload' },
        { name => 'HTML-template',  filename => qr/(\.html\.ep|\.tmpl)$/, type => 'reload' },
        { name => 'CSS',   filename => qr/\.css$/,         type => 'refetch', attr => 'href', selector => 'link[rel="stylesheet"]' },
        { name => 'image', filename => qr/\.(png|jpe?g)$/, type => 'refetch', attr => 'src', selector => 'img[src]' },
        { name => 'JS',    filename => qr/\.js$/,          type => 'eval', },
        { name => 'POD',    filename => qr/\.pod$/,        type => 'run', command => 'gmake'},
        { name => 'markdown',  filename => qr/\.(mkdn|md|markdown)$/, type => 'run', command => 'gmake'},
    ]
};

# Inject a live reload, keep all logic on the server
our $inject = <<'HTML';
<!-- hot-server appends this snippit to inject code via a websocket  -->
<script>
function _ws_reopen() {
    //console.log("Retrying connection");
    var me = {
        retry: null,
        ping: null,
        was_connected: null,
        _ws: null,
        reconnect: () => {
            if( me.ping ) {
                clearInterval( me.ping );
                me.ping = null;
            };
            me._ws = null;
            if(!me.retry) {
                me.retry = setTimeout( () => { try { me.open(); } catch( e ) { console.log("Whoa" )} }, 5000 );
            };
        },
        open: () => {
            me.retry = null;
            me._ws = new WebSocket(location.origin.replace(/^http/, 'ws'));
            me._ws.addEventListener('close', (e) => {
                me.reconnect();
            });
            me._ws.addEventListener('error', (e) => {
                me.reconnect();
            });
            me._ws.addEventListener('open', () => {
                if( me.retry ) {
                    clearInterval(me.retry)
                    me.retry = null;
                };
                me.was_connected = true;
                if( !me.ping) {
                    me.ping = setInterval( () => {
                      try {
                          me._ws.send( "ping" )
                      } catch( e ) {
                          //console.log("Lost connection", e);
                          me._ws.onerror(e);
                      };
                    }, 5000 );
                };
            });
            me._ws.addEventListener('message', (msg) => {
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
            });
        },
    };
    me.open();
    return me
};
var ws = _ws_reopen();
</script>
HTML

=head1 SYNOPSIS

  my $app = App::Mojo::AssetReloader->new();
  $app->load_config();

=cut

has 'inject_html'     => sub { $inject };
has 'watch'           => undef;
has 'reload_interval' => undef;
has 'actions'         => sub { $default_config->{actions} };
has 'clients'         => sub { {} };
has 'loop'            => sub { { require Mojo::IOLoop; 'Mojo::IOLoop' } };
has 'id'              => 1;
has 'app'             => undef;

# That config loading likely will move back out to the main program again
# or somewhere else...
sub maybe_exists( $f ) {
    return $f
        if( $f and -f $f );
    return "$f.ini"
        if( $f and -f "$f.ini" );
}

# This should go back to the app, maybe?!
sub find_config_file( $class, %options ) {
    my $config_name = $options{ name };
    my ($config_file) = grep { defined $_ }
                        map { maybe_exists "$_/$config_name" }
                        grep { defined $_ && length $_ }
                        (@{ $options{ dirs }});
    $config_file ||= maybe_exists $options{ global };
}

# Restructure config from the INI file into our default actions
sub restructure_config( $self, %options ) {
    my $config = $options{ config };
    my $config_file = $options{ config_file_name };
    if( exists $config->{watch} and not $self->watch ) {
        $self->watch( $config->{watch} );
    };
    if( ! $self->watch or (ref $self->watch eq 'ARRAY' and 0 == @{ $self->watch })) {
        $self->watch( ['.'] );
    };
    push @{ $self->watch }, $config_file
        if ($config_file and -f $config_file);

    # Convert from hash to array if necessary
    if( 'HASH' eq ref $self->watch) {
        $self->watch = [ sort keys %{ $self->watch } ];
    };

    my $cwd = getcwd();
    @{ $self->watch } = map {
        Mojo::File->new( $_ )->to_abs($cwd)
    } @{ $self->watch };

    my @actions;
    for my $section ( grep { $_ ne 'watch' and $_ ne 'actions' } keys %$config ) {
        my $user_specified = $config->{$section};
        $user_specified->{name} = $section;
        push @actions, $user_specified;
    };
    unshift @{ $self->actions }, @actions;
    return $self
};

sub notify_changed( $self, @files ) {
    my $dir = $self->watch->[0]; # let's hope we only have one source for files for the moment

    my @actions;
    for my $f (@files) {
        my $rel = Mojo::File->new($f);
        $rel = $rel->to_rel( $dir );
        $rel =~ s!\\!/!g;

        # Go through all potential actions, first one wins
        my $found;
        for my $candidate (@{ $self->actions }) {
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
                my $app = $self->app;
                if( $app ) {
                    my $log = $app->log;
                    if( $log ) {
                        $log->info(sprintf "'%s' on '%s'", $action->{type}, $action->{path});
                    };
                } else {
                    warn sprintf "'%s' on '%s'", $action->{type}, $action->{path}
                };
                push @actions, $action;
                $found++;
                last;
            };
        };
        $self->app->log->warn("Ignoring change to $rel")
            if not $found;
    };

    if( @actions ) {
        $self->notify_clients( @actions )
    };
}

=head2 C<< $plugin->notify_clients >>

  $plugin->notify_clients( {
      type => 'reload',
  });

Notify all connected clients that they should perform actions.

=cut

sub notify_clients( $self, @actions ) {
    # Blow the cache away
    if( $self->app ) {
        my $old_cache = $self->app->renderer->cache;
        $self->app->renderer->cache( Mojo::Cache->new(max_keys => $old_cache->max_keys));
    };

    my $clients = $self->clients;
    for my $client_id (sort keys %$clients ) {
        my $client = $clients->{ $client_id };
        for my $action (@actions) {
            # Convert path to what the client will likely have requested (duh)

            # These rules should all come from a config file, I guess
            #app->log->info("Notifying client $client_id of '$action->{name}' change to '$action->{path}'");
            $client->send({json => $action });
        };
    };
}

sub register( $self, $app, $config ) {
    $self->app( $app );
    $config = $self->restructure_config( config => $config );

    $app->routes->websocket( sub($c) {
        my $client_id = $self->add_client( $c );
        $app->log->warn("Client $client_id connected");
    });

    $app->helper( auto_reload => sub {
        my ( $c ) = @_;
        #if ( $app->mode eq 'development' ) {
            return $c->render_to_string( inline => unindent trim( $self->inject_html ) );
        #}
        #return '';
    } );

    unshift @{ $app->static->paths || [] }, @{ $self->watch };
    unshift @{ $app->renderer->paths || [] }, @{ $self->watch };
    $self->start_watching( 1 ); # XXX read interval from config
};


sub add_client( $self, $client ) {
    my $id = $self->{id}++;
    $self->clients->{ $id } = $client->tx;
    $client->inactivity_timeout(60);
    $client->on(finish => sub( $c, @rest ) {
        delete $self->clients->{ $id };
    });
    $id;
}

sub start_watching( $self, $poll_interval ) {
    Helper::File::ChangeNotify::Threaded::watch_files( @{ $self->watch } );
    $self->reload_interval( $self->loop->recurring($poll_interval, sub {
        my @changed = Helper::File::ChangeNotify::Threaded::files_changed();
        #app->log->debug("$_ changed") for @changed;
        $self->notify_changed(@changed) if @changed;
    }));
};

1;

=head1 SEE ALSO

L<Mojolicious::Plugin::AutoReload> - this is a Mojolicious plugin already,
which this program is not (yet). It has more controlled JS injection and
less complex Javascript. It can reload generated HTML instead of just static
assets. On the downside, it can't reload changed images or CSS
without reloading the HTML page.

=cut
