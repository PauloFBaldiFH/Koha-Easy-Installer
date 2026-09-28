package Koha::Database;
# Test double: txn_do notes the begin / commit / rollback.
use strict;
use warnings;
use KeiKohaState;
sub new { return bless {}, shift }
sub schema { return bless {}, 'KeiFakeSchema' }
package KeiFakeSchema;
sub txn_do {
    my ( $self, $code ) = @_;
    KeiKohaState::note('txn-begin');
    my $ok = eval { $code->(); 1 };
    KeiKohaState::note( $ok ? 'txn-commit' : 'txn-rollback' );
    die $@ unless $ok;
    return 1;
}
1;
