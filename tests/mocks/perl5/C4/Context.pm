package C4::Context;
# Test double: preferences and a database handle that reads the records
# of the state folder (SELECT ... FOR UPDATE is noted in calls.log).
use strict;
use warnings;
use Encode qw( decode );
use KeiKohaState;
sub preference { my ( $class, $name ) = @_; return $name eq 'marcflavour' ? 'MARC21' : undef }
sub dbh { return bless {}, 'KeiFakeDBH' }
package KeiFakeDBH;
sub selectrow_array {
    my ( $self, $sql, $attr, @bind ) = @_;
    if ( $sql =~ /^SELECT (GET_LOCK|RELEASE_LOCK)/ ) {
        KeiKohaState::note( lc($1) =~ tr/_/-/r, $bind[0] );
        return -e KeiKohaState::path('lock.busy') && $1 eq 'GET_LOCK' ? (0) : (1);
    }
    return () unless $sql =~ /FROM biblio_metadata/;
    KeiKohaState::note( 'select-metadata', $bind[0], ( $sql =~ /FOR UPDATE/ ? 'FOR-UPDATE' : '' ) );
    my $xml = KeiKohaState::slurp( KeiKohaState::path("biblio/$bind[0].xml") );
    return defined $xml ? ( Encode::decode( "UTF-8", $xml ) ) : ();
}
# Records whose 020 holds the ISBN of the LIKE pattern: [ biblionumber, title ].
sub selectall_arrayref {
    my ( $self, $sql, $attr, @bind ) = @_;
    return [] unless $sql =~ /FROM biblioitems/;
    ( my $isbn = $bind[0] ) =~ s/%//g;
    KeiKohaState::note( 'select-isbn', $isbn );
    my @rows;
    for my $f ( sort glob( KeiKohaState::path('biblio/*.xml') ) ) {
        my ($n) = $f =~ m{/(\d+)\.xml$} or next;
        my $xml = Encode::decode( 'UTF-8', KeiKohaState::slurp($f) );
        my @isbns = $xml =~ m{<datafield tag="020"[^>]*>\s*<subfield code="[az]">([^<]*)<}g;
        next unless grep { ( my $x = $_ ) =~ s/-//g; index( $x, $isbn ) >= 0 } @isbns;
        my ($title) = $xml =~ m{<datafield tag="245"[^>]*>\s*<subfield code="a">([^<]*)<};
        push @rows, [ $n, $title ];
    }
    return \@rows;
}
1;
