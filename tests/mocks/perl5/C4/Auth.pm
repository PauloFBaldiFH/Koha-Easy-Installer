package C4::Auth;
# Test double: records the permission asked for; "noauth" in the state
# folder answers like the login page.
use strict;
use warnings;
use Exporter 'import';
use KeiKohaState;
our @EXPORT_OK = qw( checkauth );
sub checkauth {
    my ( $query, $noauth, $flags, $type ) = @_;
    KeiKohaState::note( 'checkauth', $type, map { "$_=$flags->{$_}" } sort keys %$flags );
    if ( -e KeiKohaState::path('noauth') ) { print "Status: 403 Forbidden\r\nContent-Type: text/plain\r\n\r\nlogin required\n"; exit 0 }
    return ( 'librarian', undef, 'SESSID1' );
}
1;
