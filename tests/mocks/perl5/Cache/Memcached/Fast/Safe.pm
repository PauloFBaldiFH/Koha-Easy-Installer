package Cache::Memcached::Fast::Safe;
# Test double: talks to the test Memcached over TCP. The file
# /run/kei-mock/cache-module-broken makes it fail to load, like a broken
# or missing Debian package.
use strict;
use warnings;
use IO::Socket::INET;
die "Can't locate Cache/Memcached/Fast/Safe.pm in \@INC (test double: module broken)\n"
    if -e '/run/kei-mock/cache-module-broken';
sub new { my ( $class, $args ) = @_; return bless { %{ $args || {} } }, $class }
sub set {
    my ( $self, $key, $value ) = @_;
    my ($server) = @{ $self->{servers} || [] };
    my $sock = IO::Socket::INET->new( PeerAddr => $server // '', Timeout => 2 ) or return;
    my $k = ( $self->{namespace} // '' ) . $key;
    print {$sock} "set $k 0 0 " . length($value) . "\r\n$value\r\n";
    my $reply = <$sock> // '';
    return $reply =~ /^STORED/ ? 1 : undef;
}
1;
