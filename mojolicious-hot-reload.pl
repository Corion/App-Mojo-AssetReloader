#!perl -w
use strict;
use Mojolicious::Lite;
use Path::Class 'dir';
use Getopt::Long;

GetOptions();

my ($serve) = @ARGV;
$serve ||= '.';

my %inject = (
    # Inject a live reload, keep all logic on the server
    'text/html' => <<'HTML';
<!-- hot-server appends this snippit to inject code via a websock  -->
<script>
new WebSocket(location.origin.replace(/^http/, 'ws')).onmessage = msg => {
  var {path, type, str} = JSON.parse(msg.data)
  if (type == 'reload') location.reload()
  if (type == 'jsInject') eval(str)
  if (type == 'cssInject') {
    Array.from(document.querySelectorAll('link'))
      .filter(d => d.href.includes(path))
      .forEach(d => d.href = d.href)
  }
}
</script>
HTML
);

unshift @{ app->static->paths}, dir( $serve )->absolute;

my @watch = glob '*';

app->start;

package Mojo::Server::Morbo::Backend::Win32;
use strict;
use Win32::ChangeNotify;
use Win32::Event 'wait_any';
use threads;
use Mojo::Base 'Mojo::Server::Morbo::Backend';
use Mojo::File 'path';

sub _list { path(shift)->list_tree->map('to_string')->each }
has _modified_files => sub { [] };
has _cache => sub { {} };
has _watchers => sub { [] };

(my $html = $file) =~ s/\.pod$/\.html/i;

sub modified_files( $self ) {
    # Set up our watchers, just in case
    $self->_modified_files
}

sub add_watch( $self, $path ) {
    push @{ $self->_watchers }, Win32::ChangeNotify->new( $path, 1, "LAST_WRITE|SIZE" );
}

sub _on_change( $self ) {
  
  my @files = @{ $self->_modified_files };
  my %files = map { $_ => 1 } @files;
  for my $file (map { -f $_ && -r _ ? $_ : _list($_) } @{$self->watch}) {
    my ($size, $mtime) = (stat $file)[7, 9];
    next unless defined $size and defined $mtime;
    my $stats = $cache->{$file} ||= [$^T, $size];
    next if $mtime <= $stats->[0] && $size == $stats->[1];
    @$stats = ($mtime, $size);
    $files{ $file } = 1;
  }
  @{ $self->_modified_files } = sort keys %files;
};

1;

package App::ShaderToy::FileWatcher;
use strict;

our $enabled;
BEGIN {
    eval "use threads;";
    $enabled = !defined($@);
}
use Thread::Queue;
use Filesys::Notify::Simple;
use File::Basename 'dirname';
use File::Spec;

use Filter::signatures;
use feature 'signatures';
no warnings 'experimental::signatures';

=head1 NAME

App::ShaderToy::FileWatcher - watch files for changes

=cut

# Launch our watcher thread for updates to the shader program:
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
