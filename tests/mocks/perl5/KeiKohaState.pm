package KeiKohaState;
# Shared state of the Koha test doubles (tests/modules.bats): records in
# $S/biblio/<n>.xml, calls appended to $S/calls.log.
use strict;
use warnings;
our $S = $ENV{KEI_KOHA_STATE} || '/run/kei-mock/koha';
sub path { return "$S/$_[0]" }
sub note {
    open( my $fh, '>>', "$S/calls.log" ) or die "$S/calls.log: $!";
    print {$fh} join( ' ', @_ ), "\n";
    close $fh;
}
sub slurp { my $f = shift; open( my $fh, '<:raw', $f ) or return; local $/; my $d = <$fh>; close $fh; return $d }
1;
