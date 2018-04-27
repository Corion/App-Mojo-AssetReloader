package 
    Helper::File::ChangeNotify::Threaded;
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

use vars qw($reload $watcher %watched_files $watched_dirs);

sub watch_files(@files) {
    return unless $enabled;
    @files = map { File::Spec->rel2abs( $_, '.' ) } @files;
    my @dirs = map { -d $_ ? $_ : dirname($_)} @files;
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
    $watched_dirs = join "|", map { quotemeta $_ } grep { -d $_ } @files;
    $reload ||= Thread::Queue->new();

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
    grep { $watched_files{ $_ } || /^(?:$watched_dirs)\b/ }
    sort keys %changed;
}

1;

=head1 NAME

Helper::File::ChangeNotify::Threaded - helper for threaded change notifications

=head1 SYNOPSIS

This is a temporary module that should be adapted to the API
of L<File::ChangeNotify>.

=cut
