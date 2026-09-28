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
    return () unless $sql =~ /FROM biblio_metadata/;
    KeiKohaState::note( 'select-metadata', $bind[0], ( $sql =~ /FOR UPDATE/ ? 'FOR-UPDATE' : '' ) );
    my $xml = KeiKohaState::slurp( KeiKohaState::path("biblio/$bind[0].xml") );
    return defined $xml ? ( Encode::decode( "UTF-8", $xml ) ) : ();
}
1;
