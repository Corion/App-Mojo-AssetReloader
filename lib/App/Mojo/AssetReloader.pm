package App::Mojo::AssetReloader;
use strict;
use Mojo::Base -base;

use Filter::signatures;
use feature 'signatures';
no warnings 'experimental::signatures';

use Cwd 'getcwd';
use Mojo::File;

our $VERSION = '0.01';

=head1 NAME

App::Mojo::AssetReloader - automatically reload static assets

=cut

our $default_config = {
    actions => [
        { name => 'HTML',  filename => qr/\.html$/,        type => 'reload' },
        { name => 'CSS',   filename => qr/\.css$/,         type => 'refetch', attr => 'href', selector => 'link[rel="stylesheet"]' },
        { name => 'image', filename => qr/\.(png|jpe?g)$/, type => 'refetch', attr => 'src', selector => 'img[src]' },
        { name => 'JS',    filename => qr/\.js$/,          type => 'eval', },
        { name => 'POD',    filename => qr/\.pod$/,        type => 'run', command => 'gmake'},
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

has 'inject_html'    => sub { $inject };
has 'actions'        => sub { $default_config->{actions} };


sub maybe_exists( $f ) {
    return $f
        if( $f and -f $f );
    return "$f.ini"
        if( $f and -f "$f.ini" );
}

sub find_config_file( $class, %options ) {
    my $config_name = $options{ name };
    my ($config_file) = grep { defined $_ }
                        map { maybe_exists "$_/$config_name" }
                        grep { defined $_ && length $_ }
                        (@{ $options{ dirs }});
    $config_file ||= maybe_exists $options{ global };
}

# Restructure config from the INI file into our default actions
sub restructure_config( $class, $config, %options ) {
    my $config_file = $options{ config_file };
    $config->{watch} ||= ['.'];
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

    $config->{actions} ||= $class->default_config->{actions};
    my @actions;
    for my $section ( grep { $_ ne 'watch' and $_ ne 'actions' } keys %$config ) {
        my $user_specified = $config->{$section};
        $user_specified->{name} = $section;
        push @actions, $user_specified;
    };
    unshift @{ $config->{actions}}, @actions;
    return $config
};

1;

=head1 SEE ALSO

L<Mojolicious::Plugin::AutoReload> - this is a Mojolicious plugin already,
which this program is not (yet). It has more controlled JS injection and
less complex Javascript. It can reload generated HTML instead of just static
assets. On the downside, it can't reload changed images or CSS
without reloading the HTML page.

=cut