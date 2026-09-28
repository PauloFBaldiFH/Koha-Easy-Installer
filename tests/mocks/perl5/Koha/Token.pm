package Koha::Token;
# Test double: the token of session S is "tok-S".
use strict;
use warnings;
sub new { return bless {}, shift }
sub generate_csrf { my ( $self, $p ) = @_; return 'tok-' . ( $p->{session_id} // '' ) }
sub check_csrf { my ( $self, $p ) = @_; return defined $p->{session_id} && defined $p->{token} && $p->{token} eq 'tok-' . $p->{session_id} }
1;
