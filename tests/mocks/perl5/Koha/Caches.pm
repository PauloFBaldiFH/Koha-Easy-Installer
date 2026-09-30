package Koha::Caches;
# Test double of Koha's cache: like Koha::Cache->new, it uses Memcached
# only if the client loads and a first write succeeds.
use strict;
use warnings;
sub get_instance {
    my $self = bless { cache => undef }, shift;
    if ( eval { require Cache::Memcached::Fast::Safe; 1 } ) {
        my $mc = Cache::Memcached::Fast::Safe->new( { servers => ['127.0.0.1:11211'], namespace => 'koha_library::' } );
        $self->{cache} = $mc if $mc->set( 'ismemcached', '1' );
    }
    return $self;
}
sub cache { return $_[0]->{cache} }
sub set_in_cache { my ( $self, $key, $value ) = @_; return $self->{cache} ? $self->{cache}->set( $key, $value ) : undef }
1;
