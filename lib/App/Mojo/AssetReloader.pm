package App::Mojo::AssetReloader;
use strict;
our $VERSION = '0.01';

=head1 NAME

App::Mojo::AssetReloader - automatically reload static assets

=cut

1;

=head1 SEE ALSO

L<Mojolicious::Plugin::AutoReload> - this is a Mojolicious plugin already,
which this program is not (yet). It has more controlled JS injection and
less complex Javascript. It can reload generated HTML instead of just static
assets. On the downside, it can't reload changed images or CSS
without reloading the HTML page.

=cut