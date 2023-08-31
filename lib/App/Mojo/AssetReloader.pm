package App::Mojo::AssetReloader;
use strict;
use Filter::signatures;
use feature 'signatures';
no warnings 'experimental::signatures';

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

sub default_config( $class ) {
    $default_config
}

1;

=head1 SEE ALSO

L<Mojolicious::Plugin::AutoReload> - this is a Mojolicious plugin already,
which this program is not (yet). It has more controlled JS injection and
less complex Javascript. It can reload generated HTML instead of just static
assets. On the downside, it can't reload changed images or CSS
without reloading the HTML page.

=cut